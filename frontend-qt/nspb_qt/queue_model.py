"""The build queue: several games built one after another, unattended (overnight after dumping a few games).

Add to queue takes the game chosen on the Builds page with its choices (files, keys, Save to, Play on) and empties the
game rows for the next one. Start queue builds the waiting games in order through the normal build (Model.start_build):
each one's own choices are loaded first, a failed game is marked and the queue goes on. The queue is kept in the
settings, so it survives a restart (a game that was building is waiting again).

While the queue runs, a game built for the shared app is not installed on its own (an install per game would sign and
copy over and over); when the queue ends, the device chosen under Install on gets one install with every game the queue
built, if it is plugged in and ready.

The estimates are rough and say so: the disk space a build takes and how long it runs, from the size of the game's
files. The first builds use a default; after that, what this PC's own builds took (the drop in free space and the time,
per GB of game files). The queue card shows the free space left after every waiting game, the one chosen on the page
included.
"""
from __future__ import annotations

import json
import os
import shutil
import time
import uuid
from dataclasses import asdict, dataclass, field
from pathlib import Path

GB = 1024 ** 3
#: Before this PC has built anything: the build folder (the extracted files, the rewritten code, the shaders) and the
#: game data packed beside it take about this many times the game's files, plus a fixed part.
DEFAULT_SPACE_FACTOR = 2.6
DEFAULT_SPACE_BASE = 2 * GB
#: ... and a build takes about this long: a fixed part (the toolchain, the code) and minutes per GB of game files.
DEFAULT_SECONDS_BASE = 15 * 60
DEFAULT_SECONDS_PER_GB = 4 * 60
#: A game whose build folder exists already reuses most of it (extracted files, shaders).
REUSE_SPACE = 0.25
REUSE_TIME = 0.4
#: How many finished builds the estimates learn from.
HISTORY = 12


@dataclass
class QueueItem:
    id: str
    name: str
    key: str                        # the build key (title ID) of the game
    folder: str = ''                # a game folder or a NUP, else ''
    game_dir: str = ''
    base: str = ''
    update: str = ''
    dlc: list = field(default_factory=list)
    keys: str = ''
    out_dir: str = ''
    output_mode: str = 'device'
    ipa_kind: str = 'shared'
    bc_on_cpu: bool = False
    input_bytes: int = 0
    reuse: bool = False             # its build folder exists already
    state: str = 'waiting'          # waiting | running | done | failed
    note: str = ''
    started: float = 0.0
    seconds: float = 0.0            # how long it took (done or failed)

    @classmethod
    def from_dict(cls, d: dict) -> 'QueueItem | None':
        try:
            known = {k: d[k] for k in cls.__dataclass_fields__ if k in d}
            item = cls(**known)
        except TypeError:
            return None
        return item if item.id and (item.folder or item.base) else None


def path_bytes(p: str) -> int:
    """The size of a file, or of every file under a folder."""
    if not p:
        return 0
    try:
        if os.path.isfile(p):
            return os.path.getsize(p)
        total = 0
        for root, _dirs, files in os.walk(p):
            for f in files:
                try:
                    total += os.path.getsize(os.path.join(root, f))
                except OSError:
                    pass
        return total
    except OSError:
        return 0


_SIZES: dict[str, int] = {}


def cached_bytes(p: str) -> int:
    """path_bytes, once per path in a session: the window asks on every refresh, and a game folder holds thousands
    of files."""
    if p not in _SIZES:
        _SIZES[p] = path_bytes(p)
    return _SIZES[p]


def format_bytes(n: int) -> str:
    return f'{n / GB:.1f} GB' if abs(n) >= GB / 10 else f'{max(0, n) // (1024 * 1024)} MB'


def format_duration(seconds: float, t) -> str:
    minutes = max(1, int(round(seconds / 60)))
    if minutes < 60:
        return t('queue.minutes', minutes)
    return t('queue.hours', minutes // 60, minutes % 60)


def free_bytes(folder: str) -> int | None:
    """Free space on the drive of `folder` (its nearest existing parent), None when it cannot be read."""
    probe = Path(folder) if folder else None
    while probe is not None and not probe.exists():
        probe = probe.parent if probe.parent != probe else None
    try:
        return shutil.disk_usage(str(probe or '.')).free
    except OSError:
        return None


def drive_of(folder: str) -> str:
    """What identifies a drive for adding up the space the queue takes on it."""
    try:
        p = Path(folder).resolve()
    except OSError:
        p = Path(folder)
    if os.name == 'nt':
        return (p.drive or str(p)).upper()
    probe = p
    while not probe.exists() and probe.parent != probe:
        probe = probe.parent
    try:
        return str(probe.stat().st_dev)
    except OSError:
        return '/'


class Estimator:
    """Space and time of a build from the size of its game files, learned from this PC's own builds."""

    def __init__(self, history: list[dict] | None = None):
        self.history = [h for h in (history or []) if isinstance(h, dict) and h.get('input', 0) > 0]

    def _ratio(self, key: str) -> float | None:
        vals = sorted(h[key] / (h['input'] / GB) for h in self.history if h.get(key, 0) > 0 and not h.get('reuse'))
        if not vals:
            return None
        return vals[len(vals) // 2]          # the median: one odd build does not swing it

    def space(self, item: QueueItem) -> int:
        learned = self._ratio('space')
        need = (learned * item.input_bytes / GB) if learned else (item.input_bytes * DEFAULT_SPACE_FACTOR + DEFAULT_SPACE_BASE)
        return int(need * (REUSE_SPACE if item.reuse else 1.0))

    def seconds(self, item: QueueItem) -> float:
        learned = self._ratio('seconds')
        gb = item.input_bytes / GB
        t = (learned * gb) if learned else (DEFAULT_SECONDS_BASE + gb * DEFAULT_SECONDS_PER_GB)
        return max(5 * 60, t * (REUSE_TIME if item.reuse else 1.0))

    def learned(self) -> bool:
        return any(not h.get('reuse') for h in self.history)


class QueueMixin:
    """Needs from the model: settings, t(), log(), the build inputs and choices, start_build(), running, finished,
    install_on_device(), device_titles(), device_by_udid(), device_install_ready, install_udid."""

    def _queue_init(self) -> None:
        self.queue: list[QueueItem] = []
        self.queue_running = False
        self._queue_current = ''            # the id of the item building now
        self._queue_free_before: int | None = None
        self._queue_built_titles: list[str] = []
        self._queue_final_install = False
        if getattr(self, '_persist_choices', False):
            try:
                raw = json.loads(str(self.settings.value('buildQueue', '[]', type=str) or '[]'))
            except ValueError:
                raw = []
            for d in raw if isinstance(raw, list) else []:
                item = QueueItem.from_dict(d) if isinstance(d, dict) else None
                if item is not None:
                    if item.state == 'running':
                        item.state = 'waiting'
                    self.queue.append(item)
        from PySide6.QtCore import Qt
        # queued: the build's thread emits, and the next build must start on the model's own (main) thread
        self.finished.connect(self._queue_on_finished, Qt.QueuedConnection)

    # ---------------------------------------------------------------- keeping it

    def _queue_save(self) -> None:
        if getattr(self, '_persist_choices', False):
            self.settings.setValue('buildQueue', json.dumps([asdict(i) for i in self.queue]))
        self.queueChanged.emit()

    def estimator(self) -> Estimator:
        try:
            hist = json.loads(str(self.settings.value('buildStats', '[]', type=str) or '[]'))
        except ValueError:
            hist = []
        return Estimator(hist if isinstance(hist, list) else [])

    def _remember_stats(self, item: QueueItem, used: int | None, seconds: float) -> None:
        if not getattr(self, '_persist_choices', False) or item.input_bytes <= 0:
            return
        est = self.estimator()
        entry = {'input': item.input_bytes, 'seconds': round(seconds), 'reuse': item.reuse}
        if used is not None and used > 0:
            entry['space'] = used
        self.settings.setValue('buildStats', json.dumps((est.history + [entry])[-HISTORY:]))

    # ---------------------------------------------------------------- adding

    @property
    def can_queue(self) -> bool:
        """The game chosen on the page can be queued (a build may run meanwhile)."""
        inputs_ready = self.game_folder is not None or (bool(self.base_path) and bool(self.keys_path))
        return self.repo_ok and inputs_ready and not self.game_folder_problem

    def current_queue_item(self) -> QueueItem | None:
        """The game chosen on the page as a queue item, None when nothing is chosen."""
        if not self.can_queue:
            return None
        f = self.game_folder
        key = self.build_key
        out = self.out_dir or (f.folder if f is not None else str(Path(self.base_path).parent))
        files = [f.script_input] if f is not None else [self.base_path, self.update_path] + list(self.dlc_paths)
        name = ''
        try:
            from . import library as lib
            name = lib.GameFolder.profile_name(key, self.engine_path) or ''
        except Exception:
            name = ''
        if not name:
            try:
                from . import library as lib
                name = lib.clean_game_name(f.folder if f is not None else self.base_path)
            except Exception:
                name = ''
        name = name or Path(f.folder if f is not None else self.base_path).stem
        return QueueItem(id=uuid.uuid4().hex[:10], name=name, key=key,
                         folder=(f.nup or f.folder) if f is not None else '', game_dir=self.game_dir,
                         base='' if f is not None else self.base_path,
                         update='' if f is not None else self.update_path,
                         dlc=[] if f is not None else list(self.dlc_paths),
                         keys=self.keys_path, out_dir=out, output_mode=self.output_mode, ipa_kind=self.ipa_kind,
                         bc_on_cpu=self.bc_on_cpu, input_bytes=sum(cached_bytes(p) for p in files if p),
                         reuse=Path(out, f'{key}_build').is_dir())

    def add_to_queue(self) -> QueueItem | None:
        item = self.current_queue_item()
        if item is None:
            return None
        self.queue.append(item)
        # the rows are emptied for the next game (prod.keys, Save to and Play on stay)
        self.leave_game_folder()
        self.game_folder = None
        self.base_path = self.update_path = ''
        self.dlc_paths = []
        self.game_dir = ''
        self.log(self.t('queue.added', item.name) + '\n')
        self._queue_save()
        self.repoChanged.emit()
        return item

    def remove_from_queue(self, item_id: str) -> None:
        self.queue = [i for i in self.queue if not (i.id == item_id and i.state != 'running')]
        self._queue_save()

    def move_in_queue(self, item_id: str, step: int) -> None:
        idx = next((n for n, i in enumerate(self.queue) if i.id == item_id), -1)
        to = idx + step
        if idx < 0 or not (0 <= to < len(self.queue)):
            return
        self.queue[idx], self.queue[to] = self.queue[to], self.queue[idx]
        self._queue_save()

    def clear_finished(self) -> None:
        self.queue = [i for i in self.queue if i.state in ('waiting', 'running')]
        self._queue_save()

    # ---------------------------------------------------------------- the summary

    def queue_summary(self, extra: QueueItem | None = None) -> dict:
        """What the waiting games (and `extra`, the game chosen on the page) still take: their count, the seconds
        (the one building counts what is left of it) and, per drive, the free space now and after them."""
        est = self.estimator()
        items = [i for i in self.queue if i.state in ('waiting', 'running')] + ([extra] if extra else [])
        seconds = 0.0
        drives: dict[str, dict] = {}
        for i in items:
            s = est.seconds(i)
            if i.state == 'running' and i.started:
                s = max(60.0, s - (time.time() - i.started))
            seconds += s
            d = drives.setdefault(drive_of(i.out_dir), {'folder': i.out_dir, 'need': 0, 'free': None})
            if i.state != 'running':          # the one building takes its space as it goes: free space shows it
                d['need'] += est.space(i)
        for d in drives.values():
            d['free'] = free_bytes(d['folder'])
            d['after'] = None if d['free'] is None else d['free'] - d['need']
        return {'count': len(items), 'seconds': seconds, 'drives': list(drives.values()), 'learned': est.learned()}

    # ---------------------------------------------------------------- running

    def start_queue(self) -> None:
        if self.queue_running:
            return
        if not any(i.state == 'waiting' for i in self.queue):
            return
        self.queue_running = True
        self._queue_built_titles = []
        self._queue_final_install = False
        self.queueChanged.emit()
        if not self.running:
            self._queue_next()

    def stop_queue(self) -> None:
        """The game building now finishes; the next one does not start."""
        self.queue_running = False
        self.queueChanged.emit()

    def _queue_load(self, item: QueueItem) -> None:
        self.keys_path = item.keys or self.keys_path
        self.out_dir = item.out_dir
        self.output_mode = item.output_mode
        self.ipa_kind = item.ipa_kind
        self.bc_on_cpu = item.bc_on_cpu
        if item.folder:
            self.take_game_folder(item.folder)
        else:
            self.leave_game_folder()
            self.game_dir = item.game_dir
            self.base_path = item.base
            self.update_path = item.update
            self.dlc_paths = list(item.dlc)
        self.repoChanged.emit()

    def _queue_next(self) -> None:
        if not self.queue_running or self.running:
            return
        item = next((i for i in self.queue if i.state == 'waiting'), None)
        if item is None:
            self._queue_end()
            return
        missing = [p for p in ([item.folder] if item.folder else [item.base, item.keys]) if p and not os.path.exists(p)]
        if missing:
            item.state, item.note = 'failed', self.t('queue.missing', missing[0])
            self._queue_save()
            self._queue_next()
            return
        self._queue_load(item)
        item.state, item.started, item.note = 'running', time.time(), ''
        self._queue_current = item.id
        self._queue_free_before = free_bytes(item.out_dir)
        self._queue_save()
        self.log(self.t('queue.starting', item.name) + '\n')
        self.start_build()

    def _queue_end(self) -> None:
        """Every game is built: one install of the shared-app games on the chosen device, if it is there."""
        self.queue_running = False
        self._queue_current = ''
        titles = self._queue_built_titles
        self._queue_built_titles = []
        udid = getattr(self, 'install_udid', '')
        if titles and self.device_install_ready and udid and self.device_by_udid(udid) is not None:
            on_device = self.device_titles(udid)
            self._queue_final_install = True
            self.queueChanged.emit()
            self.install_on_device(udid, titles=sorted(set(on_device) | set(titles)) if on_device else None)
            return
        self.queueChanged.emit()

    def queue_defers_install(self) -> bool:
        """A queued shared-app game is not installed on its own (after_framework_build): the queue's end does it."""
        return bool(self._queue_current)

    def queue_built(self, title_id: str) -> None:
        self._queue_built_titles.append(title_id.upper())

    def _queue_on_finished(self, ok: bool, note: str) -> None:
        if self._queue_final_install:
            self._queue_final_install = False
            self.queueChanged.emit()
            return
        item = next((i for i in self.queue if i.id == self._queue_current), None)
        if item is None:
            return
        self._queue_current = ''
        item.state = 'done' if ok else 'failed'
        item.note = note
        item.seconds = time.time() - item.started if item.started else 0.0
        after = free_bytes(item.out_dir)
        used = (self._queue_free_before - after) if (self._queue_free_before is not None and after is not None) else None
        if ok:
            self._remember_stats(item, used, item.seconds)
        self._queue_save()
        if self.queue_running:
            from PySide6.QtCore import QTimer
            QTimer.singleShot(1500, self._queue_next)       # after the window has taken in this build's end
