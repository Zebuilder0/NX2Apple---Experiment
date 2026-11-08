"""Every tool the Windows launcher downloads has a pinned hash, and nothing is downloaded and run without one. No
network, no PySide6.

    python3 -m unittest frontend-qt/tests/test_pinned_downloads.py -v
"""
from __future__ import annotations

import re
import sys
import tempfile
import unittest
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


if __name__ == '__main__':
    unittest.main()
