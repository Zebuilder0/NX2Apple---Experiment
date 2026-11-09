"""The folder the build script reads when the picked game files live in more than one folder (#132).

The script keys a provisional profile's shader split and shader build on the files' size and
modification time and on the profile's path (<input folder>/<title ID>_build/profile), so the folder
must be the same one on every build of a game: it sits in the game's build folder, is never deleted
after a build, and holds exactly the current selection. The build's own folders beside the files
(<title ID>_build, <title ID>_survey) are left alone.
"""
from __future__ import annotations

import os
import shutil
from pathlib import Path

FOLDER_NAME = 'staging'
GAME_SUFFIXES = {'.nsp', '.xci', '.nsz', '.xcz'}


def folder(work_dir: str) -> str:
    return str(Path(work_dir, FOLDER_NAME))


def staged_name(name: str) -> str:
    """The name a file has in the staging folder: a game file keeps its name with the extension in lowercase. The script
    finds packages with *.nsp (and .xci, .nsz, .xcz) and that glob is case-sensitive, so Game [0100F2C0115B6000].NSP
    was not found ("no NSP with a readable title ID", #554)."""
    p = Path(name)
    suffix = p.suffix
    if suffix.lower() in GAME_SUFFIXES and suffix != suffix.lower():
        return p.stem + suffix.lower()
    return name


def needs_lowercase_name(path: str) -> bool:
    """A game file with an upper or mixed case extension: the script would not find it as it is."""
    name = Path(path).name
    return staged_name(name) != name


def _same(src: str, dst: Path) -> bool:
    """dst is already src: the same file, or a copy with its size and date."""
    try:
        if os.path.samefile(src, dst):
            return True
        a, b = os.stat(src), os.stat(dst)
        return a.st_size == b.st_size and a.st_mtime_ns == b.st_mtime_ns
    except OSError:
        return False


class StagingError(OSError):
    """A picked file could not be put in the staging folder (or a file from an earlier selection could not be taken
    out of it): the build would not be the one the player asked for. `path` is the file, `reason` why."""

    def __init__(self, path: str, reason: object):
        super().__init__(f'{path}: {reason}')
        self.path, self.reason = str(path), str(reason)


def _why(e: OSError) -> str:
    return e.strerror or str(e) or type(e).__name__


def _discard(path: Path) -> None:
    try:
        path.unlink(missing_ok=True)
    except OSError:
        pass


def sync(files: list[str], into: str, *, hard_links: bool = True) -> int:
    """Make `into` hold exactly `files` (by file name), with their dates. Returns how many were staged.

    Each file is hard-linked when `hard_links` (NTFS and APFS both have them: no second copy of gigabytes), and copied
    when it cannot be (another volume, FAT/exFAT, ReFS). A file that can be neither linked nor copied raises
    StagingError, and half a copy is removed: the build used to go on without the picked update or DLC, with no word.
    A stale file that cannot be removed raises it too, since the script would read it with the new selection."""
    root = Path(into)
    wanted = {staged_name(Path(f).name): f for f in files if f}
    try:
        root.mkdir(parents=True, exist_ok=True)
        entries = list(root.iterdir())
    except OSError as e:
        raise StagingError(str(root), _why(e)) from e
    for entry in entries:   # a stale entry from an earlier selection goes: only game files and links
        if entry.is_symlink() or (entry.is_file() and entry.suffix.lower() in GAME_SUFFIXES):
            src = wanted.get(entry.name)
            if src and entry.exists() and _same(src, entry):
                continue
            try:
                entry.unlink(missing_ok=True)
            except OSError as e:
                raise StagingError(str(entry), _why(e)) from e
    linked = 0
    for name, src in wanted.items():
        dst = root / name
        if dst.exists() and _same(src, dst):
            linked += 1
            continue
        try:
            if not hard_links:
                raise OSError('copying')
            os.link(src, dst)
        except OSError:
            try:
                shutil.copyfile(src, dst)
            except OSError as e:
                _discard(dst)                  # half a copy (a full disk) is not the file
                raise StagingError(src, _why(e)) from e
            try:
                shutil.copystat(src, dst)      # the date the script's fingerprints read (copy2's second half)
            except OSError:
                pass                           # a drive that keeps no dates still builds; the next one copies again
        linked += 1
    return linked
