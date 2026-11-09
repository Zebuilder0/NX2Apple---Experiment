"""Every tool the Windows launcher downloads has a pinned hash, and nothing is downloaded and run without one. No
network, no PySide6.

    python3 -m unittest frontend-qt/tests/test_pinned_downloads.py -v
"""
from __future__ import annotations

import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'frontend-qt'))

from nspb_qt.win import fetch as wf   # noqa: E402
from nspb_qt.win import toolchain as tc   # noqa: E402


def assets():
    yield from (('LLVM-MinGW ' + k, a) for k, a in tc.LLVM_MINGW_ASSETS.items())
    yield from (('PortableGit ' + k, a) for k, a in tc.GIT_ASSETS.items())
    yield 'Python', tc.PYTHON_ASSET
    yield 'zstd', tc.ZSTD_ASSET
    yield '.NET SDK', tc.DOTNET_ASSET


class PinnedDownloads(unittest.TestCase):
    def test_every_asset_has_a_full_hash_for_its_algorithm(self):
        for what, a in assets():
            with self.subTest(what):
                digits = {'sha256': 64, 'sha512': 128}[a.get('algo', 'sha256')]
                self.assertRegex(a['sha256'], rf'^[0-9a-f]{{{digits}}}$')

    def test_an_unpinned_git_is_refused_not_run(self):
        unpinned = {'AMD64': dict(tc.GIT_ASSETS['AMD64'], sha256='')}
        with mock.patch.object(tc, 'GIT_ASSETS', unpinned), \
                mock.patch.object(wf.urllib.request, 'urlopen', side_effect=AssertionError('downloaded')), \
                mock.patch.object(wf.subprocess, 'run', side_effect=AssertionError('ran')):
            with self.assertRaisesRegex(wf.DownloadError, 'no pinned SHA-256'):
                wf.install_git(dest=Path(tempfile.mkdtemp()) / 'git')
        self.assertFalse(hasattr(wf, '_download_unverified'))


def crafted_zip(folder: Path, members: dict[str, bytes]) -> Path:
    """A zip whose member names are written as given, `..` and drive letters included (zipfile keeps them)."""
    path = folder / 'crafted.zip'
    with zipfile.ZipFile(path, 'w') as z:
        for name, data in members.items():
            z.writestr(zipfile.ZipInfo(name), data)
    return path


class ArchiveMembersStayInside(unittest.TestCase):
    """A member of a downloaded or picked archive can never be written outside the folder it is unpacked into. Each
    unpacker stops on such a member and keeps nothing of the archive."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(__import__('shutil').rmtree, self.tmp, True)

    def test_a_name_that_leaves_the_folder_is_refused(self):
        staging = self.tmp / 'staging'
        staging.mkdir()
        for name in ('../x', '../../x', 'a/../../x', 'a\\..\\..\\x', '/abs/x', '\\abs\\x', 'C:/x', 'C:\\x',
                     'c:x', '..', '.', ''):
            with self.subTest(name), self.assertRaisesRegex(wf.DownloadError, 'unsafe path'):
                wf.member_target(staging, name)

    def test_an_ordinary_name_lands_inside(self):
        staging = self.tmp / 'staging'
        staging.mkdir()
        root = staging.resolve()
        for name, rel in (('bin/clang.exe', 'bin/clang.exe'), ('host\\fxr\\a.dll', 'host/fxr/a.dll'),
                          ('./a/./b', 'a/b'), ('a//b', 'a/b'), ('dotnet.exe', 'dotnet.exe')):
            with self.subTest(name):
                self.assertEqual(wf.member_target(staging, name), root / rel)

    def test_zstd_stops_on_an_escaping_member_and_keeps_nothing(self):
        z = crafted_zip(self.tmp, {'zstd-v1/zstd.exe': b'MZ', 'zstd-v1/../../escaped.txt': b'x'})
        dest = self.tmp / 'tools'
        with mock.patch.object(wf, 'download', return_value=z), \
                self.assertRaisesRegex(wf.DownloadError, 'unsafe path'):
            wf.install_zstd(dest=dest)
        self.assertFalse((self.tmp / 'escaped.txt').exists())
        self.assertFalse((dest / 'escaped.txt').exists())
        self.assertFalse((dest / '.unpack-zstd').exists(), 'the partial unpack is left behind')
        self.assertFalse((dest / f'zstd-{tc.ZSTD_VERSION}').exists())

    def test_dotnet_stops_on_an_escaping_member_instead_of_skipping_it(self):
        z = crafted_zip(self.tmp, {'dotnet.exe': b'MZ', '../escaped.txt': b'x'})
        dest = self.tmp / 'tools'
        with mock.patch.object(wf, 'download', return_value=z), \
                self.assertRaisesRegex(wf.DownloadError, 'unsafe path'):
            wf.install_dotnet(dest=dest)
        self.assertFalse((self.tmp / 'escaped.txt').exists())
        self.assertFalse((dest / f'.unpack-dotnet-{tc.DOTNET_VERSION}').exists(), 'the partial unpack is left behind')
        self.assertFalse((dest / f'dotnet-{tc.DOTNET_VERSION}').exists())

    def test_metal_zip_with_an_escaping_member_is_refused(self):
        z = crafted_zip(self.tmp, {'bin/metal.exe': b'MZ', '../escaped.txt': b'x'})
        dest = self.tmp / 'tools' / 'metal-developer-tools'
        with self.assertRaisesRegex(wf.DownloadError, 'unsafe path'):
            wf.install_metal_from_zip(z, dest=dest)
        self.assertFalse((self.tmp / 'tools' / 'escaped.txt').exists())
        self.assertFalse((self.tmp / 'tools' / 'metal-developer-tools-staging').exists())
        self.assertFalse(dest.exists())

    def test_a_clean_zstd_zip_still_installs(self):
        z = crafted_zip(self.tmp, {'zstd-v1/zstd.exe': b'MZ', 'zstd-v1/README.md': b'r'})
        dest = self.tmp / 'tools'
        with mock.patch.object(wf, 'download', return_value=z):
            exe = wf.install_zstd(dest=dest)
        self.assertEqual(exe.read_bytes(), b'MZ')
        self.assertFalse((dest / '.unpack-zstd').exists())


if __name__ == '__main__':
    unittest.main()
