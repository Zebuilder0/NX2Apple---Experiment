"""The window's part of the Windows install on a device: the device rows of the dependency panel (Get iTunes,
Sign in, Sign out), the Install on device row of the install card and its button text, and the auto-update
switch. Runs offscreen with PySide6 (skipped without it), with the Windows branch switched on and no device.

    QT_QPA_PLATFORM=offscreen python3 -m unittest frontend-qt/tests/test_device_window.py -v
"""
from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import qt_sandbox  # noqa: E402,F401  (first: the tests never touch the player's settings or state)
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'frontend-qt'))
os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')

try:
    from PySide6.QtCore import QEvent
    from PySide6.QtWidgets import QApplication, QPushButton
except ImportError:
    QApplication = None


@unittest.skipIf(QApplication is None, 'PySide6 is not installed')
class DeviceWindow(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def _window(self, deps):
        from nspb_qt import platform_util as pu
        from nspb_qt.i18n import Lang
        from nspb_qt.model import Model
        from nspb_qt.ui import MainWindow
        cache = tempfile.mkdtemp()
        for p in (mock.patch.object(Model, 'check_deps', lambda self: None),
                  mock.patch.object(Model, 'refresh_devices', lambda self: None),
                  mock.patch.object(Model, 'shell_cache_path', new_callable=mock.PropertyMock, return_value=cache),
                  mock.patch.object(pu, 'IS_WIN', True)):
            p.start()
            self.addCleanup(p.stop)
        m = Model()
        m.lang = Lang('en')
        m.deps, m.deps_checked = deps, True
        w = MainWindow(m)

        def close():
            w.close()
            w.deleteLater()
            m.deleteLater()
            self.app.sendPostedEvents(None, QEvent.DeferredDelete)
            self.app.processEvents()
        self.addCleanup(close)
        w.show()
        for _ in range(3):
            self.app.processEvents()
        w._refresh_deps()
        w._refresh_install_card()
        return m, w

    @staticmethod
    def _rows(*, signed_in=False, ready=True):
        from nspb_qt.model import Dep, DepState
        ok, no = DepState.OK, DepState.MISSING
        return [Dep('python', 'dep.python', 'dep.python.hint', ok, 'python.exe'),
                Dep('amds', 'win.dep.amds', 'win.dep.amds.hint', ok if ready else no, '', required=False),
                Dep('signer', 'win.dep.signer', 'win.dep.signer.hint', ok, 'plumesign.exe', required=False),
                Dep('apple_id', 'win.dep.appleId', 'win.dep.appleId.hint', ok if signed_in else no,
                    'j…@example.com' if signed_in else '', required=False),
                Dep('shell_template', 'win.dep.template', 'win.dep.template.hint', ok, 'DmShell.app', required=False)]

    def _buttons(self, w, host='device_deps_host'):
        return [b.text() for b in getattr(w, host).findChildren(QPushButton)]

    def test_rows_offer_itunes_and_sign_in(self):
        m, w = self._window(self._rows(signed_in=False, ready=False))
        texts = self._buttons(w)
        self.assertIn('Get iTunes', texts)
        self.assertIn('Sign in…', texts)
        # the device rows have their own section: the build tools list keeps only the build's rows
        self.assertNotIn('Get iTunes', self._buttons(w, 'deps_rows_host'))
        self.assertFalse(m.device_install_ready)
        self.assertTrue(w.device_group.isVisibleTo(w))
        self.assertIn('Settings, iPhone and iPad', w.win_dev_note.text())
        self.assertEqual(w.win_id_btn.text(), 'Sign in…')
        # the optional rows do not hold the build back
        self.assertTrue(m.all_deps_ok)

    def test_signed_in_offers_sign_out_and_waits_for_a_device(self):
        m, w = self._window(self._rows(signed_in=True))
        self.assertIn('Sign out', self._buttons(w))
        self.assertEqual(w.win_id_btn.text(), 'Sign out')
        self.assertIn('j…@example.com', w.win_id_note.text())
        self.assertTrue(m.device_install_ready)
        self.assertIn('No iPhone or iPad connected', w.win_dev_note.text())
        self.assertFalse(w.settings_install_btn.isEnabled())     # no game built for the shared app yet

    def test_a_known_device_shows_when_it_was_signed(self):
        from nspb_qt.win import device as dv
        from nspb_qt.win import install as wi
        m, w = self._window(self._rows(signed_in=True))
        m.devices = [dv.Device('UDID1', 7, 'USB', 'Jane’s iPhone')]
        m.install_udid = 'UDID1'
        wi.Devices(Path(m.shell_cache_path)).put('UDID1', wi.DeviceState(bundle='org.nxnative.shell.T', signed=1.0))
        w._refresh_install_card()
        self.assertEqual(w.win_dev_combo.currentText(), 'Jane’s iPhone')
        self.assertIn('Last signed', w.win_dev_note.text())

    def test_play_on_switches_between_the_device_and_an_ipa(self):
        m, w = self._window(self._rows(signed_in=True))
        self.assertEqual(m.output_mode, 'device')
        self.assertTrue(w.play_device_card.is_selected())
        self.assertTrue(w.device_group.isVisibleTo(w))
        self.assertFalse(w.install_group.isVisibleTo(w))      # no IPA steps when the build goes to a device
        self.assertTrue(w.bc_card.isVisibleTo(w))             # Older devices: under Play on, above Install
        self.assertTrue(m.bc_on_cpu)                          # on by default on Windows: one build plays everywhere
        self.assertIn('every game built now plays on all iPhones and iPads', w.bc_note_lbl.text())
        w.bc_switch.toggled.emit(False)
        self.assertFalse(m.bc_on_cpu)
        self.assertIn('only on the iPhone 15 Pro', w.bc_note_lbl.text())
        w.bc_switch.toggled.emit(True)
        w.play_ipa_card.clicked.emit()
        self.assertEqual(m.output_mode, 'ipa')
        self.assertTrue(w.play_ipa_card.is_selected())
        self.assertFalse(w.device_group.isVisibleTo(w))
        self.assertTrue(w.install_group.isVisibleTo(w))
        self.assertFalse(m.exports_one_game)
        w._on_ipa_kind_changed('oneGame')
        self.assertTrue(m.exports_one_game)
        self.assertTrue(w.bc_card.isVisibleTo(w))             # a one-game IPA takes the switch too
        w._set_output_mode('device')
        self.assertFalse(m.exports_one_game)                  # the kind of IPA does not apply to a device

    def test_settings_switches_are_saved(self):
        m, w = self._window(self._rows(signed_in=True))
        for switch, read, write in ((w.auto_switch, 'auto_update_launcher', m.set_auto_update_launcher),
                                    (w.offer_switch, 'offer_new_devices', m.set_offer_new_devices)):
            start = getattr(m, read)
            switch.toggled.emit(not start)
            self.assertEqual(getattr(m, read), not start)
            write(start)

    def test_a_wheel_turns_while_work_runs(self):
        from nspb_qt.widgets import Spinner
        m, w = self._window(self._rows(signed_in=True))
        wheel = Spinner(16)
        self.assertFalse(wheel.is_spinning())
        wheel.set_spinning(True)
        self.assertTrue(wheel.is_spinning())
        wheel.grab()                                   # paints without an error
        wheel.set_spinning(False)
        self.assertTrue(wheel.isHidden())
        # while the check runs (Model.check_deps emits at once: SavedChoices tests it), the panel shows its wheel
        m.deps_checked = False
        w._refresh_deps()
        self.assertTrue(w.deps_spinner.is_spinning())
        self.assertTrue(w.act_spinner.is_spinning())
        self.assertFalse(w.recheck_btn.isEnabled())
        m.deps_checked = True
        w._refresh_deps()
        self.assertFalse(w.deps_spinner.is_spinning())
        # the Apple ID row waits for its sign-in window
        m.signing_in = True
        w._refresh_deps()
        self.assertTrue(any(s.is_spinning() for s in w.device_deps_host.findChildren(Spinner)))
        m.signing_in = False

    def test_the_transfer_shows_the_game_the_time_left_and_the_clock(self):
        import time
        from nspb_qt.model import Stage
        from nspb_qt.transfer import TransferDialog, copy_lines, finish_clock, install_fraction
        from nspb_qt.win import device as dv
        m, w = self._window(self._rows(signed_in=True))
        self._built(m, '0100000000000A00', '0100000000000B00')
        m.devices = [dv.Device('UDID1', 7, 'USB', 'Jane’s iPhone')]
        info = {'game': 'Game 0A00', 'number': 2, 'count': 3, 'done': 14_200_000_000, 'total': 31_600_000_000,
                'rate': 38_000_000, 'left': 420.0, 'at': time.time()}
        game, size, eta = copy_lines(m, info)
        self.assertEqual(game, 'Copying Game 0A00 · game 2 of 3')
        self.assertEqual(size, '14.2 of 31.6 GB · 38 MB/s')
        self.assertTrue(eta.startswith('About 7 min left · done around '))
        self.assertIn(finish_clock(420.0, info['at']), eta)
        self.assertEqual(copy_lines(m, dict(info, left=None, rate=None))[2], 'Working out the time left…')
        # the bar: a fifth for preparing and signing, the rest by bytes
        self.assertAlmostEqual(install_fraction([], info, m.t), 0.2 + 0.8 * 14.2 / 31.6, places=3)
        signing = [Stage(m.t('win.install.stage.prepare'), 'done'), Stage(m.t('win.install.stage.sign'), 'running', '', 50.0)]
        self.assertAlmostEqual(install_fraction(signing, None, m.t), 0.125)
        # in the window, while it copies
        m.transfer_games = lambda udid, titles: True      # it started
        d = TransferDialog(m, w, udid='UDID1')
        self.addCleanup(d.deleteLater)
        d._start()
        m.stages = signing
        m.transfer_info = info
        d._on_stages()
        self.assertTrue(d.copy_box.isVisibleTo(d))
        self.assertEqual(d.copy_game.text(), 'Copying Game 0A00 · game 2 of 3')
        self.assertTrue(d.progress.spinner.is_spinning())
        w.transfer_toast.follow(d)
        self.assertIn('Copying Game 0A00', w.transfer_toast.stage.text())
        m.transfer_info = None

    def test_an_older_device_gets_only_the_games_that_play_on_it(self):
        from nspb_qt.transfer import TransferDialog
        from nspb_qt.win import device as dv
        m, w = self._window(self._rows(signed_in=True))
        self._built(m, '0100000000000A00', '0100000000000B00')
        # A was built with Older devices on, B without
        fw = Path(m.shell_cache_path) / 'frameworks' / 'DmGame0100000000000A00.framework' / 'dm'
        fw.mkdir(parents=True, exist_ok=True)
        (fw / 'env.txt').write_text('DM_PROF_TEX_BC_CPU=1\n')
        self.assertTrue(m.game_plays_on_older('0100000000000A00'))
        self.assertFalse(m.game_plays_on_older('0100000000000B00'))
        m.devices = [dv.Device('OLD', 7, 'USB', 'Jane’s iPhone', '26.0', 'iPhone15,3'),
                     dv.Device('NEW', 8, 'USB', 'Kat’s iPad', '26.0', 'iPad14,5')]
        old = TransferDialog(m, w, udid='OLD')
        self.addCleanup(old.deleteLater)
        self.assertEqual(old.titles(), ['0100000000000A00'])          # B would stop at its start: not ticked
        self.assertIn('older GPU', old.gpu_note.text())
        old._checks['0100000000000B00'].setChecked(True)
        self.assertIn('Built for newer devices only', old.hint.text())
        new = TransferDialog(m, w, udid='NEW')
        self.addCleanup(new.deleteLater)
        self.assertEqual(new.titles(), ['0100000000000A00', '0100000000000B00'])
        self.assertIn('plays every game', new.gpu_note.text())
        # the library says which devices a game plays on
        m.library.games = [type('G', (), {'title_id': '0100000000000B00'})()]
        self.assertFalse(m.game_plays_on_older('0100000000000B00'))

    def _built(self, m, *tids):
        import json
        from nspb_qt import shell
        root = Path(m.shell_cache_path)
        for tid in tids:
            fw = root / 'frameworks' / f'DmGame{tid}.framework'
            fw.mkdir(parents=True, exist_ok=True)
            (fw / 'game.manifest.json').write_text(json.dumps({'title_id': tid, 'name': 'Game ' + tid[-4:]}))
            lib = shell.Library.load(root)
            lib.add(shell.Game(tid, 'Game ' + tid[-4:], str(fw)))
            lib.save(root)

    def test_transfer_ticks_the_device_games_and_the_chosen_one(self):
        from nspb_qt.transfer import TransferDialog
        from nspb_qt.win import device as dv
        from nspb_qt.win import install as wi
        m, w = self._window(self._rows(signed_in=True))
        self._built(m, '0100000000000A00', '0100000000000B00', '0100000000000C00')
        m.devices = [dv.Device('UDID1', 7, 'USB', 'Jane’s iPhone')]
        wi.Devices(Path(m.shell_cache_path)).put('UDID1', wi.DeviceState(bundle='org.nxnative.shell.T', signed=1.0,
                                                                         titles=['0100000000000A00']))
        started = []
        m.transfer_games = lambda udid, titles: started.append((udid, titles)) or True   # it started
        d = TransferDialog(m, w, udid='UDID1', preselect=['0100000000000C00'])
        self.addCleanup(d.deleteLater)
        self.assertEqual(d.titles(), ['0100000000000A00', '0100000000000C00'])
        self.assertEqual(d.go_btn.text(), 'Transfer')                 # the device has the app: it is updated
        self.assertTrue(d.go_btn.isEnabled())
        d._checks['0100000000000A00'].setChecked(False)
        self.assertIn('1 game(s) on the device are not ticked', d.hint.text())
        d._start()
        self.assertEqual(started, [('UDID1', ['0100000000000C00'])])
        self.assertTrue(d.active)
        # closed while it runs: the corner card follows it
        d.close()
        self.assertFalse(d.isVisible())
        w.transfer_toast.follow(d)
        self.assertTrue(w.transfer_toast.isVisible())
        self.assertIn('Jane’s iPhone', w.transfer_toast.title.text())
        m.finished.emit(True, 'Installed on Jane’s iPhone')
        self.assertFalse(d.active)
        self.assertEqual(d.finished_ok, True)
        self.assertEqual(w.transfer_toast.pct.text(), '100%')

    def test_a_new_device_without_the_app_gets_the_question(self):
        from nspb_qt.win import device as dv
        m, w = self._window(self._rows(signed_in=True))
        self._built(m, '0100000000000A00')
        m.devices = [dv.Device('UDID2', 9, 'USB', 'Kat’s iPad')]
        m.newDeviceFound.emit('UDID2')
        d = w._transfer
        self.assertIsNotNone(d)
        self.assertTrue(d.new_device)
        self.assertIn('Kat’s iPad is connected', d.head.text())
        self.assertEqual(d.titles(), ['0100000000000A00'])        # never installed: every built game is ticked
        self.assertEqual(d.go_btn.text(), 'Install')
        d.close()


@unittest.skipIf(QApplication is None, 'PySide6 is not installed')
class SavedChoices(unittest.TestCase):
    """prod.keys, the output folder, the output mode and the last game last from one start to the next."""

    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def test_check_again_says_checking_at_once(self):
        from nspb_qt.model import Model
        real = Model.check_deps
        with mock.patch.object(Model, 'check_deps', lambda self: None):
            m = Model()
        self.addCleanup(m.deleteLater)
        emitted = []
        m.depsChanged.connect(lambda: emitted.append(m.deps_checked))
        with mock.patch.object(Model, 'sync_engine', lambda self: None), \
                mock.patch('threading.Thread.start', lambda self: None):
            real(m)
        self.assertEqual(emitted, [False])          # before the check's thread has done anything

    def test_choices_come_back_at_the_next_start(self):
        from PySide6.QtCore import QSettings
        from nspb_qt.model import Model
        tmp = Path(tempfile.mkdtemp())
        keys = tmp / 'prod.keys'
        keys.write_text('header_key = 00\n')
        base = tmp / 'Game [0100ABCD00000000][v0].nsp'
        base.write_bytes(b'x')
        out = tmp / 'out'
        out.mkdir()
        ini = str(tmp / 'settings.ini')

        def model():
            with mock.patch.object(Model, 'check_deps', lambda self: None):
                m = Model()
            m.settings = QSettings(ini, QSettings.IniFormat)
            m._persist_choices = True
            self.addCleanup(m.deleteLater)
            return m
        a = model()
        a.keys_path, a.base_path, a.out_dir, a.game_dir = str(keys), str(base), str(out), str(tmp)
        a.output_mode, a.ipa_kind, a.bc_on_cpu = 'ipa', 'oneGame', True
        a.remember_choices()
        a.settings.sync()
        b = model()
        b.restore_choices()
        self.assertEqual((b.keys_path, b.base_path, b.out_dir, b.game_dir), (str(keys), str(base), str(out), str(tmp)))
        self.assertEqual((b.ipa_kind, b.bc_on_cpu), ('oneGame', True))
        # a file that is gone is not brought back, and the games folder is the output when none was chosen
        keys.unlink()
        b.settings.setValue('buildOutputDirectory', '')
        b.library.games_folder = str(tmp)
        c = model()
        c.library.games_folder = str(tmp)
        c.restore_choices()
        self.assertEqual(c.keys_path, '')
        self.assertEqual(c.out_dir, str(tmp))


if __name__ == '__main__':
    unittest.main()
