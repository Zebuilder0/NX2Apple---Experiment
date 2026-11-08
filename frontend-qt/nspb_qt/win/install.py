"""Install the shared app on an iPhone or iPad from Windows, and keep it signed.

One function does the whole install the Mac launcher does with Xcode and devicectl
(`ShellInstaller`): put every built game into the empty shared app (`shell.py`), sign and
install it with the player's Apple ID (`signer.py`), then copy the game data the device lacks
into the app's `Documents/games/<title ID>/` (`device.py`).

`devices.json` in the shell cache folder remembers, per device, the app's bundle ID there, when
it was last signed and which games it holds. "Update the launcher when a device connects" reads
it: a device that has the app gets it signed and installed again when the signature is 5 days
old (a free Apple ID's lasts 7) or when the games changed. Nothing here needs Qt: the window's
model runs it on a thread and passes callbacks.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

from .. import shell
from . import device as dv
from . import signer

#: Re-sign when the last signature is this old. A free Apple ID's lasts 7 days.
RESIGN_AFTER = 5 * 24 * 3600


@dataclass
class Outcome:
    ok: bool
    message: tuple = ()             # (en.json key, *args) for the window
    failure: str = ''               # an en.json key with what to do next, '' when none
    bundle_id: str = ''
    copied_files: int = 0
    stopped: bool = False           # the player stopped it: neither a success nor a failure to explain


#: A stage's state when the player stopped the run there (the window shows it neither green nor red).
STOPPED = 'stopped'


@dataclass
class DeviceState:
    bundle: str = ''
    signed: float = 0.0
    games: str = ''                 # library_hash() at the last install
    name: str = ''
    receipts: dict = field(default_factory=dict)   # title ID → the game data's stamp on this device
    titles: list = field(default_factory=list)     # the title IDs in the app on this device ([]: every built game)


#: One writer of devices.json at a time in this app (an install, the automatic update, the window).
_DEVICES_LOCK = threading.Lock()


def _device_state(d) -> DeviceState | None:
    """One entry of devices.json, None when it is damaged (a hand edit, a cut-off write): that device is then
    treated as never installed from this PC, and the other devices keep theirs."""
    if not isinstance(d, dict):
        return None
    try:
        return DeviceState(str(d.get('bundle', '')), float(d.get('signed', 0) or 0), str(d.get('games', '')),
                           str(d.get('name', '')), {str(k): str(v) for k, v in dict(d.get('receipts') or {}).items()},
                           [str(t).upper() for t in d.get('titles') or []])
    except (TypeError, ValueError, AttributeError):
        return None


class Devices:
    """`<root>/devices.json`."""

    def __init__(self, root: Path):
        self.path = Path(root) / 'devices.json'
        self.items: dict[str, DeviceState] = self._read()

    def _read(self) -> dict[str, DeviceState]:
        try:
            raw = json.loads(self.path.read_text(encoding='utf-8'))
        except (OSError, ValueError):
            raw = {}
        items = {}
        for udid, d in (raw.items() if isinstance(raw, dict) else []):
            state = _device_state(d)
            if state is not None:
                items[str(udid)] = state
        return items

    def get(self, udid: str) -> DeviceState | None:
        return self.items.get(udid)

    def put(self, udid: str, state: DeviceState) -> None:
        """Save one device's entry. The file is read again first: an install keeps its Devices for minutes, and its
        old copy must not write over what another device's install or the window saved meanwhile."""
        with _DEVICES_LOCK:
            items = self._read()
            items[udid] = state
            self.items = items
            self._write(items)

    def save(self) -> None:
        with _DEVICES_LOCK:
            self._write(self.items)

    def _write(self, items: dict[str, DeviceState]) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix('.tmp')
        tmp.write_text(json.dumps({u: vars(s) for u, s in items.items()}, indent=2, sort_keys=True),
                       encoding='utf-8')
        os.replace(tmp, self.path)


def library_hash(games: list[shell.Game], template: Path | None) -> str:
    """What the app on a device would change with: the games (and when each was built) and the
    empty app's own version (a launcher update brings a new one)."""
    h = hashlib.sha256()
    if template:
        h.update(shell.template_version(template).encode() + b'\0')
    for g in sorted(games, key=lambda g: g.titleID):
        try:
            mt = (Path(g.framework) / 'game.manifest.json').stat().st_mtime_ns
        except OSError:
            mt = 0
        h.update(f'{g.titleID}:{mt}\0'.encode())
    return h.hexdigest()[:16]


def device_games(root: Path, state: DeviceState | None) -> list[shell.Game]:
    """The built games the app on a device holds: the ones chosen for it, else (never chosen) every built game."""
    games = shell.Library.load(root).present()
    if state is None or not state.titles:
        return games
    return shell.present_titles(games, state.titles)


def needs_update(state: DeviceState | None, current: str, now: float | None = None) -> bool:
    """Whether a connected device's app should be signed and installed again on its own: only a
    device this PC installed the app on before, when the signature is getting old or the games
    changed."""
    if state is None or not state.bundle:
        return False
    now = time.time() if now is None else now
    return now - state.signed >= RESIGN_AFTER or (bool(current) and state.games != current)


data_stamp = shell.data_stamp

class CopyPlan:
    """The game data of one install, all games together: which game is copying (its name and number), and the
    bytes done and to do. Each game counts its files' size until its copy starts and says what the device lacks."""

    def __init__(self, games: list[tuple[str, str, Path]]):
        self.names = [name for _tid, name, _folder in games]
        self.sizes = [sum(dv.local_files(Path(folder)).values()) if Path(folder).is_dir() else 0
                      for _tid, _name, folder in games]
        self.finished = 0          # bytes of the games already copied

    def report(self, number: int, done: int, total: int | None) -> dict:
        if total is not None:
            self.sizes[number - 1] = total
        return {'game': self.names[number - 1], 'number': number, 'count': len(self.names),
                'done': self.finished + done, 'total': max(sum(self.sizes), 1)}

    def finish(self, number: int, copied: int) -> None:
        self.sizes[number - 1] = copied       # 0 when the device had it all
        self.finished += copied


class CopyRate:
    """The copy's speed over its last `window` seconds and the time left at that speed. Nothing until `least`
    seconds have passed: the first seconds (opening the connection, a small file) say little about the rest."""

    def __init__(self, window: float = 30.0, least: float = 3.0):
        self.window, self.least = window, least
        self.samples: list[tuple[float, int]] = []

    def add(self, done: int, now: float) -> None:
        if self.samples and done < self.samples[-1][1]:
            self.samples = []                 # a new count: start over
        self.samples.append((now, done))
        while len(self.samples) > 2 and now - self.samples[1][0] >= self.window:
            self.samples.pop(0)

    def rate(self) -> float | None:
        if len(self.samples) < 2:
            return None
        (t0, d0), (t1, d1) = self.samples[0], self.samples[-1]
        if t1 - t0 < self.least or d1 <= d0:
            return None
        return (d1 - d0) / (t1 - t0)

    def seconds_left(self, done: int, total: int) -> float | None:
        r = self.rate()
        return None if r is None else max(0.0, (total - done) / r)


_LOG_PREFIX = re.compile(r'^\[[^\]]*\]\s*')


def signer_step(line: str) -> str:
    """What the signing tool is doing, from one of its (redacted) log lines, for the step's detail: its message
    without the time and level, '' for the command echo, the progress lines (the percentage shows those) and blank
    lines."""
    text = _LOG_PREFIX.sub('', line.strip())
    if not text or text.startswith('$ ') or text.lower().startswith('installation progress'):
        return ''
    return text if len(text) <= 70 else text[:69] + '…'


Callback = Callable[..., None]


def install(root: Path, udid: str, *, data: list[tuple[str, Path]] | None = None,
            titles: list[str] | set[str] | None = None,
            log: Callable[[str], None] = lambda s: None,
            stage: Callable[[str, str, str, float], None] = lambda *a: None,
            cancelled: Callable[[], bool] = lambda: False,
            started: Callable[[object], None] | None = None,
            template: Path | None = None, signer_exe: Path | None = None,
            banner: Callable[[str], str | None] | None = None,
            t: Callable[..., str] = lambda key, *a: key,
            transfer: Callable[[dict], None] | None = None, engine: str = '') -> Outcome:
    """Sign and install the shared app on `udid`, then copy each `(title ID, game data folder)`
    of `data`: by default every game's data the device has not received yet (`shell.pending_data`).
    `titles` are the games the app holds (a game left out is removed from the app on the device); by default the
    ones it held after the last install from this PC, else every built game.
    `stage(key, state, detail, percent)` reports the steps: key is an en.json key, state
    'running', 'done', 'failed' or 'stopped'. A stop (`cancelled()`) is checked between the steps and between the
    games, and stops a copy mid-file: it returns `Outcome(stopped=True)`, never a success."""
    root = Path(root)

    def stop(key: str, bundle_id: str = '', copied: int = 0) -> Outcome:
        stage(key, STOPPED, t('msg.stopped'), 0)
        return Outcome(False, ('win.install.stopped',), '', bundle_id, copied, stopped=True)
    template = template or shell.find_template()
    if not template:
        return Outcome(False, ('win.install.noTemplate',), 'win.install.noTemplate.next')
    exe = signer_exe or signer.find()
    if not exe:
        return Outcome(False, ('win.sign.fail.missing',))
    known = Devices(root)
    prev = known.get(udid) or DeviceState()
    every = shell.Library.load(root).present()
    if titles is not None:
        games = shell.present_titles(every, titles)
    else:
        games = device_games(root, prev if prev.bundle else None)
    if not games:
        return Outcome(False, ('win.install.noGames',))
    try:
        devices = dv.list_devices()
    except dv.DeviceError as e:
        return Outcome(False, ('win.install.noService', str(e)), 'win.dep.amds.hint')
    dev = next((d for d in devices if d.udid == udid), None)
    if dev is None:
        return Outcome(False, ('win.install.notConnected',), 'win.sign.fail.noDevice')
    if not dev.wired:
        # the signing tool installs over a cable only ("Device is not connected via USB")
        return Outcome(False, ('win.install.needsCable',), 'win.sign.fail.noDevice')
    if not dv.is_paired(udid):
        # the signing tool installs only on a device that trusts this PC, and does not ask itself
        return Outcome(False, ('win.install.notPaired',), 'win.install.notPaired.next')
    dv.describe(dev)
    name = dev.name or 'iPhone'
    if dv.gpu_class(dev.product) == 'older':
        # this device's GPU has no BC textures: a game built for newer devices only stops at its start with a message
        unready = [g.name for g in games if not shell.supports_older(Path(g.framework), engine)]
        if unready:
            log(t('win.install.olderWarn', name, ', '.join(unready)) + '\n')
    need = shell.template_min_ios(template)
    if dev.ios and need and shell.version_tuple(dev.ios) < shell.version_tuple(need):
        # the app's own minimum: the signing tool would install it and iOS would refuse to open it
        return Outcome(False, ('win.install.oldIOS', name, dev.ios, need), 'win.install.oldIOS.next')

    # 1. the app with every game in it
    stage('win.install.stage.prepare', 'running', '', 0)
    names = {g.titleID: g.name for g in games}

    def artwork(title_id: str) -> str | None:
        # a banner may still be downloading: the step says what it waits for instead of standing still
        stage('win.install.stage.prepare', 'running', t('win.install.gettingArt', names.get(title_id, title_id)), 0)
        return banner(title_id) if banner else None
    try:
        app = shell.assemble(root, template, games, artwork if banner else None)
    except (OSError, ValueError) as e:
        stage('win.install.stage.prepare', 'failed', str(e), 0)
        return Outcome(False, ('win.install.prepareFailed', str(e)))
    log(f'shared app: {len(games)} game(s): {", ".join(g.name for g in games)}\n')
    stage('win.install.stage.prepare', 'done', f'{len(games)}', 100)
    if cancelled():
        return stop('win.install.stage.sign')

    # 2. sign and install. The signing tool talks to Apple for a while before it installs anything: the step shows
    # the tool's own latest line, so the window moves while the percentage cannot.
    stage('win.install.stage.sign', 'running', t('win.install.contactingApple'), 0)
    last_pct = [0]

    def on_progress(p: int) -> None:
        last_pct[0] = p
        stage('win.install.stage.sign', 'running', f'{p}%', p)

    def sign_log(text: str) -> None:
        log(text)
        step = signer_step(text)
        if step:
            stage('win.install.stage.sign', 'running', step, last_pct[0])
    r = signer.sign_and_install(app, dev.device_id, log=sign_log, exe=exe, started=started, progress=on_progress)
    if not r.ok and cancelled():
        # Stop ends the signing tool (device_model.cancel_install): its exit is the stop, not a failure to explain.
        # A stop that came after the tool finished keeps its install: the app is on the device, so it is remembered
        # below and the copy loop then stops before the first game.
        return stop('win.install.stage.sign')
    if not r.ok:
        last = next((ln for ln in reversed(r.output.splitlines()) if ln.strip()), '')
        stage('win.install.stage.sign', 'failed', last[:160], 0)
        return Outcome(False, ('win.install.signFailed', last[:300] or 'see the log'), r.failure)
    stage('win.install.stage.sign', 'done', name, 100)

    # 3. remember it: the bundle ID the signer gave the app, found on the device
    try:
        bundle = dv.find_shell(dev, preferred=prev.bundle)
    except dv.DeviceError as e:
        log(f'the app list: {e}\n')
        bundle = ''
    if not bundle:
        return Outcome(False, ('win.install.notFound',))
    state = DeviceState(bundle=bundle, signed=time.time(), games=library_hash(games, template),
                        name=name, receipts=prev.receipts if prev.bundle == bundle else {},
                        titles=sorted(g.titleID.upper() for g in games))
    known.put(udid, state)

    # 4. the game data the device lacks. `transfer` hears where the whole copy is (the game, its number, the bytes
    # of every game together), for the time left: the plan starts from the size of each game's files and takes each
    # game's real amount (what the device lacks) as its copy starts.
    if data is None:
        data = shell.pending_data(root, games, state.receipts)
    copied = 0
    plan = CopyPlan([(tid, names.get(tid.upper(), names.get(tid, tid)), folder) for tid, folder in data])
    for number, (title_id, folder) in enumerate(data, 1):
        if cancelled():
            return stop('win.install.stage.data', bundle, copied)
        stamp = data_stamp(folder)
        force = ['romfs.img'] if stamp and state.receipts.get(title_id.upper()) != stamp else []
        stage('win.install.stage.data', 'running', name, 0)
        if transfer:
            transfer(plan.report(number, 0, None))

        def on_copy(done: int, total: int, _n=number) -> None:
            stage('win.install.stage.data', 'running', f'{done / 1e9:.1f} / {total / 1e9:.1f} GB',
                  done * 100 / max(total, 1))
            if transfer:
                transfer(plan.report(_n, done, total))
        try:
            n, game_bytes = dv.copy_game_data(dev, bundle, title_id, Path(folder), force=force, log=log,
                                              cancelled=cancelled, progress=on_copy)
        except dv.Cancelled:
            return stop('win.install.stage.data', bundle, copied)
        except dv.DeviceError as e:
            if cancelled():         # Stop came, and the copy ended with another error on its way out: still a stop
                return stop('win.install.stage.data', bundle, copied)
            stage('win.install.stage.data', 'failed', str(e)[:160], 0)
            return Outcome(False, ('win.install.dataFailed', str(e)), 'win.install.dataFailed.next', bundle)
        plan.finish(number, game_bytes)
        copied += n
        state.receipts[title_id.upper()] = stamp
        known.put(udid, state)
        stage('win.install.stage.data', 'done', name, 100)

    # 5. Developer Mode, last: turning it on restarts the device
    on = check_developer_mode(dev, log)
    return Outcome(True, (done_message(first=not prev.bundle, developer_mode=on), name), '', bundle, copied)


def check_developer_mode(dev: dv.Device, log: Callable[[str], None] = lambda s: None) -> bool | None:
    """Whether Developer Mode is on (None: the device does not say). When it is off, its switch is
    made to appear in Settings, as Xcode does on a Mac: iOS hides it until a development tool
    asks, so a device that only ever met Windows had no switch to turn on."""
    try:
        on = dv.developer_mode(dev)
    except (dv.DeviceError, OSError, ValueError) as e:
        log(f'Developer Mode: {e}\n')
        return None
    if on is False:
        try:
            dv.reveal_developer_mode(dev)
            log('Developer Mode is off on the device: its switch is now in Settings, Privacy & Security\n')
        except (dv.DeviceError, OSError, ValueError) as e:
            log(f'Developer Mode: {e}\n')
    return on


def done_message(first: bool, developer_mode: bool | None) -> str:
    """The en.json key of a finished install's note. The first time, iOS opens the app only once the
    player trusts the Apple ID's certificate; and with Developer Mode off, it never does."""
    if first:
        return 'win.install.firstTimeTrust' if developer_mode else 'win.install.firstTime'
    return 'win.install.devModeOff' if developer_mode is False else 'dev.installed'
