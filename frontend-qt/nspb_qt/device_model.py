"""The shared app on an iPhone or iPad, for the Windows launcher's model.

`Model` takes these methods from `DeviceMixin`: the device rows of the dependency panel (Apple's
USB service, the signing tool, the Apple ID), the device list, the install after a build, the
install again ("Update launcher", by hand or when a device connects) and the unsigned IPA of the
shared app. The work itself is `win/install.py`, `win/device.py` and `win/signer.py`, which
need no Qt. On macOS the Swift launcher does all of this with Xcode, so nothing here runs there.
"""
from __future__ import annotations

import os
import threading
import time
import webbrowser
import zipfile
from pathlib import Path

from . import platform_util as pu
from . import shell

#: Apple's page for iTunes for Windows: the installer from apple.com carries Apple Mobile Device
#: Support, the USB service every tool that talks to an iPhone from Windows needs.
ITUNES_URL = 'https://support.apple.com/en-us/106372'

#: How often a connected device is looked for while "Update the launcher when a device connects"
#: is on (a local query of Apple's USB service, no network).
AUTO_POLL_MS = 20_000

#: How long an install waits for a game's banner that is still downloading after its build.
BANNER_WAIT = 45


class DeviceMixin:
    """Needs from the model: settings, t(), log(), running, stages, the signals runningChanged,
    stagesChanged, finished, devicesChanged and autoInstallRequested, shell_cache_path,
    check_deps() and _proc."""

    def _device_init(self) -> None:
        self.devices: list = []                 # win.device.Device, connected now
        self.devices_note = ''                  # why the list is empty, for the window
        self.install_udid = str(self.settings.value('installDevice', '', type=str) or '')
        self.apple_account = None               # win.signer.Account after a dependency check
        self._install_cancel = False
        self._auto_seen: set[str] = set()
        self._auto_busy = False
        # a method of this QObject, not a lambda: the worker thread emits, and the install must start on
        # the model's own (main) thread
        self.autoInstallRequested.connect(self._on_auto_install)
        self._known_udids: set[str] = set()
        if pu.IS_WIN:
            from PySide6.QtCore import QTimer
            self._auto_timer = QTimer(self)
            self._auto_timer.setInterval(AUTO_POLL_MS)
            self._auto_timer.timeout.connect(self._auto_tick)
            self._auto_timer.start()

    # ---------------------------------------------------------------- the dependency rows

    @property
    def auto_update_launcher(self) -> bool:
        return bool(self.settings.value('autoUpdateLauncher', True, type=bool))

    def set_auto_update_launcher(self, on: bool) -> None:
        self.settings.setValue('autoUpdateLauncher', bool(on))

    def _device_rows(self) -> list:
        """Apple's USB service, the signing tool and the Apple ID: what installing on a device
        needs, beside the build tools. Optional rows: a build and the IPA export work without."""
        from .model import Dep, DepState
        from .win import device as dv, signer
        rows = []
        amds = dv.service_running()
        rows.append(Dep('amds', 'win.dep.amds', 'win.dep.amds.hint',
                        DepState.OK if amds else DepState.MISSING,
                        'Apple Mobile Device Service' if amds else '', required=False))
        exe = signer.find()
        ok = bool(exe) and signer.works(exe)
        rows.append(Dep('signer', 'win.dep.signer', 'win.dep.signer.hint',
                        DepState.OK if ok else DepState.MISSING,
                        str(exe) if ok else ('win.dep.signer.broken' if exe else 'win.dep.signer.missing'),
                        required=False))
        acct = signer.account(exe) if ok else None
        self.apple_account = acct
        signed_in = bool(acct and acct.signed_in)
        rows.append(Dep('apple_id', 'win.dep.appleId', 'win.dep.appleId.hint',
                        DepState.OK if signed_in else DepState.MISSING,
                        signer.masked(acct.email) if signed_in else '', required=False))
        tpl = shell.find_template()
        rows.append(Dep('shell_template', 'win.dep.template', 'win.dep.template.hint',
                        DepState.OK if tpl else DepState.MISSING,
                        (str(tpl) + '  ' + shell.template_version(tpl)) if tpl else 'win.dep.template.missing',
                        required=False))
        return rows

    @property
    def device_install_ready(self) -> bool:
        need = {'amds', 'signer', 'apple_id', 'shell_template'}
        return pu.IS_WIN and all(d.ok for d in self.deps if d.id in need) and \
            need <= {d.id for d in self.deps}

    def open_itunes_page(self) -> None:
        webbrowser.open(ITUNES_URL)

    def sign_in_apple_id(self) -> None:
        """Impactor's own sign-in, in its own console window. The launcher only waits for the
        window to close, then checks again."""
        from .win import signer
        p = signer.login_console()
        if p is None:
            self.log(self.t('win.sign.fail.missing') + '\n')
            return
        self.log(self.t('win.appleId.opened') + '\n')

        def wait() -> None:
            try:
                p.wait()
            finally:
                self.check_deps()
        threading.Thread(target=wait, daemon=True).start()

    def sign_out_apple_id(self) -> None:
        from .win import signer
        ok, out = signer.logout()
        self.log((self.t('win.appleId.signedOut') if ok else out) + '\n')
        self.check_deps()

    # ---------------------------------------------------------------- devices

    def refresh_devices(self) -> None:
        def work() -> None:
            from .win import device as dv
            try:
                found = [dv.describe(d) for d in dv.list_devices()]
                self.devices_note = '' if found else self.t('win.devices.none')
            except dv.DeviceError as e:
                found, self.devices_note = [], str(e)
            self.devices = found
            if found and self.install_udid not in {d.udid for d in found}:
                self.install_udid = found[0].udid
            self.devicesChanged.emit()
        threading.Thread(target=work, daemon=True).start()

    def set_install_device(self, udid: str) -> None:
        self.install_udid = udid
        self.settings.setValue('installDevice', udid)

    def device_label(self, d) -> str:
        name = d.name or self.t('win.devices.untrusted')
        return name + ('' if d.wired else ' · Wi-Fi')

    # ---------------------------------------------------------------- after a build

    def after_framework_build(self, work_dir: str, archive: str) -> None:
        """A `--shell-framework` build ended: put the game in the shared app's list, then install
        when a device is ready (as the Mac launcher does after a build for iPhone / iPad)."""
        built = shell.built_framework(Path(work_dir))
        if not built:
            self.finished.emit(False, self.t('win.install.noFramework', work_dir))
            return
        try:
            game = shell.add_built_game(Path(self.shell_cache_path), built)
        except OSError as e:
            self.finished.emit(False, self.t('win.install.prepareFailed', str(e)))
            return
        self.log(self.t('win.install.added', game.name) + '\n')
        if archive and Path(archive).is_dir():
            shell.remember_data(Path(self.shell_cache_path), game.titleID, Path(archive))
        if self.device_install_ready and self.install_udid:
            self.install_on_device(self.install_udid, keep_stages=True)   # with every game's data the device lacks
        else:
            self.finished.emit(True, self.t('win.install.builtNoDevice', game.name))

    # ---------------------------------------------------------------- the install

    def install_on_device(self, udid: str = '', data: list | None = None, auto: bool = False,
                          keep_stages: bool = False) -> None:
        """Sign and install the shared app on `udid` (the chosen device by default), then copy
        `data` [(title ID, game data folder)], by default the data of every game the device has not
        received yet. The games already on the device keep theirs."""
        if self.running:
            return
        udid = udid or self.install_udid
        if not udid:
            self.finished.emit(False, self.t('win.install.noDevice'))
            return
        from .model import Stage
        from .win import install as wi
        self.running = True
        self.runningChanged.emit(True)
        self._install_cancel = False
        self.failure = None
        if not keep_stages:      # after a build its stages stay above the install's
            self.stages = []
        self.stagesChanged.emit()
        if auto:
            self.log(self.t('win.install.autoStart') + '\n')

        def stage(key: str, state: str, detail: str, percent: float) -> None:
            name = self.t(key)
            st = next((s for s in self.stages if s.name == name), None)
            if st is None:
                st = Stage(name=name)
                self.stages.append(st)
            st.state, st.detail, st.percent = state, detail, percent
            self.stagesChanged.emit()

        def started(p) -> None:
            self._proc = p

        def work() -> None:
            try:
                out = wi.install(Path(self.shell_cache_path), udid, data=data,
                                 log=self.log, stage=stage, cancelled=lambda: self._install_cancel,
                                 started=started, banner=self._banner_for)
            except Exception as e:      # a bug must end the run visibly, not leave it "running"
                out = wi.Outcome(False, ('win.install.prepareFailed', str(e)))
            self._proc = None
            self.running = False
            self.runningChanged.emit(False)
            note = self.t(*out.message) if out.message else ''
            if not out.ok and out.failure:
                note += ' ' + self.t(out.failure)
            self.log(note + '\n')       # the footer is one line: the log keeps the whole note
            self.finished.emit(out.ok, note)
        threading.Thread(target=work, daemon=True).start()

    def _banner_for(self, title_id: str) -> str | None:
        """The game's picture for the app's library: what this launcher's own library shows (the
        player's pick, the cached eShop banner, the engine's gallery picture). Right after a build the
        banner may still be downloading (request_banner_async): it waits for it a little."""
        art = getattr(self, 'artwork', None)
        if art is None:
            return None
        path = art.image_path(title_id, self.engine_path)
        if path:
            return path
        art.request_banner_async(title_id)
        deadline = time.time() + BANNER_WAIT
        while time.time() < deadline:
            time.sleep(1)
            if path := art.image_path(title_id, self.engine_path):
                return path
            if title_id.upper() not in getattr(art, '_fetching', ()):
                break                       # the download ended without a picture
        return None

    def cancel_install(self) -> None:
        self._install_cancel = True

    def _on_auto_install(self, udid: str) -> None:
        self.install_on_device(udid, auto=True)

    def _auto_tick(self) -> None:
        """"Update the launcher when a device connects": a device that has the app from this PC
        gets it signed and installed again when the signature is getting old or the games
        changed. Only a cable connection, only when nothing else runs."""
        if self._auto_busy:
            return
        self._auto_busy = True
        auto = not self.running and self.auto_update_launcher and self.device_install_ready

        def work() -> None:
            try:
                from .win import device as dv, install as wi
                try:
                    found = dv.list_devices()
                except dv.DeviceError:
                    found = []
                # a device plugged in or out: the install row's list follows without a press of Refresh
                udids = {d.udid for d in found}
                if udids != self._known_udids:
                    self._known_udids = udids
                    self.refresh_devices()
                if not auto:
                    return
                wired = {d.udid for d in found if d.wired}
                new = wired - self._auto_seen
                self._auto_seen = wired
                if not new:
                    return
                root = Path(self.shell_cache_path)
                games = shell.Library.load(root).present()
                current = wi.library_hash(games, shell.find_template())
                known = wi.Devices(root)
                for udid in sorted(new):
                    if wi.needs_update(known.get(udid), current):
                        self.autoInstallRequested.emit(udid)
                        return              # one at a time: the next tick sees the rest
            finally:
                self._auto_busy = False
        threading.Thread(target=work, daemon=True).start()

    # ---------------------------------------------------------------- the unsigned IPA

    def export_shell_ipa_async(self, dest: str) -> None:
        """Export IPA off the window's thread: a shared app with several games is gigabytes to zip."""
        if self.running:
            return
        self.running = True
        self.runningChanged.emit(True)

        def work() -> None:
            try:
                ok, msg = self.export_shell_ipa(dest)
            except Exception as e:      # the run must end visibly
                ok, msg = False, self.t('shell.exportFailed', str(e))
            self.log(msg + '\n')
            self.running = False
            self.runningChanged.emit(False)
            self.finished.emit(ok, msg)
        threading.Thread(target=work, daemon=True).start()

    def export_shell_ipa(self, dest: str) -> tuple[bool, str]:
        """The shared app with every game, unsigned, as an IPA for AltStore, SideStore or another
        signing tool (the game data goes separately, as on the Mac)."""
        tpl = shell.find_template()
        if not tpl:
            return False, self.t('win.install.noTemplate')
        root = Path(self.shell_cache_path)
        games = shell.Library.load(root).present()
        try:
            app = shell.assemble(root, tpl, games, self._banner_for)
            write_ipa(app, Path(dest))
        except (OSError, ValueError) as e:
            return False, self.t('shell.exportFailed', str(e))
        return True, self.t('shell.exportDone', dest)


def write_ipa(app: Path, dest: Path) -> None:
    """Zip `app` as `Payload/<name>.app` with Unix modes: Mach-O files 0755 (an iOS install tool
    may refuse an executable without its x bit, and Windows has none to copy), the rest 0644."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(dest.suffix + '.tmp')
    base = f'Payload/{app.name}'
    with zipfile.ZipFile(tmp, 'w', zipfile.ZIP_DEFLATED, compresslevel=1) as z:
        for p in sorted(app.rglob('*')):
            rel = f'{base}/{p.relative_to(app).as_posix()}'
            if p.is_dir():
                zi = zipfile.ZipInfo(rel + '/')
                zi.external_attr = (0o40755 << 16) | 0x10
                zi.create_system = 3
                z.writestr(zi, b'')
                continue
            zi = zipfile.ZipInfo.from_file(p, rel)
            zi.create_system = 3
            with open(p, 'rb') as f:
                head = f.read(4)
            macho = head in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe')
            zi.external_attr = ((0o100755 if macho else 0o100644) << 16)
            zi.compress_type = zipfile.ZIP_DEFLATED
            with open(p, 'rb') as src, z.open(zi, 'w', force_zip64=True) as out:
                while chunk := src.read(8 << 20):
                    out.write(chunk)
    os.replace(tmp, dest)
