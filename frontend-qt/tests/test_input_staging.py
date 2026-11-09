"""The staging folder for files picked from several folders (#132): the same selection stages to the
same paths with the same sizes and dates, and the folder holds exactly the current selection."""
from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'frontend-qt'))

from nspb_qt import input_staging   # noqa: E402


def make(path: Path, age: int) -> str:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b'x' * 4096)
    t = path.stat().st_mtime_ns - age * 10**9
    os.utime(path, ns=(t, t))
    return str(path)


def seen(d: str) -> list[tuple]:
    return [(p.name, p.stat().st_size, p.stat().st_mtime_ns) for p in sorted(Path(d).iterdir())]


class InputStagingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        self.work = str(self.root / '0100000000000000_build')

    def test_two_stagings_are_identical(self):
        for hard in (True, False):
            files = [make(self.root / 'a' / 'base.nsp', 5000), make(self.root / 'b' / 'update.nsp', 9000)]
            d = input_staging.folder(self.work + str(hard))
            self.assertEqual(input_staging.sync(files, d, hard_links=hard), 2)
            first = seen(d)
            self.assertEqual(input_staging.sync(files, d, hard_links=hard), 2)
            self.assertEqual(seen(d), first)
            self.assertEqual([p.stat().st_mtime_ns for p in sorted(Path(d).iterdir())],
                             [os.stat(f).st_mtime_ns for f in sorted(files, key=os.path.basename)])

    def test_stale_entry_removed_build_folders_kept(self):
        base = make(self.root / 'a' / 'base.nsp', 100)
        upd = make(self.root / 'b' / 'update.nsp', 200)
        d = input_staging.folder(self.work)
        input_staging.sync([base, upd], d)
        (Path(d) / '0100000000000000_build' / 'profile').mkdir(parents=True)
        self.assertEqual(input_staging.sync([base], d), 1)
        self.assertEqual({p.name for p in Path(d).iterdir()}, {'base.nsp', '0100000000000000_build'})

    def test_extension_is_lowercased_in_the_staged_name(self):   # #554
        S = input_staging
        self.assertEqual(S.staged_name('Game [0100F2C0115B6000].NSP'), 'Game [0100F2C0115B6000].nsp')
        self.assertEqual(S.staged_name('Game [0100F2C0115B6000].Nsz'), 'Game [0100F2C0115B6000].nsz')
        self.assertEqual(S.staged_name('Game.XcI'), 'Game.xci')
        self.assertEqual(S.staged_name('Game.nsp'), 'Game.nsp')
        self.assertEqual(S.staged_name('Game.NSP.XCZ'), 'Game.NSP.xcz')
        self.assertEqual(S.staged_name('PROD.KEYS'), 'PROD.KEYS')
        self.assertTrue(S.needs_lowercase_name('/x/Game [0100F2C0115B6000].NSP'))
        self.assertTrue(S.needs_lowercase_name('/x/Game.Nsp'))
        self.assertFalse(S.needs_lowercase_name('/x/Game.nsp'))
        self.assertFalse(S.needs_lowercase_name('/x/Game.NUP'))

    def test_uppercase_file_is_staged_under_a_lowercase_name(self):   # #554
        for hard in (True, False):
            upper = make(self.root / 'a' / 'Game [0100F2C0115B6000].NSP', 100)
            mixed = make(self.root / 'a' / 'Game [0100F2C0115B6800][v65536].Nsp', 100)
            d = input_staging.folder(self.work + str(hard))
            self.assertEqual(input_staging.sync([upper, mixed], d, hard_links=hard), 2)
            self.assertEqual(sorted(p.name for p in Path(d).iterdir()),
                             ['Game [0100F2C0115B6000].nsp', 'Game [0100F2C0115B6800][v65536].nsp'])
            self.assertEqual(input_staging.sync([upper, mixed], d, hard_links=hard), 2)   # again: nothing stale
            self.assertEqual(len(list(Path(d).iterdir())), 2)

    def test_a_file_that_cannot_be_staged_stops_instead_of_being_left_out(self):
        import errno
        import shutil
        from unittest import mock
        base = make(self.root / 'a' / 'base.nsp', 100)
        upd = make(self.root / 'b' / 'update.nsp', 100)
        d = input_staging.folder(self.work)
        real_copy = shutil.copyfile

        def full_disk(src, dst, *a, **k):
            if src == upd:
                Path(dst).write_bytes(b'half')            # a copy cut off by a full disk
                raise OSError(errno.ENOSPC, 'No space left on device')
            return real_copy(src, dst, *a, **k)
        for hard in (True, False):   # a link that fails (another volume) falls back to the copy that fails
            with self.subTest(hard_links=hard), \
                    mock.patch.object(input_staging.os, 'link', side_effect=OSError('another volume')), \
                    mock.patch.object(input_staging.shutil, 'copyfile', side_effect=full_disk):
                with self.assertRaises(input_staging.StagingError) as cm:
                    input_staging.sync([base, upd], d, hard_links=hard)
                self.assertIsInstance(cm.exception, OSError)
                self.assertEqual(cm.exception.path, upd)
                self.assertIn('No space', cm.exception.reason)
                self.assertFalse((Path(d) / 'update.nsp').exists(), 'half a copy was left as the update')

    def test_a_link_that_fails_falls_back_to_a_copy_with_its_date(self):
        from unittest import mock
        base = make(self.root / 'a' / 'base.nsp', 100)
        upd = make(self.root / 'b' / 'update.nsp', 9000)
        d = input_staging.folder(self.work)
        with mock.patch.object(input_staging.os, 'link', side_effect=OSError('FAT32 has no hard links')) as link:
            self.assertEqual(input_staging.sync([base, upd], d, hard_links=True), 2)
        self.assertEqual(link.call_count, 2, 'a hard link is tried first')
        self.assertEqual(seen(d), [('base.nsp', 4096, os.stat(base).st_mtime_ns),
                                   ('update.nsp', 4096, os.stat(upd).st_mtime_ns)])

    def test_a_drive_that_keeps_no_dates_still_stages(self):
        from unittest import mock
        base = make(self.root / 'a' / 'base.nsp', 100)
        d = input_staging.folder(self.work)
        with mock.patch.object(input_staging.shutil, 'copystat', side_effect=PermissionError(1, 'not permitted')):
            self.assertEqual(input_staging.sync([base], d, hard_links=False), 1)
        self.assertEqual((Path(d) / 'base.nsp').read_bytes(), b'x' * 4096)

    def test_a_stale_file_that_cannot_be_removed_stops_the_staging(self):
        from unittest import mock
        old_upd = make(self.root / 'b' / 'update [v65536].nsp', 100)
        base = make(self.root / 'a' / 'base.nsp', 100)
        d = input_staging.folder(self.work)
        input_staging.sync([base, old_upd], d)
        real_unlink = Path.unlink

        def in_use(self, *a, **k):
            if self.name == 'update [v65536].nsp':
                raise PermissionError(13, 'The file is in use by another process')
            return real_unlink(self, *a, **k)
        with mock.patch.object(Path, 'unlink', in_use):
            with self.assertRaises(input_staging.StagingError) as cm:
                input_staging.sync([base], d)
        self.assertEqual(Path(cm.exception.path).name, 'update [v65536].nsp')
        self.assertIn('in use', cm.exception.reason)


if __name__ == '__main__':
    unittest.main()
