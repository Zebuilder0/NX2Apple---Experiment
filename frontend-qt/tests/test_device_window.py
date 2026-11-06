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

    def _buttons(self, w):
        return [b.text() for b in w.deps_rows_host.findChildren(QPushButton)]

    def test_rows_offer_itunes_and_sign_in(self):
        m, w = self._window(self._rows(signed_in=False, ready=False))
        texts = self._buttons(w)
        self.assertIn('Get iTunes', texts)
        self.assertIn('Sign in…', texts)
        self.assertFalse(m.device_install_ready)
        self.assertTrue(w.win_dev_container.isVisibleTo(w))
        self.assertFalse(w.win_install_btn.isEnabled())
        self.assertIn('Settings, Device dependencies', w.win_dev_note.text())
        # the optional rows do not hold the build back
        self.assertTrue(m.all_deps_ok)

    def test_signed_in_offers_sign_out_and_install_waits_for_a_device(self):
        m, w = self._window(self._rows(signed_in=True))
        self.assertIn('Sign out', self._buttons(w))
        self.assertTrue(m.device_install_ready)
        self.assertEqual(w.win_install_btn.text(), 'Install on device')
        self.assertFalse(w.win_install_btn.isEnabled())       # no device connected
        self.assertIn('No iPhone or iPad connected', w.win_dev_note.text())

    def test_a_known_device_offers_update_launcher(self):
        from nspb_qt.win import device as dv
        from nspb_qt.win import install as wi
        m, w = self._window(self._rows(signed_in=True))
        m.devices = [dv.Device('UDID1', 7, 'USB', 'Jane’s iPhone')]
        m.install_udid = 'UDID1'
        wi.Devices(Path(m.shell_cache_path)).put('UDID1', wi.DeviceState(bundle='org.nxnative.shell.T', signed=1.0))
        w._refresh_install_card()
        self.assertEqual(w.win_install_btn.text(), 'Update launcher')
        self.assertTrue(w.win_install_btn.isEnabled())
        self.assertEqual(w.win_dev_combo.currentText(), 'Jane’s iPhone')
        self.assertIn('Last signed', w.win_dev_note.text())

    def test_one_game_ipa_hides_the_device_row(self):
        m, w = self._window(self._rows(signed_in=True))
        w._on_ipa_kind_changed('oneGame')
        self.assertFalse(w.win_dev_container.isVisibleTo(w))

    def test_auto_update_switch_is_saved(self):
        m, w = self._window(self._rows(signed_in=True))
        start = m.auto_update_launcher
        w.auto_switch.toggled.emit(not start)
        self.assertEqual(m.auto_update_launcher, not start)
        m.set_auto_update_launcher(start)


if __name__ == '__main__':
    unittest.main()
