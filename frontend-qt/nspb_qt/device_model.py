"""The shared app on an iPhone or iPad, for the Windows launcher's model.

`Model` takes these methods from `DeviceMixin`: the device rows of the dependency panel (Apple's
USB service, the signing tool, the Apple ID), the device list, the install after a build, the
install again ("Update the launcher", by hand or when a device connects). The work itself is
`win/install.py`, `win/device.py` and `win/signer.py`, which need no Qt; the shared app's library
and template are `win/shell_export.py`, the same the IPA export uses. On macOS the Swift launcher
does all of this with Xcode, so nothing here runs there.
"""
from __future__ import annotations

import threading
import time
import webbrowser
from pathlib import Path

from . import platform_util as pu
from .signals import emit_safely

#: Apple's page for iTunes for Windows: the installer from apple.com carries Apple Mobile Device
#: Support, the USB service every tool that talks to an iPhone from Windows needs.
ITUNES_URL = 'https://support.apple.com/en-us/106372'

#: How often a connected device is looked for while "Update the launcher when a device connects"
#: is on (a local query of Apple's USB service, no network).
AUTO_POLL_MS = 20_000

#: How long an install waits for a game's banner that is still downloading after its build. Short: the install
#: shows it is waiting, and a banner that comes later goes in at the next install.
BANNER_WAIT = 15


#: The dependency rows of signing and installing on a device (_device_rows): Settings shows them in their own card, the
#: setup guide on its own step, and device_install_ready needs all of them.
DEVICE_DEP_IDS = ('amds', 'signer', 'apple_id', 'shell_template')


def _se():
    from .win import shell_export as se
    return se


class DeviceMixin:
    """Needs from the model: settings, t(), log(), running, stages, begin_run(), end_run(), cancel_run(),
    cancel_requested, the signals runningChanged, stagesChanged, finished, depsChanged, devicesChanged,
    autoInstallRequested and newDeviceFound, shell_cache_path, engine_path, python_path, artwork, check_deps() and
    _proc."""

    def _device_init(self) -> None:
        self.devices: list = []                 # win.device.Device, connected now
        self.devices_note = ''                  # why the list is empty, for the window
        self.install_udid = self._setting('installDevice')
        self.apple_account = None               # win.signer.Account after a dependency check
        self.signing_in = False                 # the sign-in window is open (the Apple ID row waits for it)
        self.transfer_info: dict | None = None  # where an install's game data copy is (install.py CopyPlan)
        self._auto_seen: set[str] = set()
        self._auto_busy = False
        self._scan_lock = threading.Lock()      # one device scan at a time (refresh_devices)
        self._scan_running = False
        self._scan_again = False
        # a method of this QObject, not a lambda: the worker thread emits, and the install must start on
        # the model's own (main) thread
        self.autoInstallRequested.connect(self._on_auto_install)
        self._known_udids: set[str] = set()
        self._offered: set[str] = set()         # devices asked about this session (newDeviceFound)
        self._auto_timer = None

    def start_device_poll(self) -> None:
        """Look for connected devices every AUTO_POLL_MS from now on (the window starts it once it is up, on Windows):
        the install row's list follows the cable, and "Update the launcher when a device connects" and the new-device
        offer act on what it finds. A model on its own (a test, a tool) polls nothing."""
        if not pu.IS_WIN or self._auto_timer is not None:
            return
        from PySide6.QtCore import QTimer
        self._auto_timer = QTimer(self)
        self._auto_timer.setInterval(AUTO_POLL_MS)
        self._auto_timer.timeout.connect(self._auto_tick)
        self._auto_timer.start()

    # ---------------------------------------------------------------- the dependency rows

    @property
    def auto_update_launcher(self) -> bool:
        return self._setting_bool('autoUpdateLauncher', True)

    def set_auto_update_launcher(self, on: bool) -> None:
        self.settings.setValue('autoUpdateLauncher', bool(on))

    @property
    def offer_new_devices(self) -> bool:
        """Ask to install the launcher when an iPhone or iPad without it is plugged in."""
        return self._setting_bool('offerNewDevices', True)

    def set_offer_new_devices(self, on: bool) -> None:
        self.settings.setValue('offerNewDevices', bool(on))

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
        se = _se()
        tpl = se.find_shell_template(self.engine_path, root=self.shell_cache_path)
        rows.append(Dep('shell_template', 'win.dep.template', 'win.dep.template.hint',
                        DepState.OK if tpl else DepState.MISSING,
                        str(tpl) if tpl else 'win.dep.template.missing', required=False))
        return rows

    @property
    def device_install_ready(self) -> bool:
        need = set(DEVICE_DEP_IDS)
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
        self.signing_in = True
        emit_safely(self.depsChanged)

        def wait() -> None:
            try:
                p.wait()
            finally:
                self.signing_in = False
                self.check_deps()
        threading.Thread(target=wait, daemon=True).start()

    def sign_out_apple_id(self) -> None:
        from .win import signer
        ok, out = signer.logout()
        self.log((self.t('win.appleId.signedOut') if ok else out) + '\n')
        self.check_deps()

    # ---------------------------------------------------------------- devices

    def refresh_devices(self) -> None:
        """Look for connected devices on a thread. One scan at a time: a request while one runs is remembered and
        served by one more scan when it ends (the dependency check, the poll and Refresh may all ask at once, and
        each scan opens a lockdown session with every device)."""
        with self._scan_lock:
            if self._scan_running:
                self._scan_again = True
                return
            self._scan_running = True

        def work() -> None:
            from .win import device as dv
            while True:
                found: list = []
                try:
                    found = [dv.describe(d) for d in dv.list_devices()]
                    self.devices_note = '' if found else self.t('win.devices.none')
                except dv.DeviceError as e:
                    found, self.devices_note = [], str(e)
                except Exception as e:      # a bug must not leave the list stuck: the window always hears the end
                    found, self.devices_note = [], str(e)
                finally:
                    self.devices = found
                    if found and self.install_udid not in {d.udid for d in found}:
                        self.install_udid = found[0].udid
                    emit_safely(self.devicesChanged)
                with self._scan_lock:
                    if not self._scan_again:
                        self._scan_running = False
                        return
                    self._scan_again = False
        threading.Thread(target=work, daemon=True).start()

    def set_install_device(self, udid: str) -> None:
        self.install_udid = udid
        self.settings.setValue('installDevice', udid)

    def device_label(self, d) -> str:
        name = d.name or self.t('win.devices.untrusted')
        return name + ('' if d.wired else ' · Wi-Fi')

    def device_by_udid(self, udid: str):
        return next((d for d in self.devices if d.udid == udid), None)

    # ---------------------------------------------------------------- the games on a device

    def built_games(self) -> list:
        """Every game built for the shared app on this PC (shell.json, its framework still there and whole)."""
        return _se().present_games(Path(self.shell_cache_path))

    def device_state(self, udid: str):
        from .win import install as wi
        return wi.Devices(Path(self.shell_cache_path)).get(udid) if udid else None

    def device_titles(self, udid: str) -> list[str]:
        """The games in the app on a device after the last install from this PC ([]: none from this PC yet). A device
        installed before the app kept this list holds every built game."""
        st = self.device_state(udid)
        if st is None or not st.bundle:
            return []
        return list(st.titles) if st.titles else [g.title_id.upper() for g in self.built_games()]

    def game_plays_on_older(self, title_id: str) -> bool:
        """Whether a game built for the shared app plays on a device without BC textures (shell_export.supports_older)."""
        g = next((x for x in self.built_games() if x.title_id.upper() == title_id.upper()), None)
        return bool(g) and _se().supports_older(Path(g.framework), self.engine_path)

    def device_gpu(self, udid: str) -> str:
        """'new', 'older' or 'unknown' for a connected device (win.device.gpu_class of its model identifier)."""
        from .win import device as dv
        d = self.device_by_udid(udid)
        return dv.gpu_class(getattr(d, 'product', '')) if d else 'unknown'

    def transfer_games(self, udid: str, titles: list[str]) -> bool:
        """Put exactly `titles` in the app on `udid` (install or update it), then copy their data the device lacks.
        False when another run is going on and nothing started."""
        return self.install_on_device(udid, titles=[t.upper() for t in titles])

    # ---------------------------------------------------------------- after a build

    def after_framework_build(self, framework: Path, title_id: str, name: str, archive: str) -> tuple[bool, str]:
        """A `--shell-framework` build for "Install on device" ended: the game goes into the shared app's library
        (shell.json, its framework mirrored, its banner), its data folder is remembered, then the app is signed and
        installed on the chosen device with this game and the ones it has, as the Mac launcher does after a build for
        iPhone / iPad. Runs on the build's worker, as the rest of the build's run (model._export_shell_after_archive):
        returns how the run ends, (ok, note). A stop is seen by the caller through cancel_requested."""
        se = _se()
        root = Path(self.shell_cache_path)
        picked = self.artwork.custom_paths.get(title_id.upper()) if getattr(self, 'artwork', None) else None
        banners = self.artwork.banners_dir if getattr(self, 'artwork', None) else None
        stage_name = self.t('win.install.stage.library')
        self._device_stage(stage_name, 'running')
        library, notes, err = se.add_to_library(root, framework, title_id, name, banners_dir=banners,
                                                picked_artwork=picked, t_func=self.t, log=self.log)
        if library is None:
            self._device_stage(stage_name, 'failed')
            return False, err
        for note in notes:
            self.log(note + '\n')
        self._device_stage(stage_name, 'done')
        self.log(self.t('win.install.added', name) + '\n')
        if archive and Path(archive).is_dir():
            from .win import install as wi
            wi.remember_data(root, title_id, Path(archive))
        # the game is built: the library says so whatever the install below does (a device unplugged is not a failed build)
        self._record_library_ios_completion(title_id, name=name, ipa_path='', archive_path=archive)
        if self.cancel_requested:
            return False, ''
        if getattr(self, 'queue_defers_install', lambda: False)():
            # a queued game: the queue's end installs every game it built at once (queue_model.py)
            self.queue_built(title_id)
            return True, self.t('queue.built', name)
        udid = self.install_udid
        if self.device_install_ready and udid and self.device_by_udid(udid) is not None:
            # the games already on the device and this one (a device never installed from this PC gets every game)
            on_device = self.device_titles(udid)
            titles = sorted(set(on_device) | {title_id.upper()}) if on_device else None
            self.run_kind = 'install'      # the activity bar says what runs now: the install is the rest of this run
            emit_safely(self.runningChanged, True)
            ok, note, _stopped = self._install(udid, titles=titles, keep_stages=True)
            return ok, note
        return True, self.t('win.install.builtNoDevice', name)

    # ---------------------------------------------------------------- the install

    def install_on_device(self, udid: str = '', data: list | None = None, auto: bool = False,
                          titles: list[str] | None = None) -> bool:
        """Sign and install the shared app on `udid` (the chosen device by default) as a run of its own, then copy
        `data` [(title ID, game data folder)], by default the data of every game the device has not received yet.
        Returns False when it did not start (another run is going on), True when it started (its end is
        `finished`)."""
        if not self.begin_run('install'):
            return False

        def work() -> None:
            try:
                ok, note, stopped = self._install(udid or self.install_udid, data=data, auto=auto, titles=titles)
            except Exception as e:      # a bug must end the run visibly, not leave it "running"
                ok, note, stopped = False, self.t('win.install.unexpected', str(e)), False
            self.end_run(ok, note, stopped=stopped)
        threading.Thread(target=work, daemon=True).start()
        return True

    def _device_stage(self, name: str, state: str, detail: str = '', percent: float = 0.0) -> None:
        from .model import Stage
        st = next((x for x in self.stages if x.name == name), None)
        if st is None:
            st = Stage(name=name)
            self.stages.append(st)
        st.state, st.detail, st.percent = state, detail, percent
        emit_safely(self.stagesChanged)

    def _install(self, udid: str, data: list | None = None, auto: bool = False, keep_stages: bool = False,
                 titles: list[str] | None = None) -> tuple[bool, str, bool]:
        """The install itself, on the run's own thread: (ok, note, stopped)."""
        if not udid:
            return False, self.t('win.install.noDevice'), False
        from .win import install as wi
        self.failure = None
        if not keep_stages:      # after a build its stages stay above the install's
            self.stages = []
        emit_safely(self.stagesChanged)
        if auto:
            self.log(self.t('win.install.autoStart') + '\n')

        def stage(key: str, state: str, detail: str, percent: float) -> None:
            self._device_stage(self.t(key), state, detail, percent)

        def started(p) -> None:
            self._proc = p
            if self.cancel_requested:     # Stop came while the signing tool started: end it now
                self.cancel_run()

        rate = wi.CopyRate()
        self.transfer_info = None

        def on_transfer(info: dict) -> None:
            # where the game data copy is, with its speed and the time left (the window shows it with a clock time)
            now = time.time()
            rate.add(info['done'], now)
            left = rate.seconds_left(info['done'], info['total'])
            self.transfer_info = dict(info, rate=rate.rate(), left=left, at=now)
            emit_safely(self.stagesChanged)

        try:
            out = wi.install(Path(self.shell_cache_path), udid, data=data, titles=titles,
                             log=self.log, stage=stage, cancelled=lambda: self.cancel_requested,
                             started=started, banner=self._banner_for, t=self.t, transfer=on_transfer,
                             engine=self.engine_path, python_exe=self.python_path or '')
        except Exception as e:      # a bug must end the run visibly, not leave it "running"
            # not "could not prepare": this can come from any step. The step that was running failed with it.
            for st in self.stages:
                if st.state == 'running':
                    st.state, st.detail = 'failed', str(e)[:160]
            emit_safely(self.stagesChanged)
            out = wi.Outcome(False, ('win.install.unexpected', str(e)))
        finally:
            self._proc = None
        note = self.t(*out.message) if out.message else ''
        if not out.ok and out.failure:
            note += ' ' + self.t(out.failure)
        self.log(note + '\n')       # the footer is one line: the log keeps the whole note
        emit_safely(self.devicesChanged)    # the device's state (last signed, its games) changed
        return out.ok, note, out.stopped

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

    @staticmethod
    def _has_shell(found: list, udid: str) -> bool:
        """Whether the device has the shared app already (installed from another computer): then it is not offered."""
        from .win import device as dv
        dev = next((d for d in found if d.udid == udid), None)
        if dev is None:
            return False
        try:
            return bool(dv.find_shell(dev))
        except dv.DeviceError:
            return True         # cannot tell: do not ask

    def cancel_install(self) -> None:
        """The transfer window's Stop: the same as every Stop (Model.cancel_run), so the signing tool ends at once
        instead of finishing its install first."""
        self.cancel_run()

    def _on_auto_install(self, udid: str) -> None:
        if not self.install_on_device(udid, auto=True):
            self._auto_seen.discard(udid)   # something else ran: a later tick asks again

    def _auto_tick(self) -> None:
        """"Update the launcher when a device connects": a device that has the app from this PC
        gets it signed and installed again when the signature is getting old or the games
        changed. Only a cable connection, only when nothing else runs. A device without the app
        (none from this PC, none from elsewhere) is offered it once a session (newDeviceFound)."""
        if self._auto_busy:
            return
        self._auto_busy = True
        ready = not self.running and self.device_install_ready
        auto = ready and self.auto_update_launcher
        offer = ready and self.offer_new_devices

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
                if not (auto or offer):
                    return
                wired = {d.udid for d in found if d.wired}
                self._auto_seen &= wired            # a device unplugged is new again when it comes back
                new = wired - self._auto_seen
                if not new:
                    return
                root = Path(self.shell_cache_path)
                tpl = _se().find_shell_template(self.engine_path, root=root)
                known = wi.Devices(root)
                for udid in sorted(new):
                    # A device counts as seen once it has been looked at here. The tick acts on one device and stops:
                    # the devices after it stay new, so the next tick sees them (before, every connected device was
                    # marked seen first, and only the first one was ever updated or offered).
                    self._auto_seen.add(udid)
                    state = known.get(udid)
                    if state is not None and state.bundle:
                        current = wi.library_hash(wi.device_games(root, state), tpl)
                        if auto and wi.needs_update(state, current):
                            emit_safely(self.autoInstallRequested, udid)
                            return          # one at a time: the next tick sees the rest
                        continue
                    if offer and udid not in self._offered and _se().present_games(root) \
                            and dv.is_paired(udid) and not self._has_shell(found, udid):
                        self._offered.add(udid)
                        self.refresh_devices()          # its name, for the question
                        emit_safely(self.newDeviceFound, udid)
                        return
            except Exception as e:      # a damaged devices.json or a bug: say it, and the next tick tries again
                self.log(f'[devices] {e}\n')
            finally:
                self._auto_busy = False
        threading.Thread(target=work, daemon=True).start()
