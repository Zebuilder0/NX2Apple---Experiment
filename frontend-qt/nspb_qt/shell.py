"""The shared app on Windows: one iPhone and iPad app that holds every game built for it.

The Mac launcher builds this app with Xcode (`dm/ios/tools/build_shell.sh`). Windows cannot
compile its Swift, so the Windows zip carries the app ready-made and empty: `shell/DmShell.app`,
built unsigned on GitHub's macOS runner by `build-qt.yml` (`frontend-qt/tools/build_shell_template.sh`)
with its executable's Increased Memory Limit request in an ad-hoc signature. The app has no game
code of its own: every game is a `DmGame<title ID>.framework` with its own engine host, which
the build makes on this PC (`--shell-framework`, `win/build_app.py`). The app finds the
frameworks in its `Frameworks/` folder when it starts.

So an install is: copy the empty app, put every game's framework in it, sign it with the
player's Apple ID and install it (`win/signer.py`), then copy the game's data into the app's
Documents (`win/device.py`). The bundle ID is the template's `org.nxnative.shell`, which the
signer makes `org.nxnative.shell.<team ID>`, the same on every install: the device keeps the app's
saves and game data when it is installed again (after 7 days for a free Apple ID).

`shell.json` in the shell cache folder lists the games, in the Mac launcher's format.
"""
from __future__ import annotations

import json
import os
import plistlib
import shutil
import sys
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

APP_NAME = 'DmShell.app'
EXECUTABLE = 'DmShell'
DEFAULT_BUNDLE_ID = 'org.nxnative.shell'
DISPLAY_NAME = 'NX2Apple'


@dataclass
class Game:
    titleID: str
    name: str
    framework: str


@dataclass
class Library:
    """`<root>/shell.json`: the games of the shared app (the Mac launcher's ShellLibrary)."""
    bundleID: str = DEFAULT_BUNDLE_ID
    team: str = ''
    games: list[Game] = field(default_factory=list)

    @staticmethod
    def path(root: Path) -> Path:
        return Path(root) / 'shell.json'

    @classmethod
    def load(cls, root: Path) -> 'Library':
        try:
            d = json.loads(cls.path(root).read_text(encoding='utf-8'))
            games = [Game(str(g['titleID']), str(g.get('name', '')), str(g['framework']))
                     for g in d.get('games', []) if g.get('titleID') and g.get('framework')]
            return cls(str(d.get('bundleID') or DEFAULT_BUNDLE_ID), str(d.get('team') or ''), games)
        except (OSError, ValueError, TypeError, KeyError):
            return cls()

    def save(self, root: Path) -> None:
        root = Path(root)
        root.mkdir(parents=True, exist_ok=True)
        d = {'bundleID': self.bundleID, 'team': self.team,
             'games': [{'framework': g.framework, 'name': g.name, 'titleID': g.titleID} for g in self.games]}
        tmp = self.path(root).with_suffix('.json.tmp')
        tmp.write_text(json.dumps(d, indent=2, sort_keys=True), encoding='utf-8')
        os.replace(tmp, self.path(root))

    def add(self, game: Game) -> None:
        """A rebuilt game replaces its entry, a new one is appended."""
        for i, g in enumerate(self.games):
            if g.titleID.upper() == game.titleID.upper():
                self.games[i] = game
                return
        self.games.append(game)

    def remove(self, title_id: str) -> None:
        self.games = [g for g in self.games if g.titleID.upper() != title_id.upper()]

    def present(self) -> list[Game]:
        """The games whose framework is still whole (its manifest is there)."""
        return [g for g in self.games if (Path(g.framework) / 'game.manifest.json').is_file()]


def frameworks_dir(root: Path) -> Path:
    return Path(root) / 'frameworks'


def built_framework(work_dir: Path) -> Path | None:
    """The framework a `--shell-framework <work>/shell-framework` build wrote: the newest
    `DmGame*.framework` there (a build without a title ID in its file names names it after the
    title ID it read, the Mac launcher's ShellInstall.builtFramework)."""
    folder = Path(work_dir) / 'shell-framework'
    try:
        found = [p for p in folder.iterdir()
                 if p.is_dir() and p.name.startswith('DmGame') and p.name.endswith('.framework')
                 and len(p.name) > len('DmGame.framework') and (p / 'game.manifest.json').is_file()]
    except OSError:
        return None
    return max(found, key=lambda p: (p.stat().st_mtime, p.name)) if found else None


def title_id_of(framework: Path) -> str:
    name = Path(framework).name
    return name[len('DmGame'):-len('.framework')] if name.startswith('DmGame') and name.endswith('.framework') else ''


def mirror(framework: Path, root: Path) -> Path:
    """Copy a built framework into the shell cache (`<root>/frameworks/`), so the game stays in
    the shared app when its build folder is deleted. Replaced only once the copy is whole."""
    dest_dir = frameworks_dir(root)
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / Path(framework).name
    tmp = dest_dir / f'.copy-{uuid.uuid4().hex[:8]}'
    try:
        shutil.copytree(framework, tmp)
        shutil.rmtree(dest, ignore_errors=True)
        os.replace(tmp, dest)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return dest


def manifest(framework: Path) -> dict:
    try:
        return json.loads((Path(framework) / 'game.manifest.json').read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return {}


def add_built_game(root: Path, built: Path) -> Game:
    """Mirror a freshly built framework and list it in shell.json. Returns its entry."""
    m = manifest(built)
    fw = mirror(built, root)
    tid = (m.get('title_id') or title_id_of(fw)).upper()
    lib = Library.load(root)
    game = Game(titleID=tid, name=str(m.get('name') or tid), framework=str(fw))
    lib.add(game)
    lib.save(root)
    return game


# ---------------------------------------------------------------- the empty app

def template_candidates() -> list[Path]:
    out: list[Path] = []
    if env := os.environ.get('NSPB_SHELL_TEMPLATE'):
        out.append(Path(env))
    meipass = getattr(sys, '_MEIPASS', None)
    if meipass:
        out += [Path(meipass) / 'shell' / APP_NAME, Path(meipass).parent / 'shell' / APP_NAME]
    exe_dir = Path(sys.executable).resolve().parent
    out += [exe_dir / 'shell' / APP_NAME, exe_dir / '_internal' / 'shell' / APP_NAME]
    return out


def template_problem(app: Path) -> str:
    """'' when `app` is a usable empty shared app, else what is wrong with it."""
    info = Path(app) / 'Info.plist'
    if not info.is_file():
        return f'{app} has no Info.plist'
    try:
        with open(info, 'rb') as f:
            p = plistlib.load(f)
    except (OSError, plistlib.InvalidFileException, ValueError) as e:
        return f'{info} cannot be read ({e})'
    if p.get('CFBundleExecutable') != EXECUTABLE:
        return f'{app} is not the shared app (executable {p.get("CFBundleExecutable")!r})'
    if not (Path(app) / EXECUTABLE).is_file():
        return f'{app} has no {EXECUTABLE} executable'
    return ''


def find_template() -> Path | None:
    for p in template_candidates():
        if p.is_dir() and not template_problem(p):
            return p
    return None


def template_version(app: Path) -> str:
    try:
        with open(Path(app) / 'Info.plist', 'rb') as f:
            p = plistlib.load(f)
        return str(p.get('CFBundleShortVersionString') or '')
    except (OSError, plistlib.InvalidFileException, ValueError):
        return ''


def template_min_ios(app: Path) -> str:
    """The oldest iOS the empty app runs on (its MinimumOSVersion), '' when it does not say."""
    try:
        with open(Path(app) / 'Info.plist', 'rb') as f:
            return str(plistlib.load(f).get('MinimumOSVersion') or '')
    except (OSError, plistlib.InvalidFileException, ValueError):
        return ''


def version_tuple(v: str) -> tuple[int, ...]:
    out = []
    for part in str(v).split('.'):
        digits = ''.join(ch for ch in part if ch.isdigit())
        if not digits:
            break
        out.append(int(digits))
    return tuple(out)


def present_titles(games: list['Game'], titles) -> list['Game']:
    """The games of `games` whose title ID is in `titles` (all of them when `titles` is None), in library order."""
    if titles is None:
        return list(games)
    want = {str(t).upper() for t in titles}
    return [g for g in games if g.titleID.upper() in want]


#: The pictures the app's library reads beside a framework (ShellHost GameCatalogue.imageExtensions)
BANNER_EXTS = ('png', 'jpg', 'jpeg', 'heic', 'webp')


def place_banner(framework: Path, source: str | None) -> str | None:
    """The 16:9 picture the app's library shows for a game, as `<framework>/banner.<ext>`: the
    player's own pick, else the eShop banner the launcher caches (the Mac launcher's
    ShellInstall.placeBanner). Without one, an older banner goes and the library shows the
    framework's square icon.png. Returns the picture used."""
    framework = Path(framework)
    for ext in BANNER_EXTS:
        (framework / f'banner.{ext}').unlink(missing_ok=True)
    if not source or not os.path.isfile(source):
        return None
    ext = Path(source).suffix.lower().lstrip('.')
    shutil.copyfile(source, framework / f'banner.{ext if ext in BANNER_EXTS else "jpg"}')
    return source


def assemble(root: Path, template: Path, games: list[Game],
             banner: 'Callable[[str], str | None] | None' = None) -> Path:
    """`<root>/stage/DmShell.app`: a fresh copy of the empty app with every game's framework in
    `Frameworks/`, each with its banner (`banner(title ID)` → a picture, as the Mac launcher puts
    it in). Always from the template, never from an earlier signed copy: the signer adds the team
    ID to the bundle ID, and signing a signed copy would add it twice."""
    if not games:
        raise ValueError('no game is built for the shared app yet')
    stage = Path(root) / 'stage'
    app = stage / APP_NAME
    shutil.rmtree(app, ignore_errors=True)
    if app.exists():
        raise OSError(f'{app} cannot be replaced (is a file in it open?)')
    stage.mkdir(parents=True, exist_ok=True)
    shutil.copytree(template, app)
    fw_dir = app / 'Frameworks'
    fw_dir.mkdir(exist_ok=True)
    for g in games:
        src = Path(g.framework)
        shutil.copytree(src, fw_dir / src.name)
        if banner:
            try:
                place_banner(fw_dir / src.name, banner(g.titleID))
            except OSError:          # a picture that cannot be copied leaves the icon, not a failed install
                pass
    return app


# ---------------------------------------------------------------- the games' data

def data_stamp(folder: Path) -> str:
    """A cheap identity of a game's data: romfs.img's size and modification time. A rebuilt image
    gets a new one, so the copy happens again even when the size is the same."""
    try:
        st = (Path(folder) / 'romfs.img').stat()
        return f'{st.st_size}:{st.st_mtime_ns}'
    except OSError:
        return ''


def remember_data(root: Path, title_id: str, folder: Path) -> None:
    """`<root>/data.json`: the folder of a built game's data and its stamp, so an install later (a
    device plugged in after the build) copies it too."""
    path = Path(root) / 'data.json'
    try:
        d = json.loads(path.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        d = {}
    d[title_id.upper()] = {'folder': str(folder), 'stamp': data_stamp(folder)}
    Path(root).mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix('.tmp')
    tmp.write_text(json.dumps(d, indent=2, sort_keys=True), encoding='utf-8')
    os.replace(tmp, path)


def pending_data(root: Path, games: list[Game], receipts: dict) -> list[tuple[str, Path]]:
    """The (title ID, data folder) of the shared app's games whose data a device has not received
    (`receipts`: title ID → the stamp it got). A folder whose romfs.img changed since its game was
    built is left out: its data is no longer the data that game was built with (a rebuild packed
    new data and remember_data stamps it again; a folder from before the per-game layout,
    `<output>/romfs`, may hold another game's now)."""
    try:
        d = json.loads((Path(root) / 'data.json').read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return []
    out = []
    for g in games:
        e = d.get(g.titleID.upper()) or {}
        folder, stamp = Path(e.get('folder') or ''), e.get('stamp') or ''
        if stamp and data_stamp(folder) == stamp and receipts.get(g.titleID.upper()) != stamp:
            out.append((g.titleID.upper(), folder))
    return out


def signed_bundle_id(base: str, team: str) -> str:
    """The bundle ID the signer gives the app: the template's with the team ID appended."""
    return f'{base}.{team}' if team else base
