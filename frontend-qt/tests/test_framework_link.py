"""The Windows link of the app and of a game's framework (win/build_app.py link, link_framework): a long command line
goes through the response file, and the framework's source list follows the engine's project-framework.yml. No
compiler and no SDK: the commands are checked, not run."""
from __future__ import annotations

import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
QT = HERE.parent
ROOT = QT.parent
ENGINE = ROOT / 'engine'
sys.path.insert(0, str(QT))

from nspb_qt.win import build_app  # noqa: E402

class LinksGoThroughTheResponseFile(unittest.TestCase):
    """Both links (the app's and a game framework's) name the engine's 267 objects by their full paths: under a long work
    folder that passes Windows' 32,767-character limit (WinError 206, a Snipperclips build, upstream #870). Upstream's
    response_file_args (test_link_response_file.py) moves them into an @file; this checks that each link uses it."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        folder = Path(tmp.name, 'Local-Switch', 'Switch Games', '3rd Party', 'Snipperclips - Cut it out, together',
                      '0100704000B3A000_build', 'build', 'ios', 'win', 'obj_fw')
        folder.mkdir(parents=True)
        self.objs = [folder / f'module_{i:03}_with_a_long_name-0123456789abcdef.o' for i in range(267)]
        self.assertGreater(len(subprocess.list2cmdline([str(o) for o in self.objs])), 32767)   # the case it fixes
        self.seen: dict = {}

    def run_linker(self, args, **kw):
        self.seen['args'] = list(args)
        rsp = Path(args[-1][1:])
        self.seen['rsp'] = rsp.read_text(encoding='utf-8').splitlines()
        return mock.Mock(returncode=0, stdout='', stderr='')

    def check(self):
        args = self.seen['args']
        self.assertEqual(len(args), 2)
        self.assertTrue(args[1].startswith('@'))
        self.assertLess(len(subprocess.list2cmdline(args)), 32767)
        listed = set(self.seen['rsp'])
        for o in self.objs:
            self.assertIn(f'"{o.as_posix()}"', listed)

    def test_the_app_link(self):
        with mock.patch.object(build_app.subprocess, 'run', side_effect=self.run_linker), \
                mock.patch.object(build_app, 'check_executable'), \
                mock.patch.object(build_app.macho_sign, 'sign', return_value=0):
            build_app.link(Path('clang'), Path('sdk'), self.objs, ['UIKit'], Path('out/DmIOS'), '26.0', [], None,
                           Path('lld'))
        self.check()

    def test_the_framework_link(self):
        with mock.patch.object(build_app.subprocess, 'run', side_effect=self.run_linker), \
                mock.patch.object(build_app, 'check_dylib'), \
                mock.patch.object(build_app.macho_sign, 'sign', return_value=0):
            build_app.link_framework(Path('clang'), Path('sdk'), self.objs, ['UIKit'], Path('out/DmGameX'), 'DmGameX',
                                     '26.0', [], None, Path('lld'))
        self.check()
        self.assertIn('"-dynamiclib"', self.seen['rsp'])


@unittest.skipUnless((ENGINE / 'dm' / 'ios' / 'project-framework.yml').is_file(),
                     'no engine/: run python3 tools/engine.py sync')
class FrameworkSources(unittest.TestCase):
    """build_app.py compiles a game's framework from its own list of sources (Windows has no xcodegen). The engine's
    project-framework.yml is the truth: a source added there and not here would leave the framework without it."""

    #: Swift sources of the framework that Windows cannot compile, and what stands in for each.
    SWIFT_STAND_INS = {'Sources/GameMenu.swift': 'Launcher.m (dm_game_menu)',
                       'Sources/LauncherSettings.swift': 'Launcher.m'}

    def yml_sources(self) -> list[str]:
        text = (ENGINE / 'dm' / 'ios' / 'project-framework.yml').read_text(encoding='utf-8')
        target = text[text.index('DmShellGame:'):]
        block = target[target.index('    sources:'):]
        block = block[:re.search(r'\n    [a-zA-Z]', block[len('    sources:'):]).start() + len('    sources:')]
        return re.findall(r'- path: (\S+)', block)

    def test_every_source_of_the_framework_target_is_compiled_or_stood_in_for(self):
        listed = set(re.findall(r"repo / 'dm/ios/([^']+\.m)'", (QT / 'nspb_qt' / 'win' / 'build_app.py').read_text(
            encoding='utf-8')))
        sources = [p for p in self.yml_sources() if not p.startswith('Gen/')]
        self.assertTrue(sources)
        for path in sources:
            with self.subTest(path):
                if path.endswith('.m'):
                    self.assertIn(path, listed, f'{path} is in project-framework.yml but not compiled on Windows')
                else:
                    self.assertIn(path, self.SWIFT_STAND_INS, f'{path}: a new source Windows does not build')


if __name__ == '__main__':
    unittest.main()
