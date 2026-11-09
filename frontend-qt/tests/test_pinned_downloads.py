"""Every tool the Windows launcher downloads has a pinned hash, and nothing is downloaded and run without one; no member
of an archive it unpacks is written outside the folder it is unpacked into. No network, no PySide6, nothing outside a
temporary folder.

    python3 -m unittest frontend-qt/tests/test_pinned_downloads.py -v
"""
from __future__ import annotations

import shutil
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
    yield 'iPhoneOS SDK', tc.SDK_ASSET
    yield 'Python', tc.PYTHON_ASSET
    yield 'zstd', tc.ZSTD_ASSET
    yield '.NET SDK', tc.DOTNET_ASSET


class PinnedDownloads(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def test_every_asset_has_a_full_hash_for_its_algorithm(self) -> None:
        for what, a in assets():
            with self.subTest(what):
                digits = {'sha256': 64, 'sha512': 128}[a.get('algo', 'sha256')]
                self.assertRegex(a['sha256'], rf'^[0-9a-f]{{{digits}}}$')

    def test_an_unpinned_git_is_refused_not_run(self) -> None:
        unpinned = {'AMD64': dict(tc.GIT_ASSETS['AMD64'], sha256='')}
        with mock.patch.object(tc, 'GIT_ASSETS', unpinned), \
                mock.patch.object(tc, 'tools_dir', return_value=self.tmp / 'tools'), \
                mock.patch.object(wf.urllib.request, 'urlopen', side_effect=AssertionError('downloaded')), \
                mock.patch.object(wf, 'download', side_effect=AssertionError('downloaded')), \
                mock.patch.object(wf.subprocess, 'run', side_effect=AssertionError('ran')):
            with self.assertRaisesRegex(wf.DownloadError, 'no pinned SHA-256'):
                wf.install_git(dest=self.tmp / 'git')
        self.assertFalse(hasattr(wf, '_download_unverified'))
        self.assertFalse((self.tmp / 'git').exists())


def crafted_zip(folder: Path, members: dict[str, bytes], name: str = 'crafted.zip') -> Path:
    """A zip whose member names are written as given, `..`, drive letters and `:` included (zipfile keeps them)."""
    path = folder / name
    with zipfile.ZipFile(path, 'w') as z:
        for member, data in members.items():
            z.writestr(zipfile.ZipInfo(member), data)
    return path


class ArchiveMembersStayInside(unittest.TestCase):
    """A member of a downloaded or picked archive can never be written outside the folder it is unpacked into. Each
    unpacker stops on such a member and keeps nothing of the archive."""

    REFUSED = ('../x', '../../x', 'a/../../x', 'a\\..\\..\\x', '/abs/x', '\\abs\\x', 'C:/x', 'C:\\x', 'c:x', '..',
               '.', '', './a/./b', 'a/./b',
               # NTFS alternate data streams, and any other ':' (sdk_fetch's rule, now everyone's)
               'a/b:stream', 'bin/clang.exe:Zone.Identifier', 'x:y',
               # a NUL ends the name for the C runtime (zipfile itself cuts a name there, so only the rule sees it)
               'a\x00b', 'bin/\x00',
               # Windows drops trailing dots and spaces: these could read as `.` or `..` there
               'a/.. /x', 'a/. /b', '...', 'a/ /b')

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def test_a_name_that_leaves_the_folder_is_refused(self) -> None:
        staging = self.tmp / 'staging'
        staging.mkdir()
        for name in self.REFUSED:
            with self.subTest(name), self.assertRaisesRegex(wf.DownloadError, 'unsafe path inside the archive'):
                wf.member_target(staging, name)

    def test_an_ordinary_name_lands_inside(self) -> None:
        staging = self.tmp / 'staging'
        staging.mkdir()
        root = staging.resolve()
        for name, rel in (('bin/clang.exe', 'bin/clang.exe'), ('host\\fxr\\a.dll', 'host/fxr/a.dll'),
                          ('a//b', 'a/b'), ('dotnet.exe', 'dotnet.exe'), ('bin/', 'bin'),
                          ('a.b/c..d/.hidden', 'a.b/c..d/.hidden')):
            with self.subTest(name):
                self.assertEqual(wf.member_target(staging, name), root / rel)

    def test_a_link_inside_the_folder_that_points_out_is_refused(self) -> None:
        staging = self.tmp / 'staging'
        staging.mkdir()
        try:
            (staging / 'out').symlink_to(self.tmp, target_is_directory=True)
        except (OSError, NotImplementedError):
            self.skipTest('this system cannot make a symbolic link here')
        with self.assertRaisesRegex(wf.DownloadError, 'unsafe path'):
            wf.member_target(staging, 'out/escaped.txt')

    def test_sdk_fetch_uses_the_same_rule(self) -> None:
        from nspb_qt.win import sdk_fetch
        self.assertIs(sdk_fetch._clean_archive_relpath, wf.archive_member_name)
        for name in self.REFUSED:
            with self.subTest(name):
                self.assertIsNone(sdk_fetch._clean_archive_relpath(name))
        self.assertEqual(sdk_fetch._clean_archive_relpath('iPhoneOS27.2.sdk\\usr//lib/'), 'iPhoneOS27.2.sdk/usr/lib')
        z = crafted_zip(self.tmp, {'iPhoneOS27.2.sdk/SDKSettings.json': b'{}',
                                   'iPhoneOS27.2.sdk/usr/lib/a.tbd:stream': b'x'})
        with self.assertRaisesRegex(sdk_fetch.SdkError, 'unsafe paths'):
            sdk_fetch.install_sdk_from_zip(z, dest=self.tmp / 'sdk', log=lambda s: None)
        self.assertFalse(any((self.tmp / 'sdk').rglob('*.tbd*')))

    def test_llvm_stops_on_an_escaping_member_and_keeps_nothing(self) -> None:
        # the top folder is the bad part here: it would be dropped, so only a check of the whole name sees it
        for bad in ('../escaped.txt', 'llvm/../../escaped.txt', 'llvm/bin/clang.exe:stream'):
            with self.subTest(bad):
                z = crafted_zip(self.tmp, {'llvm/bin/clang.exe': b'MZ', bad: b'x'})
                dest = self.tmp / 'tools'
                with mock.patch.object(wf, 'download', return_value=z), \
                        self.assertRaisesRegex(wf.DownloadError, 'unsafe path'):
                    wf.install_llvm(dest=dest)
                self.assertFalse((self.tmp / 'escaped.txt').exists())
                self.assertFalse((dest / f'.unpack-{tc.LLVM_MINGW_VERSION}').exists(), 'the partial unpack is left')
                self.assertFalse((dest / f'llvm-mingw-{tc.LLVM_MINGW_VERSION}').exists())

    def test_zstd_stops_on_an_escaping_member_and_keeps_nothing(self) -> None:
        z = crafted_zip(self.tmp, {'zstd-v1/zstd.exe': b'MZ', 'zstd-v1/../../escaped.txt': b'x'})
        dest = self.tmp / 'tools'
        with mock.patch.object(wf, 'download', return_value=z), \
                self.assertRaisesRegex(wf.DownloadError, 'unsafe path'):
            wf.install_zstd(dest=dest)
        self.assertFalse((self.tmp / 'escaped.txt').exists())
        self.assertFalse((dest / 'escaped.txt').exists())
        self.assertFalse((dest / '.unpack-zstd').exists(), 'the partial unpack is left behind')
        self.assertFalse((dest / f'zstd-{tc.ZSTD_VERSION}').exists())

    def test_dotnet_stops_on_an_escaping_member_instead_of_skipping_it(self) -> None:
        for bad in ('../escaped.txt', f'../.unpack-dotnet-{tc.DOTNET_VERSION}x/escaped.txt',
                    'dotnet.exe:Zone.Identifier'):
            with self.subTest(bad):
                z = crafted_zip(self.tmp, {'dotnet.exe': b'MZ', bad: b'x'})
                dest = self.tmp / 'tools'
                with mock.patch.object(wf, 'download', return_value=z), \
                        self.assertRaisesRegex(wf.DownloadError, 'unsafe path'):
                    wf.install_dotnet(dest=dest)
                self.assertFalse((self.tmp / 'escaped.txt').exists())
                self.assertFalse((dest / f'.unpack-dotnet-{tc.DOTNET_VERSION}x').exists(), 'a sibling was written')
                self.assertFalse((dest / f'.unpack-dotnet-{tc.DOTNET_VERSION}').exists(), 'the partial unpack is left')
                self.assertFalse((dest / f'dotnet-{tc.DOTNET_VERSION}').exists())

    def test_metal_zip_with_an_escaping_member_is_refused(self) -> None:
        for bad in ('../escaped.txt', 'bin\\..\\..\\escaped.txt', 'C:escaped.txt'):
            with self.subTest(bad):
                z = crafted_zip(self.tmp, {'bin/metal.exe': b'MZ', bad: b'x'})
                dest = self.tmp / 'tools' / 'metal-developer-tools'
                with self.assertRaisesRegex(wf.DownloadError, 'unsafe path'):
                    wf.install_metal_from_zip(z, dest=dest)
                self.assertFalse((self.tmp / 'tools' / 'escaped.txt').exists())
                self.assertFalse((self.tmp / 'tools' / 'metal-developer-tools-staging').exists())
                self.assertFalse(dest.exists())

    def test_a_clean_zstd_zip_still_installs(self) -> None:
        z = crafted_zip(self.tmp, {'zstd-v1/zstd.exe': b'MZ', 'zstd-v1/README.md': b'r'})
        dest = self.tmp / 'tools'
        with mock.patch.object(wf, 'download', return_value=z):
            exe = wf.install_zstd(dest=dest)
        self.assertEqual(exe.read_bytes(), b'MZ')
        self.assertFalse((dest / '.unpack-zstd').exists())


if __name__ == '__main__':
    unittest.main()
