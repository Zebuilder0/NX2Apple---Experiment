"""A run from start to end: Stop, the signing tool's time limit, a build whose archive step and install belong to its
run, the device scans and the automatic update, a second engine sync request, and the inputs a build ends with. The
install part needs no PySide6; the model part runs offscreen with it (skipped without it).

    QT_QPA_PLATFORM=offscreen python3 -m unittest frontend-qt/tests/test_run_lifecycle.py -v
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import qt_sandbox  # noqa: E402,F401  (first: the tests never touch the player's settings or state)
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'frontend-qt'))
os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')

from test_device_install import make_framework, make_template   # noqa: E402
from nspb_qt.win import device as dv   # noqa: E402
from nspb_qt.win import install as wi   # noqa: E402
from nspb_qt.win import shell_export as se   # noqa: E402
from nspb_qt.win import signer   # noqa: E402

try:
    from PySide6.QtCore import QEvent
    from PySide6.QtWidgets import QApplication, QWidget
except ImportError:
    QApplication = None


def shared_app_root(tmp: Path, titles=('0100000000010000', '0100000000020000')) -> tuple[Path, list, Path]:
    """A shell cache with built games, their data folders and an empty shared app."""
    tpl = make_template(tmp / 'tpl')
    library = se.ShellLibrary()
    for tid in titles:
        fw = make_framework(tmp / 'fw', tid, tid)
        library.add(se.ShellGame(tid, tid, str(fw)))
        data = tmp / 'data' / tid
        data.mkdir(parents=True)
        (data / 'romfs.img').write_bytes(b'1234')
    library.save(tmp)
    return tmp, [(tid, tmp / 'data' / tid) for tid in titles], tpl


class InstallStop(unittest.TestCase):
    """Stop is neither a success nor a failure, wherever it lands."""

    def setUp(self):
        self.root, self.data, self.tpl = shared_app_root(Path(tempfile.mkdtemp()))
        self.dev = dv.Device('U', 1, 'USB', 'Phone', '26.0')
        self.stages: list[tuple[str, str]] = []

    def run_install(self, cancelled, copy=None, sign_ok=True):
        copy = copy or (lambda *a, **k: (1, 4))
        with mock.patch.object(dv, 'list_devices', return_value=[self.dev]), \
                mock.patch.object(dv, 'is_paired', return_value=True), \
                mock.patch.object(dv, 'describe', side_effect=lambda d: d), \
                mock.patch.object(dv, 'find_shell', return_value='org.nxnative.shell.T'), \
                mock.patch.object(dv, 'copy_game_data', side_effect=copy), \
                mock.patch.object(wi, 'check_developer_mode', return_value=True), \
                mock.patch.object(signer, 'sign_and_install',
                                  return_value=signer.Result(sign_ok, 'Installation complete' if sign_ok else 'killed')):
            return wi.install(self.root, 'U', data=self.data, template=self.tpl, signer_exe=Path('/bin/true'),
                              cancelled=cancelled, stage=lambda k, st, d, p: self.stages.append((k, st)))

    def test_a_stop_between_games_is_a_stop_not_an_install(self):
        flag = []
        out = self.run_install(lambda: bool(flag), copy=lambda *a, **k: (flag.append(1), (1, 4))[1])
        self.assertFalse(out.ok)
        self.assertTrue(out.stopped)
        self.assertEqual(out.message, ('win.install.stopped',))
        self.assertEqual(out.failure, '')
        self.assertIn(('win.install.stage.data', wi.STOPPED), self.stages)

    def test_a_stop_mid_file_is_a_stop_not_a_copy_failure(self):
        def copy(*a, **k):
            raise dv.Cancelled('the copy was stopped')
        out = self.run_install(lambda: False, copy=copy)
        self.assertTrue(out.stopped)
        self.assertEqual(out.failure, '')

    def test_a_stop_that_ends_the_copy_with_another_error_is_still_a_stop(self):
        flag = []

        def copy(*a, **k):
            flag.append(1)
            raise dv.DeviceError('the device connection closed')
        out = self.run_install(lambda: bool(flag), copy=copy)
        self.assertTrue(out.stopped)

    def test_a_copy_error_without_a_stop_is_a_failure(self):
        def copy(*a, **k):
            raise dv.DeviceError('the device connection closed')
        out = self.run_install(lambda: False, copy=copy)
        self.assertFalse(out.stopped)
        self.assertEqual(out.message[0], 'win.install.dataFailed')

    def test_a_stop_during_signing_is_a_stop(self):
        out = self.run_install(lambda: True, sign_ok=False)
        self.assertTrue(out.stopped)
        self.assertIn(('win.install.stage.sign', wi.STOPPED), self.stages)

    def test_a_stop_after_a_finished_signing_keeps_the_app_it_installed(self):
        out = self.run_install(lambda: any(k == 'win.install.stage.sign' and st == 'done' for k, st in self.stages))
        self.assertTrue(out.stopped)
        self.assertEqual(wi.Devices(self.root).get('U').bundle, 'org.nxnative.shell.T')

    def test_without_a_stop_it_installs(self):
        out = self.run_install(lambda: False)
        self.assertTrue(out.ok)
        self.assertFalse(out.stopped)
        self.assertEqual(out.copied_files, 2)


@unittest.skipIf(os.name == 'nt', 'the pretend signer is a POSIX script')
class SignerTimeLimit(unittest.TestCase):
    def test_a_signer_that_hangs_is_ended_at_the_limit(self):
        tmp = Path(tempfile.mkdtemp())
        hang = tmp / 'plumesign'
        # the shell starts sleep as a child that holds the output pipe: ending the shell alone kept the run waiting
        hang.write_text('#!/bin/sh\necho start\nsleep 30\necho late\n')
        hang.chmod(0o755)
        t0 = time.time()
        with mock.patch.object(signer, 'SIGN_TIMEOUT', 1):
            r = signer.sign_and_install(tmp / 'DmShell.app', 3, exe=hang)
        self.assertLess(time.time() - t0, 8, 'the time limit did not end the signing tool and what it started')
        self.assertFalse(r.ok)
        self.assertEqual(r.failure, 'win.sign.fail.network')
        self.assertIn('did not finish in time', r.output)

    def test_a_signer_within_the_limit_is_not_ended(self):
        tmp = Path(tempfile.mkdtemp())
        ok = tmp / 'plumesign'
        ok.write_text('#!/bin/sh\necho "Installation progress: 50%"\necho "Installation complete"\n')
        ok.chmod(0o755)
        with mock.patch.object(signer, 'SIGN_TIMEOUT', 30):
            r = signer.sign_and_install(tmp / 'DmShell.app', 3, exe=ok)
        self.assertTrue(r.ok, r.output)


class Sandbox(unittest.TestCase):
    def test_every_test_that_builds_the_app_keeps_the_players_state_out_of_reach(self):
        """A test module that builds the Model, the window or the library imports qt_sandbox first: the app has no
        test switch of its own, so without it the test would write into the player's settings and log."""
        here = Path(__file__).resolve().parent
        builds = re.compile(r'\bModel\(|\bMainWindow\(|\bGameLibrary\(|\bArtworkStore\(')
        missing = [f.name for f in sorted(here.glob('test_*.py'))
                   if builds.search(f.read_text(encoding='utf-8'))
                   and 'import qt_sandbox' not in f.read_text(encoding='utf-8')]
        self.assertEqual(missing, [])

    def test_the_sandbox_is_where_the_state_the_settings_and_the_log_go(self):
        from nspb_qt import library as lib
        self.assertEqual(str(lib.default_state_dir()), qt_sandbox.STATE_DIR)
        if QApplication is None:
            return
        from nspb_qt.model import Model
        QApplication.instance() or QApplication([])
        with mock.patch.object(Model, 'check_deps', lambda self: None):
            m = Model()
        self.addCleanup(m.deleteLater)
        self.assertTrue(str(m.settings.fileName()).startswith(qt_sandbox.STATE_DIR))
        self.assertEqual(Path(m.log_path).parent, Path(qt_sandbox.STATE_DIR) / 'logs')


class Waits:
    def wait(self, cond, seconds=10.0):
        deadline = time.time() + seconds
        while time.time() < deadline:
            self.app.processEvents()
            if cond():
                return True
            time.sleep(0.01)
        return False


@unittest.skipIf(QApplication is None, 'PySide6 is not installed')
class ModelRuns(Waits, unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def model(self):
        from nspb_qt.model import Model
        with mock.patch.object(Model, 'check_deps', lambda self: None):
            m = Model()
        self.addCleanup(m.deleteLater)
        self.ends: list[tuple[bool, str]] = []
        m.finished.connect(lambda ok, note: self.ends.append((ok, note)))
        return m

    def archive_inputs(self, m, packed=True) -> Path:
        """A finished build's work folder: its RomFS image (packed), or its RomFS folder for the packer to pack."""
        work = Path(tempfile.mkdtemp())
        v0 = work / 'extract' / 'v0'
        if packed:
            v0.mkdir(parents=True)
            (v0 / 'RomFS.img').write_bytes(b'DMROMFS1')
        else:
            (v0 / 'RomFS').mkdir(parents=True)
        m.effective_work_dir = str(work)
        m.base_path = str(work / 'Game [0100ABCD00000000][v0].nsp')
        m.out_dir = str(work / 'out')
        return work / 'out' / 'games' / '0100ABCD00000000'

    def test_the_archive_step_and_what_follows_belong_to_the_run(self):
        m = self.model()
        dest = self.archive_inputs(m)
        self.assertTrue(m.begin_run('build'))
        seen = []

        def record(*a, **k):
            seen.append((m.running, m.begin_run('install')))   # still running: nothing else can start in the gap
        with mock.patch.object(m, '_record_library_ios_completion', side_effect=record):
            ok, _note = m.pack_archive('0100ABCD00000000')
        self.assertTrue(ok)
        self.assertEqual(seen, [(True, False)])
        self.assertTrue((dest / 'romfs.img').is_file())
        m.end_run(True, 'done')
        self.assertEqual(self.ends, [(True, 'done')])
        self.assertFalse(m.running)

    def test_a_built_game_installs_as_the_rest_of_its_run(self):
        m = self.model()
        m.begin_run('build')
        calls = []
        lib = se.ShellLibrary(games=[se.ShellGame('0100ABCD00000000', 'Game', '/fw')])
        with mock.patch.object(se, 'add_to_library', return_value=(lib, [], '')), \
                mock.patch.object(type(m), 'device_install_ready', new_callable=mock.PropertyMock, return_value=True):
            m.install_udid = 'U'
            m.device_by_udid = lambda u: object()
            m.device_titles = lambda u: []
            m._install = lambda udid, **k: calls.append((udid, m.running, m.run_kind)) or (True, 'installed', False)
            out = m.after_framework_build(Path('/fw'), '0100ABCD00000000', 'Game', '')
        self.assertEqual(calls, [('U', True, 'install')])     # the same run, now labelled an install
        self.assertEqual(out, (True, 'installed'))
        self.assertEqual(self.ends, [])                        # the build's worker ends the run, not this step

    def test_a_built_game_goes_where_it_was_meant_to_when_build_was_pressed(self):
        """N2: Play on switched to Export as IPA while the build ran: the game still installs, as chosen at the start."""
        from nspb_qt import model as mm
        from nspb_qt.model import RunInputs
        m = self.model()
        work = Path(tempfile.mkdtemp())
        fw = make_framework(work / 'shell-framework', '0100ABCD00000000', 'Game')
        m.begin_run('build')
        m.run_inputs = RunInputs(work_dir=str(work), tid_hex='0100ABCD00000000', output_mode='device')
        m.output_mode = 'ipa'                       # the page now
        m.effective_work_dir = ''                   # and another game opened from the library
        installs, exports = [], []
        with mock.patch.object(mm.pu, 'IS_WIN', True), \
                mock.patch.object(se, 'export_shell', side_effect=lambda **k: exports.append(k) or (True, '', '', [])), \
                mock.patch.object(m, '_record_library_ios_completion'):
            m.after_framework_build = lambda f, tid, name, arch: installs.append((Path(f), tid)) or (True, 'installed')
            ok, note = m._export_shell_after_archive(True, '')
        self.assertEqual((installs, exports), ([(fw, '0100ABCD00000000')], []))
        self.assertEqual((ok, note), (True, 'installed'))

    def test_stop_ends_the_tool_that_runs_now(self):
        m = self.model()
        m.begin_run('install')
        m._proc = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])
        p = m._proc
        m.cancel_install()                          # the transfer window's Stop
        self.assertTrue(m.cancel_requested)
        p.wait(timeout=10)
        self.assertIsNotNone(p.returncode)

    def test_a_stop_during_the_packer_ends_it_and_the_archive_step(self):
        """H2: the RomFS packer can run for minutes; Stop ends it, and the step says stopped, not failed."""
        from nspb_qt import model as mm
        m = self.model()
        self.archive_inputs(m, packed=False)
        m.begin_run('build')
        started = threading.Event()
        real_popen = subprocess.Popen

        def packer(args, **k):
            started.set()
            return real_popen([sys.executable, '-c', 'import time; time.sleep(30)'], stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, text=True)
        result = []
        with mock.patch.object(mm.subprocess, 'Popen', side_effect=packer):
            t = threading.Thread(target=lambda: result.append(m.pack_archive('0100ABCD00000000')))
            t.start()
            self.assertTrue(started.wait(10))
            self.assertTrue(self.wait(lambda: m._proc is not None))
            t0 = time.time()
            m.cancel_run()
            t.join(10)
        self.assertLess(time.time() - t0, 8)
        self.assertEqual(result, [(False, '')])
        self.assertEqual(m.stages[-1].state, 'stopped')
        self.assertEqual(m.archive_path, '')

    def test_an_install_that_cannot_start_says_so(self):
        m = self.model()
        m.begin_run('build')
        self.assertFalse(m.install_on_device('U'))
        self.assertEqual(self.ends, [])

    def test_a_device_scan_always_ends_and_requests_coalesce(self):
        from nspb_qt import device_model as dm
        m = self.model()
        changed = []
        m.devicesChanged.connect(lambda: changed.append(1))
        gate = threading.Event()
        scans = []

        def listing(*a, **k):
            scans.append(1)
            gate.wait(5)
            return [dv.Device('U', 1)]
        with mock.patch.object(dm, 'emit_safely', side_effect=lambda sig, *a: sig.emit(*a)), \
                mock.patch.object(dv, 'list_devices', side_effect=listing), \
                mock.patch.object(dv, 'describe', side_effect=RuntimeError('a bug in describe')):
            m.refresh_devices()
            self.assertTrue(self.wait(lambda: bool(scans)))
            m.refresh_devices()                     # while one runs: remembered, not a second thread
            m.refresh_devices()
            gate.set()
            self.assertTrue(self.wait(lambda: len(changed) >= 2))
            time.sleep(0.2)
            self.app.processEvents()
        self.assertEqual(len(scans), 2)             # the running scan, then one more for both requests
        self.assertEqual(m.devices, [])
        self.assertIn('a bug in describe', m.devices_note)

    def test_every_new_device_is_updated_one_tick_after_another(self):
        from nspb_qt import device_model as dm
        m = self.model()
        asked = []
        m.autoInstallRequested.disconnect()
        m.autoInstallRequested.connect(lambda u: asked.append(u))
        st = wi.DeviceState(bundle='org.nxnative.shell.T', signed=0)

        class Inline:
            def __init__(self, target, daemon):
                self.f = target

            def start(self):
                self.f()
        with mock.patch.object(type(m), 'device_install_ready', new_callable=mock.PropertyMock, return_value=True), \
                mock.patch.object(dv, 'list_devices', return_value=[dv.Device('A', 1), dv.Device('B', 2)]), \
                mock.patch.object(wi.Devices, 'get', return_value=st), \
                mock.patch.object(wi, 'device_games', return_value=[]), \
                mock.patch.object(se, 'find_shell_template', return_value=None), \
                mock.patch.object(dm.threading, 'Thread', Inline), \
                mock.patch.object(type(m), 'refresh_devices', lambda self: None):
            for _ in range(3):
                m._auto_tick()
                self.app.processEvents()
        self.assertEqual(asked, ['A', 'B'])

    def test_an_automatic_update_that_could_not_start_is_asked_again(self):
        m = self.model()
        m.begin_run('build')
        m._auto_seen = {'A'}
        m._on_auto_install('A')
        self.assertNotIn('A', m._auto_seen)

    def test_a_second_sync_request_hears_the_real_end(self):
        """L6: Build pressed while the engine syncs waits for that sync's end, instead of being told at once that it
        ended (and then finding the engine still stale)."""
        from nspb_qt import engine
        from nspb_qt import model as mm
        m = self.model()
        release = threading.Event()
        answers = []

        def run_sync(*a, **k):
            release.wait(5)
            return False, engine.ENGINE_SYNC
        with mock.patch.object(engine, 'is_stale', return_value=True), \
                mock.patch.object(engine, 'run_sync', side_effect=run_sync), \
                mock.patch.object(mm.pu, 'IS_WIN', False):
            m.sync_engine(lambda ok: answers.append(('first', ok)))
            m.sync_engine(lambda ok: answers.append(('second', ok)))
            self.assertEqual(answers, [])           # not True at once: the sync has not ended
            release.set()
            self.assertTrue(self.wait(lambda: len(answers) == 2))
        self.assertEqual(sorted(answers), [('first', False), ('second', False)])


@unittest.skipIf(QApplication is None, 'PySide6 is not installed')
class WholeBuilds(Waits, unittest.TestCase):
    """start_build to the run's end, with the build script replaced: N2 (the inputs the build ends with) and Stop."""

    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def setUp(self):
        from nspb_qt.model import Model
        tmp = Path(tempfile.mkdtemp())
        self.a, self.b = tmp / 'a', tmp / 'b'
        self.a.mkdir()
        self.b.mkdir()
        self.base_a = self.a / 'Game A [0100000000010000][v0].nsp'
        self.upd_a = self.a / 'Game A [0100000000010800][v65536].nsp'
        self.base_b = self.b / 'Game B [0100000000020000][v0].nsp'
        keys = tmp / 'prod.keys'
        for f in (self.base_a, self.upd_a, self.base_b, keys):
            f.write_bytes(b'x')
        with mock.patch.object(Model, 'check_deps', lambda self: None):
            self.m = Model()
        self.addCleanup(self.m.deleteLater)
        m = self.m
        m.base_path, m.update_path, m.keys_path, m.out_dir = str(self.base_a), str(self.upd_a), str(keys), str(tmp / 'out')
        m.ipa_kind = 'oneGame'                   # a one-game IPA: the run ends by recording it in the library
        m.output_mode = 'ipa'
        self.release = threading.Event()
        self.ends: list[bool] = []
        m.finished.connect(lambda ok, note: self.ends.append(ok))

    def script(self, test):
        """The build script: it runs until the test lets it go (or Stop ends it), then exits."""
        release = self.release

        class Build:
            pid = 0

            def __init__(self, *a, **k):
                self.returncode = None
                self.stdout = self.lines()

            def lines(self):
                yield '[1/1] build\n'
                release.wait(10)

            def wait(self, timeout=None):
                if self.returncode is None:
                    self.returncode = -15 if test.stopped else 0
                return self.returncode

            def poll(self):
                return self.returncode

            def terminate(self):
                test.stopped = True
                release.set()
        self.stopped = False
        return Build

    def start(self):
        from nspb_qt import engine as eng
        from nspb_qt import model as mm
        from nspb_qt.model import Model
        m = self.m
        return (mock.patch.object(type(m), 'repo_ok', new_callable=mock.PropertyMock, return_value=True),
                mock.patch.object(eng, 'needs_sync_before_build', return_value=False),
                mock.patch.object(Model, 'supports_work_dir', lambda self: True),
                mock.patch.object(mm.subprocess, 'Popen', self.script(self)))

    def test_the_library_records_the_files_the_build_started_with(self):
        m = self.m
        p1, p2, p3, p4 = self.start()
        with p1, p2, p3, p4:
            m.start_build()
            self.assertTrue(m.running)
            # meanwhile, on the page: the next game, as the file picker, a drop or Add to queue leaves it
            m.leave_game_folder()
            m.base_path, m.update_path, m.dlc_paths = str(self.base_b), '', []
            m.effective_work_dir = ''               # as load_game_from_library leaves it
            self.release.set()
            self.assertTrue(self.wait(lambda: bool(self.ends)))
        self.assertEqual(self.ends, [True])
        built = next(g for g in m.library.games if g.title_id == '0100000000010000')
        self.assertEqual(built.inputs.get('base'), [str(self.base_a)])
        self.assertEqual(built.inputs.get('update'), [str(self.upd_a)])
        self.assertFalse(any(g.title_id == '0100000000020000' for g in m.library.games),
                         'the game picked during the build was recorded as the one built')

    def test_a_stopped_build_ends_as_stopped_not_as_a_failure(self):
        m = self.m
        p1, p2, p3, p4 = self.start()
        with p1, p2, p3, p4:
            m.start_build()
            self.assertTrue(self.wait(lambda: m._proc is not None))
            m.cancel_build()                         # the activity bar's Stop
            self.assertTrue(self.wait(lambda: bool(self.ends)))
        self.assertEqual(self.ends, [False])
        self.assertTrue(m.run_stopped)
        self.assertIsNone(m.failure)                 # no failure card for a stop
        self.assertFalse(any(st.state == 'failed' for st in m.stages))
        self.assertFalse(m.running)
        # the next run starts clean
        self.assertTrue(m.begin_run('build'))
        self.assertFalse(m.cancel_requested)
        self.assertFalse(m.run_stopped)
        m.end_run(True, '')


@unittest.skipIf(QApplication is None, 'PySide6 is not installed')
class TransferWindowLifetime(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def test_a_closed_transfer_window_hears_nothing_more(self):
        from PySide6.QtCore import QObject, Signal
        from nspb_qt import transfer

        class Model(QObject):
            devicesChanged, depsChanged, stagesChanged = Signal(), Signal(), Signal()
            runningChanged, logAppended, finished = Signal(bool), Signal(str), Signal(bool, str)
            devices, install_udid, running, stages, device_install_ready = [], '', False, [], True

            def t(self, k, *a):
                return k

            def refresh_devices(self):
                pass

            def cancel_install(self):
                pass

            def built_games(self):
                return []

            def device_titles(self, u):
                return []

            def device_by_udid(self, u):
                return None

            def device_label(self, d):
                return ''
        m = Model()
        parent = QWidget()
        d = transfer.TransferDialog(m, parent)
        d.deleteLater()
        self.app.sendPostedEvents(None, QEvent.DeferredDelete)
        errors = []
        old = sys.excepthook
        sys.excepthook = lambda *a: errors.append(a[1])
        try:
            m.runningChanged.emit(True)
            m.depsChanged.emit()
            m.finished.emit(True, '')
            self.app.processEvents()
        finally:
            sys.excepthook = old
        self.assertEqual(errors, [])


if __name__ == '__main__':
    unittest.main()
