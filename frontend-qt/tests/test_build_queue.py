"""The build queue (nspb_qt/queue_model.py): games queued with their choices, built one after another, the estimates of
the time and the space they take, and the one install of the shared-app games when the queue ends.

    QT_QPA_PLATFORM=offscreen python3 -m unittest frontend-qt/tests/test_build_queue.py -v
"""
from __future__ import annotations

import os
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import qt_sandbox  # noqa: E402,F401  (first: the tests never touch the player's settings or state)
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'frontend-qt'))
os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')

from nspb_qt import queue_model as qm   # noqa: E402

try:
    from PySide6.QtCore import QSettings
    from PySide6.QtWidgets import QApplication
except ImportError:
    QApplication = None

GB = qm.GB


class Estimates(unittest.TestCase):
    def item(self, gb: float, reuse=False) -> qm.QueueItem:
        return qm.QueueItem(id='x', name='G', key='K', base='b', input_bytes=int(gb * GB), reuse=reuse)

    def test_the_default_before_any_build(self):
        est = qm.Estimator([])
        self.assertFalse(est.learned())
        self.assertEqual(est.space(self.item(10)), int(10 * GB * qm.DEFAULT_SPACE_FACTOR + qm.DEFAULT_SPACE_BASE))
        self.assertEqual(est.seconds(self.item(10)), qm.DEFAULT_SECONDS_BASE + 10 * qm.DEFAULT_SECONDS_PER_GB)
        # a build folder that is there already is mostly reused
        self.assertLess(est.space(self.item(10, reuse=True)), est.space(self.item(10)) / 2)

    def test_it_learns_from_this_pcs_builds(self):
        hist = [{'input': 10 * GB, 'seconds': 3000, 'space': 20 * GB},
                {'input': 5 * GB, 'seconds': 1000, 'space': 10 * GB},
                {'input': 2 * GB, 'seconds': 99999, 'space': 99 * GB, 'reuse': True}]   # a reused build teaches nothing
        est = qm.Estimator(hist)
        self.assertTrue(est.learned())
        self.assertEqual(est.space(self.item(4)), int(2 * GB * 4))           # 2 GB of space per GB of files
        self.assertEqual(est.seconds(self.item(4)), 300 * 4)                 # the median of 200 and 300 s per GB

    def test_formatting(self):
        en = lambda key, *a: {'queue.minutes': '%d min', 'queue.hours': '%d h %d min'}[key] % a
        self.assertEqual(qm.format_duration(30, en), '1 min')
        self.assertEqual(qm.format_duration(160 * 60, en), '2 h 40 min')
        self.assertEqual(qm.format_bytes(int(12.34 * GB)), '12.3 GB')

    def test_sizes_of_files_and_folders(self):
        d = Path(tempfile.mkdtemp())
        (d / 'a.nsp').write_bytes(b'x' * 1000)
        (d / 'sub').mkdir()
        (d / 'sub' / 'b').write_bytes(b'y' * 500)
        self.assertEqual(qm.path_bytes(str(d / 'a.nsp')), 1000)
        self.assertEqual(qm.path_bytes(str(d)), 1500)
        self.assertEqual(qm.path_bytes(str(d / 'gone')), 0)
        self.assertIsNotNone(qm.free_bytes(str(d / 'not' / 'made' / 'yet')))


@unittest.skipIf(QApplication is None, 'PySide6 is not installed')
class Queue(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.ini = str(self.tmp / 'settings.ini')
        self.keys = self.tmp / 'prod.keys'
        self.keys.write_text('x')
        self.out = self.tmp / 'out'
        self.out.mkdir()

    def model(self):
        from nspb_qt.model import Model
        with mock.patch.object(Model, 'check_deps', lambda self: None):
            m = Model(settings=QSettings(self.ini, QSettings.IniFormat))   # its own: a restart reads it again
        m.repo_path = str(ROOT)
        self.addCleanup(m.deleteLater)
        return m

    def game(self, m, tid: str, size: int = 3000):
        base = self.tmp / f'Game {tid[-4:]} [{tid}][v0].nsp'
        base.write_bytes(b'z' * size)
        m.leave_game_folder()
        m.base_path, m.keys_path, m.out_dir, m.game_dir = str(base), str(self.keys), str(self.out), str(self.tmp)
        return base

    def test_adding_takes_the_game_and_empties_the_rows(self):
        m = self.model()
        with mock.patch.object(type(m), 'repo_ok', new_callable=mock.PropertyMock, return_value=True):
            base = self.game(m, '0100000000000A00')
            self.assertTrue(m.can_queue)
            item = m.add_to_queue()
            self.assertEqual((item.key, item.base, item.keys, item.out_dir), ('0100000000000A00', str(base),
                                                                              str(self.keys), str(self.out)))
            self.assertEqual(item.input_bytes, 3000)
            self.assertEqual((m.base_path, m.game_dir), ('', ''))
            self.assertEqual(m.keys_path, str(self.keys))          # the keys and the output stay for the next game
            self.assertFalse(m.can_queue)
            # the summary counts the queued games and the one chosen above
            self.game(m, '0100000000000B00', size=7000)
            one = m.queue_summary()
            both = m.queue_summary(m.current_queue_item())
            self.assertEqual((one['count'], both['count']), (1, 2))
            self.assertGreater(both['drives'][0]['need'], one['drives'][0]['need'])
            self.assertEqual(both['drives'][0]['after'], both['drives'][0]['free'] - both['drives'][0]['need'])

    def test_the_queue_builds_each_game_and_goes_on_after_a_failure(self):
        m = self.model()
        with mock.patch.object(type(m), 'repo_ok', new_callable=mock.PropertyMock, return_value=True):
            for tid in ('0100000000000A00', '0100000000000B00', '0100000000000C00'):
                self.game(m, tid)
                m.add_to_queue()
        built = []
        m.start_build = lambda: built.append(m.base_path)
        m.start_queue()
        self.assertTrue(m.queue_running)
        self.assertEqual([i.state for i in m.queue], ['running', 'waiting', 'waiting'])
        self.assertIn('0100000000000A00', built[-1])               # its own files were loaded first
        m._queue_on_finished(False, 'it broke')
        self.assertEqual(m.queue[0].state, 'failed')
        m._queue_next()                                            # the window's timer does this 1.5 s later
        self.assertEqual(m.queue[1].state, 'running')
        m._queue_on_finished(True, '')
        m._queue_next()
        m._queue_on_finished(True, '')
        m._queue_next()
        self.assertEqual([i.state for i in m.queue], ['failed', 'done', 'done'])
        self.assertFalse(m.queue_running)
        self.assertEqual(len(built), 3)
        # a finished build teaches the estimates
        self.assertTrue(m.estimator().history)
        m.clear_finished()
        self.assertEqual(m.queue, [])

    def test_shared_app_games_go_onto_the_device_at_the_end(self):
        m = self.model()
        with mock.patch.object(type(m), 'repo_ok', new_callable=mock.PropertyMock, return_value=True):
            for tid in ('0100000000000A00', '0100000000000B00'):
                self.game(m, tid)
                m.add_to_queue()
        m.start_build = lambda: None
        installs = []
        m.install_on_device = lambda udid, titles=None, **k: installs.append((udid, titles))
        m.start_queue()
        for tid in ('0100000000000A00', '0100000000000B00'):
            self.assertTrue(m.queue_defers_install())              # no install per game
            m.queue_built(tid)
            m._queue_on_finished(True, '')
            m._queue_next()
        self.assertEqual(installs, [])                             # no device chosen: nothing to install on
        m._queue_built_titles = ['0100000000000A00', '0100000000000B00']
        m.queue_running = True
        with mock.patch.object(type(m), 'device_install_ready', new_callable=mock.PropertyMock, return_value=True):
            m.install_udid = 'UDID1'
            m.device_by_udid = lambda u: object()
            m.device_titles = lambda u: ['0100000000000F00']
            m._queue_end()
        self.assertEqual(installs, [('UDID1', ['0100000000000A00', '0100000000000B00', '0100000000000F00'])])

    def test_a_queue_started_during_another_run_begins_when_it_ends(self):
        m = self.model()
        with mock.patch.object(type(m), 'repo_ok', new_callable=mock.PropertyMock, return_value=True):
            self.game(m, '0100000000000A00')
            m.add_to_queue()
        built = []
        m.start_build = lambda: built.append(m.base_path)
        m.running = True                                           # an install from the transfer window runs
        m.start_queue()
        self.assertEqual(built, [])
        m.running = False
        m._queue_on_finished(True, 'installed')                    # that run's end, not a queued game's
        deadline = time.time() + 5
        while not built and time.time() < deadline:
            self.app.processEvents()
            time.sleep(0.02)
        self.assertEqual(len(built), 1, 'the queue never started')
        self.assertEqual(m.queue[0].state, 'running')

    def test_a_final_install_that_cannot_start_does_not_swallow_the_next_end(self):
        m = self.model()
        m.queue_running = True
        m._queue_built_titles = ['0100000000000A00']
        m.install_on_device = lambda udid, titles=None, **k: False   # another run is going on
        with mock.patch.object(type(m), 'device_install_ready', new_callable=mock.PropertyMock, return_value=True):
            m.install_udid = 'UDID1'
            m.device_by_udid = lambda u: object()
            m.device_titles = lambda u: []
            m._queue_end()
        self.assertFalse(m._queue_final_install)

    def test_the_page_gets_its_own_choices_back_after_the_queue(self):
        m = self.model()
        with mock.patch.object(type(m), 'repo_ok', new_callable=mock.PropertyMock, return_value=True):
            self.game(m, '0100000000000A00')
            m.add_to_queue()
            m.queue[0].output_mode, m.queue[0].bc_on_cpu = 'ipa', True   # the queued game exports an IPA
            mine = self.game(m, '0100000000000B00')                   # the game the player has on the page now
        m.output_mode, m.bc_on_cpu = 'device', False
        m.remember_choices()
        m.start_build = lambda: None
        m.start_queue()
        self.assertEqual((m.output_mode, m.bc_on_cpu), ('ipa', True))   # the queued game's, while it builds
        m.remember_choices()                                       # the window does this on every refresh
        self.assertEqual(m.settings.value('outputMode'), 'device')  # not saved as the player's
        m._queue_on_finished(True, '')
        m._queue_next()                                            # nothing waits: the queue ends
        self.assertFalse(m.queue_running)
        self.assertEqual((m.output_mode, m.bc_on_cpu, m.base_path), ('device', False, str(mine)))

    def test_the_queue_survives_a_restart(self):
        m = self.model()
        with mock.patch.object(type(m), 'repo_ok', new_callable=mock.PropertyMock, return_value=True):
            self.game(m, '0100000000000A00')
            m.add_to_queue()
        m.queue[0].state = 'running'                               # the app closed during its build
        m._queue_save()
        m.settings.sync()
        again = self.model()                                       # a new start reads the queue back
        self.assertEqual([(i.key, i.state) for i in again.queue], [('0100000000000A00', 'waiting')])

    def test_a_game_whose_files_are_gone_is_skipped(self):
        m = self.model()
        with mock.patch.object(type(m), 'repo_ok', new_callable=mock.PropertyMock, return_value=True):
            base = self.game(m, '0100000000000A00')
            m.add_to_queue()
        base.unlink()
        built = []
        m.start_build = lambda: built.append(1)
        m.start_queue()
        self.assertEqual(built, [])
        self.assertEqual(m.queue[0].state, 'failed')
        self.assertIn('no longer there', m.queue[0].note)


if __name__ == '__main__':
    unittest.main()
