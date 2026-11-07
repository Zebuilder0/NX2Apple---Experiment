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


@dataclass
class DeviceState:
    bundle: str = ''
    signed: float = 0.0
    games: str = ''                 # library_hash() at the last install
    name: str = ''
    receipts: dict = field(default_factory=dict)   # title ID → the game data's stamp on this device


class Devices:
    """`<root>/devices.json`."""

    def __init__(self, root: Path):
        self.path = Path(root) / 'devices.json'
        try:
            raw = json.loads(self.path.read_text(encoding='utf-8'))
        except (OSError, ValueError):
            raw = {}
        self.items: dict[str, DeviceState] = {}
        for udid, d in (raw.items() if isinstance(raw, dict) else []):
            if isinstance(d, dict):
                self.items[udid] = DeviceState(str(d.get('bundle', '')), float(d.get('signed', 0) or 0),
                                               str(d.get('games', '')), str(d.get('name', '')),
                                               dict(d.get('receipts') or {}))

    def get(self, udid: str) -> DeviceState | None:
        return self.items.get(udid)

    def put(self, udid: str, state: DeviceState) -> None:
        self.items[udid] = state
        self.save()

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix('.tmp')
        tmp.write_text(json.dumps({u: vars(s) for u, s in self.items.items()}, indent=2, sort_keys=True),
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


def needs_update(state: DeviceState | None, current: str, now: float | None = None) -> bool:
    """Whether a connected device's app should be signed and installed again on its own: only a
    device this PC installed the app on before, when the signature is getting old or the games
    changed."""
    if state is None or not state.bundle:
        return False
    now = time.time() if now is None else now
    return now - state.signed >= RESIGN_AFTER or (bool(current) and state.games != current)


data_stamp = shell.data_stamp


Callback = Callable[..., None]


def install(root: Path, udid: str, *, data: list[tuple[str, Path]] | None = None,
            log: Callable[[str], None] = lambda s: None,
            stage: Callable[[str, str, str, float], None] = lambda *a: None,
            cancelled: Callable[[], bool] = lambda: False,
            started: Callable[[object], None] | None = None,
            template: Path | None = None, signer_exe: Path | None = None) -> Outcome:
    """Sign and install the shared app on `udid`, then copy each `(title ID, game data folder)`
    of `data`: by default every game's data the device has not received yet (`shell.pending_data`).
    `stage(key, state, detail, percent)` reports the steps: key is an en.json key, state
    'running', 'done' or 'failed'."""
    root = Path(root)
    template = template or shell.find_template()
    if not template:
        return Outcome(False, ('win.install.noTemplate',), 'win.install.noTemplate.next')
    exe = signer_exe or signer.find()
    if not exe:
        return Outcome(False, ('win.sign.fail.missing',))
    games = shell.Library.load(root).present()
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

    # 1. the app with every game in it
    stage('win.install.stage.prepare', 'running', '', 0)
    try:
        app = shell.assemble(root, template, games)
    except (OSError, ValueError) as e:
        stage('win.install.stage.prepare', 'failed', str(e), 0)
        return Outcome(False, ('win.install.prepareFailed', str(e)))
    log(f'shared app: {len(games)} game(s): {", ".join(g.name for g in games)}\n')
    stage('win.install.stage.prepare', 'done', f'{len(games)}', 100)
    if cancelled():
        return Outcome(False, ('msg.stopped',))

    # 2. sign and install
    stage('win.install.stage.sign', 'running', name, 0)
    r = signer.sign_and_install(app, udid, log=log, exe=exe, started=started,
                                progress=lambda p: stage('win.install.stage.sign', 'running', f'{p}%', p))
    if not r.ok:
        last = next((ln for ln in reversed(r.output.splitlines()) if ln.strip()), '')
        stage('win.install.stage.sign', 'failed', last[:160], 0)
        return Outcome(False, ('win.install.signFailed', last[:300] or 'see the log'), r.failure)
    stage('win.install.stage.sign', 'done', name, 100)

    # 3. remember it: the bundle ID the signer gave the app, found on the device
    known = Devices(root)
    prev = known.get(udid) or DeviceState()
    try:
        bundle = dv.find_shell(dev, preferred=prev.bundle)
    except dv.DeviceError as e:
        log(f'the app list: {e}\n')
        bundle = ''
    if not bundle:
        return Outcome(False, ('win.install.notFound',))
    state = DeviceState(bundle=bundle, signed=time.time(), games=library_hash(games, template),
                        name=name, receipts=prev.receipts if prev.bundle == bundle else {})
    known.put(udid, state)

    # 4. the game data the device lacks
    if data is None:
        data = shell.pending_data(root, games, state.receipts)
    copied = 0
    for title_id, folder in data:
        if cancelled():
            break
        stamp = data_stamp(folder)
        force = ['romfs.img'] if stamp and state.receipts.get(title_id.upper()) != stamp else []
        stage('win.install.stage.data', 'running', name, 0)
        try:
            n, _bytes = dv.copy_game_data(
                dev, bundle, title_id, Path(folder), force=force, log=log, cancelled=cancelled,
                progress=lambda done, total: stage('win.install.stage.data', 'running',
                                                   f'{done / 1e9:.1f} / {total / 1e9:.1f} GB',
                                                   done * 100 / max(total, 1)))
        except dv.DeviceError as e:
            stage('win.install.stage.data', 'failed', str(e)[:160], 0)
            return Outcome(False, ('win.install.dataFailed', str(e)), 'win.install.dataFailed.next', bundle)
        copied += n
        state.receipts[title_id.upper()] = stamp
        known.put(udid, state)
        stage('win.install.stage.data', 'done', name, 100)
    if not prev.bundle:
        # the first install on this device: iOS opens the app only once the player trusts the
        # Apple ID's certificate and turns Developer Mode on
        return Outcome(True, ('win.install.firstTime', name), '', bundle, copied)
    return Outcome(True, ('dev.installed', name), '', bundle, copied)
