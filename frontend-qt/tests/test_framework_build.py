"""The shared app's game framework on Windows (win/build_app.py DM_FRAMEWORK_ONLY): the source list read from
project-framework.yml, the dylib link, the Launcher.m guard and the framework folder with its manifest, made from a
real profile of the engine (engine/, `python3 tools/engine.py sync`). No compiler and no SDK: the compile and the
link are what test_win.py covers for the one-game app."""
from __future__ import annotations

import json
import os
import plistlib
import shutil
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

HAS_ENGINE = (ENGINE / 'dm' / 'ios' / 'project-framework.yml').is_file()


@unittest.skipUnless(HAS_ENGINE, 'no engine/: run python3 tools/engine.py sync')
class FrameworkSources(unittest.TestCase):
    def test_the_list_is_the_shell_games_objc_sources(self):
        names = {p.name for p in build_app.framework_sources(ENGINE)}
        self.assertIn('ShellGlue.m', names)        # stands in for main.m and Launcher.swift
        self.assertIn('DmGameMarker.m', names)     # the image marker the shell finds with dlsym
        self.assertIn('front_ios.m', names)
        self.assertNotIn('main.m', names)          # the app's entry point, not the framework's
        self.assertNotIn('FrameworkBootstrap.m', names)
        for p in build_app.framework_sources(ENGINE):
            self.assertTrue(p.is_file(), p)

    def test_an_unknown_source_stops_the_build(self):
        tmp = Path(tempfile.mkdtemp())
        ios = tmp / 'dm' / 'ios'
        shutil.copytree(ENGINE / 'dm' / 'ios', ios)
        yml = ios / 'project-framework.yml'
        text = yml.read_text(encoding='utf-8')
        text = text.replace('      - path: framework/ShellGlue.m\n',
                            '      - path: framework/ShellGlue.m\n      - path: Sources/NewThing.swift\n', 1)
        yml.write_text(text, encoding='utf-8')
        with self.assertRaises(SystemExit):
            build_app.framework_sources(tmp)


@unittest.skipUnless(HAS_ENGINE, 'no engine/: run python3 tools/engine.py sync')
class ProfileFoldersOnWindows(unittest.TestCase):
    """The NSP script puts a derived profile's folder in DM_GAMES_DIR joined with os.pathsep (';' on Windows), and game.py
    must split it the same way: ':' cut "D:\\Games\\<id>_build\\profile" at the drive letter, every tool took the registered
    profile, and the build stopped with KeyError: 'v1376256' (patches/0084)."""

    def test_a_windows_list_keeps_its_drive_letters(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location('engine_game_py', ENGINE / 'dm' / 'games' / 'game.py')
        game = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(game)
        with mock.patch.object(game.os, 'pathsep', ';'), \
                mock.patch.dict(os.environ, {'DM_GAMES_DIR': r'D:\Games\0100152000022000_build\profile;E:\more'}):
            self.assertEqual([str(p) for p in game.extra_dirs()],
                             [str(Path(r'D:\Games\0100152000022000_build\profile')), str(Path(r'E:\more'))])


class LauncherGuard(unittest.TestCase):
    def test_the_framework_keeps_the_menu_and_leaves_the_launcher_out(self):
        src = (QT / 'nspb_qt' / 'win' / 'ios' / 'Launcher.m').read_text(encoding='utf-8')
        guard = src.index('#ifndef NSPB_SHELL_FRAMEWORK')
        self.assertLess(src.index('void *dm_game_menu(void)'), guard)
        self.assertGreater(src.index('bool dm_show_launcher('), guard)
        self.assertTrue(src.rstrip().endswith('#endif  // NSPB_SHELL_FRAMEWORK'))


class DylibLink(unittest.TestCase):
    def test_a_framework_links_as_a_dylib_without_entitlements(self):
        seen = {}

        def run(args, **kw):
            seen['args'] = args
            return mock.Mock(returncode=0, stdout='', stderr='')
        with mock.patch.object(build_app.subprocess, 'run', side_effect=run), \
                mock.patch.object(build_app, 'check_executable') as check, \
                mock.patch.object(build_app.macho_sign, 'sign') as sign:
            build_app.link(Path('clang'), Path('sdk'), [Path('a.o')], ['UIKit'], Path('out/DmGameX'), '26.0',
                           ['-Wl,-x'], None, None, dylib_install_name='@rpath/DmGameX.framework/DmGameX')
        args = seen['args']
        self.assertIn('-dynamiclib', args)
        self.assertIn('-Wl,-install_name,@rpath/DmGameX.framework/DmGameX', args)
        self.assertIn('-Wl,-adhoc_codesign', args)
        self.assertNotIn('-Wl,-rpath,@executable_path/Frameworks', args)
        self.assertEqual(check.call_args[0][1], build_app.MH_DYLIB)
        sign.assert_not_called()

    def test_the_objects_go_in_a_file_list_not_the_command_line(self):
        # 267 objects under a long build folder passed Windows' 32,767-character limit (WinError 206)
        folder = 'D:\\Local-Switch\\Switch Games\\3rd Party\\Snipperclips\\0100704000B3A000_build\\obj\\dm\\host'
        objs = [Path(f'{folder}\\module_{i:03}_with_a_long_name.o') for i in range(267)]
        seen = {}

        def run(args, **kw):
            seen['args'] = args
            fl = args[args.index('-filelist') + 2]
            seen['list'] = Path(fl).read_text(encoding='utf-8')
            seen['path'] = fl
            return mock.Mock(returncode=0, stdout='', stderr='')
        with mock.patch.object(build_app.subprocess, 'run', side_effect=run), \
                mock.patch.object(build_app, 'check_executable'), \
                mock.patch.object(build_app.macho_sign, 'sign', return_value=0):
            build_app.link(Path('clang'), Path('sdk'), objs, ['UIKit'], Path('out/DmIOS'), '26.0', [], None, None)
        args = seen['args']
        self.assertEqual(args[args.index('-filelist') - 1], '-Xlinker')
        self.assertEqual(args[args.index('-filelist') + 1], '-Xlinker')
        self.assertEqual(seen['list'].splitlines(), [str(o) for o in objs])
        self.assertFalse(any(str(o) in args for o in objs))
        self.assertLess(len(subprocess.list2cmdline(args)), 2000)
        self.assertFalse(Path(seen['path']).exists())       # removed after the link

    def test_info_plist_is_a_framework(self):
        p = build_app.framework_info_plist(executable='DmGameX', bundle_id='org.nxnative.x.game', name='X',
                                           version='1.0.0', sdk_ver='26.0', sdk_build='23A', deployment='26.0')
        self.assertEqual(p['CFBundlePackageType'], 'FMWK')
        self.assertEqual(p['CFBundleExecutable'], 'DmGameX')
        plistlib.dumps(p, fmt=plistlib.FMT_BINARY)


@unittest.skipUnless(HAS_ENGINE, 'no engine/: run python3 tools/engine.py sync')
class FinishFramework(unittest.TestCase):
    """The step after the link: profile, manifest, Info.plist, shader libraries, then the folder in place."""

    GAME = '0100000000010000'

    def setUp(self):
        if not (ENGINE / 'dm' / 'games' / self.GAME / 'game.tsv').is_file():
            self.skipTest(f'no profile {self.GAME} in this engine')
        self.tmp = Path(tempfile.mkdtemp())

    def test_the_folder_has_what_the_shell_reads(self):
        app = self.tmp / 'stage' / f'DmGame{self.GAME}.framework'
        (app / 'dm').mkdir(parents=True)
        (app / f'DmGame{self.GAME}').write_bytes(b'\xcf\xfa\xed\xfe')
        msl = self.tmp / 'msl'
        (msl / 'b-1').mkdir(parents=True)
        (msl / 'b-1' / 'x_b.metallib').write_bytes(b'lib')
        romfs = self.tmp / 'v0' / 'RomFS'
        romfs.mkdir(parents=True)
        out = self.tmp / 'shell-framework'
        old = os.environ.get('DM_COPY_ROMFS')
        os.environ['DM_COPY_ROMFS'] = 'NO'
        try:
            rc = build_app.finish_framework(
                repo=ENGINE, env=dict(os.environ), app=app, fw_only=out, fw_name=f'DmGame{self.GAME}',
                game=self.GAME, name='Test Game', version='1.0.0', pkg='', mods=['main'], patched=self.tmp,
                romfs=romfs, marker='x', msl_ios=msl, msldir='b-1', chain='1', bundle_id='org.nxnative.test',
                sdk_ver='26.0', sdk_build='23A', deployment='26.0')
        finally:
            if old is None:
                os.environ.pop('DM_COPY_ROMFS', None)
            else:
                os.environ['DM_COPY_ROMFS'] = old
        self.assertEqual(rc, 0)
        fw = out / f'DmGame{self.GAME}.framework'
        m = json.loads((fw / 'game.manifest.json').read_text(encoding='utf-8'))
        self.assertEqual(m['loader'], 'FH')                       # its own host: the shell skips the chain check
        self.assertEqual(m['framework_executable'], f'DmGame{self.GAME}')
        self.assertEqual(m['title_id'], self.GAME)
        self.assertTrue((fw / 'profile.tsv').is_file())
        self.assertEqual((fw / 'msl' / 'b-1' / 'x_b.metallib').read_bytes(), b'lib')
        with open(fw / 'Info.plist', 'rb') as f:
            self.assertEqual(plistlib.load(f)['CFBundleIdentifier'], 'org.nxnative.test.game')
        self.assertFalse(any(p.name.startswith('.') for p in out.iterdir()))   # no half copy left

    def test_a_stop_on_the_way_leaves_no_hidden_copy(self):
        app = self.tmp / 'stage' / f'DmGame{self.GAME}.framework'
        (app / 'dm').mkdir(parents=True)
        (app / f'DmGame{self.GAME}').write_bytes(b'\xcf\xfa\xed\xfe' + bytes(1 << 20))
        romfs = self.tmp / 'v0' / 'RomFS'
        romfs.mkdir(parents=True)
        out = self.tmp / 'shell-framework'
        with mock.patch.dict(os.environ, {'DM_COPY_ROMFS': 'NO'}), self.assertRaises(SystemExit):
            build_app.finish_framework(
                repo=ENGINE, env=dict(os.environ), app=app, fw_only=out, fw_name=f'DmGame{self.GAME}',
                game=self.GAME, name='Test Game', version='1.0.0', pkg='', mods=['main'], patched=self.tmp,
                romfs=romfs, marker='x', msl_ios=self.tmp / 'no-shaders', msldir='b-1', chain='1',
                bundle_id='org.nxnative.test', sdk_ver='26.0', sdk_build='23A', deployment='26.0')
        self.assertEqual([p.name for p in out.iterdir()], [], 'a stopped framework build left its copy behind')


if __name__ == '__main__':
    unittest.main()
