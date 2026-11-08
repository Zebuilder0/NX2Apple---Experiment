"""The Windows install on an iPhone or iPad: the USB client (win/device.py), the shared app (shell.py), the
signing tool's wrapper (win/signer.py) and the install that joins them (win/install.py), against a pretend
device (fake_device.py) and a pretend plumesign. No PySide6, no device, no network."""
from __future__ import annotations

import json
import os
import plistlib
import stat
import sys
import tempfile
import time
import unittest
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))

from fake_device import FakeDevice, make_cert   # noqa: E402
from nspb_qt import shell   # noqa: E402
from nspb_qt.win import device as dv   # noqa: E402
from nspb_qt.win import install as wi   # noqa: E402
from nspb_qt.win import signer   # noqa: E402

SHELL_ID = 'org.nxnative.shell.ABCDE12345'


def make_template(folder: Path) -> Path:
    app = folder / 'DmShell.app'
    app.mkdir(parents=True)
    (app / 'DmShell').write_bytes(b'\xcf\xfa\xed\xfe' + bytes(60))
    with open(app / 'Info.plist', 'wb') as f:
        plistlib.dump({'CFBundleExecutable': 'DmShell', 'CFBundleIdentifier': 'org.nxnative.shell',
                       'CFBundleShortVersionString': '1.2.3'}, f)
    return app


def make_framework(folder: Path, tid: str, name='Game') -> Path:
    fw = folder / f'DmGame{tid}.framework'
    fw.mkdir(parents=True)
    (fw / f'DmGame{tid}').write_bytes(b'\xcf\xfa\xed\xfe' + bytes(28))
    (fw / 'game.manifest.json').write_text(json.dumps({'title_id': tid, 'name': name,
                                                        'framework_executable': f'DmGame{tid}'}))
    return fw


class DeviceTestCase(unittest.TestCase):
    tls = None

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.dev = FakeDevice(tls=self.tls)
        self.old = os.environ.get('NSPB_USBMUXD')
        os.environ['NSPB_USBMUXD'] = self.dev.address

    def tearDown(self):
        self.dev.close()
        if self.old is None:
            os.environ.pop('NSPB_USBMUXD', None)
        else:
            os.environ['NSPB_USBMUXD'] = self.old


class UsbClient(DeviceTestCase):
    def test_lists_names_and_finds_the_shared_app(self):
        self.assertTrue(dv.service_running())
        devs = dv.list_devices()
        self.assertEqual([d.udid for d in devs], [self.dev.udid])
        self.assertTrue(devs[0].wired)
        self.assertEqual(dv.describe(devs[0]).name, 'Test iPhone')
        self.dev.apps = {'com.other': {'CFBundleIdentifier': 'com.other', 'CFBundleExecutable': 'Other'},
                         SHELL_ID: {'CFBundleIdentifier': SHELL_ID, 'CFBundleExecutable': 'DmShell'}}
        self.assertEqual(dv.find_shell(devs[0]), SHELL_ID)
        self.assertEqual(dv.find_shell(devs[0], preferred='gone'), SHELL_ID)

    def test_copies_game_data_once_and_again_when_forced(self):
        self.dev.apps = {SHELL_ID: {'CFBundleIdentifier': SHELL_ID, 'CFBundleExecutable': 'DmShell'}}
        data = self.tmp / 'romfs'
        (data / 'aoc' / '001').mkdir(parents=True)
        (data / 'romfs.img').write_bytes(os.urandom(9 << 20))   # more than one 4 MB write
        (data / 'aoc' / '001' / 'romfs.img').write_bytes(b'dlc')
        d = dv.list_devices()[0]
        seen = []
        n, size = dv.copy_game_data(d, SHELL_ID, '0100abcd00000000', data, progress=lambda a, b: seen.append((a, b)))
        self.assertEqual(n, 2)
        base = '/Documents/games/0100ABCD00000000'
        self.assertEqual(self.dev.files[base + '/romfs.img'], (data / 'romfs.img').read_bytes())
        self.assertEqual(self.dev.files[base + '/aoc/001/romfs.img'], b'dlc')
        self.assertFalse(any(p.endswith('.part') for p in self.dev.files))
        self.assertEqual(seen[-1], (size, size))
        self.assertEqual(dv.copy_game_data(d, SHELL_ID, '0100ABCD00000000', data), (0, 0))
        self.assertEqual(dv.copy_game_data(d, SHELL_ID, '0100ABCD00000000', data, force=['romfs.img'])[0], 1)

    def test_refuses_without_space_or_app_or_pairing(self):
        data = self.tmp / 'romfs'
        data.mkdir()
        (data / 'romfs.img').write_bytes(b'x' * 100)
        d = dv.list_devices()[0]
        with self.assertRaises(dv.AppMissing):
            dv.copy_game_data(d, SHELL_ID, '0100ABCD00000000', data)
        self.dev.apps = {SHELL_ID: {'CFBundleIdentifier': SHELL_ID, 'CFBundleExecutable': 'DmShell'}}
        self.dev.free = 1_000
        with self.assertRaisesRegex(dv.DeviceError, 'not enough space'):
            dv.copy_game_data(d, SHELL_ID, '0100ABCD00000000', data)
        self.dev.locked = True
        with self.assertRaises(dv.Locked):
            dv.copy_game_data(d, SHELL_ID, '0100ABCD00000000', data)
        self.dev.paired = False
        with self.assertRaises(dv.NotPaired):
            dv.copy_game_data(d, SHELL_ID, '0100ABCD00000000', data)

    def test_no_service(self):
        os.environ['NSPB_USBMUXD'] = '127.0.0.1:1'
        self.assertFalse(dv.service_running(timeout=1))
        with self.assertRaisesRegex(dv.DeviceError, 'iTunes'):
            dv.list_devices(timeout=1)

    def test_files_to_copy(self):
        self.assertEqual(dv.files_to_copy({'a': 1, 'b': 2}, {'a': 1, 'b': None}), ['b'])
        self.assertEqual(dv.files_to_copy({'a': 1}, {'a': 1}, force=['a']), ['a'])


class DeveloperMode(DeviceTestCase):
    def test_status_and_reveal(self):
        dev = dv.list_devices()[0]
        self.assertIsNone(dv.developer_mode(dev))            # the device does not say: iOS 15
        self.dev.developer_mode = False
        self.assertIs(dv.developer_mode(dev), False)
        dv.reveal_developer_mode(dev)
        self.assertEqual(self.dev.revealed, 1)
        log = []
        self.assertIs(wi.check_developer_mode(dev, log.append), False)
        self.assertEqual(self.dev.revealed, 2)
        self.assertIn('Privacy & Security', ''.join(log))
        self.dev.developer_mode = True
        self.assertIs(wi.check_developer_mode(dev), True)
        self.assertEqual(self.dev.revealed, 2)


class UsbClientOverTls(UsbClient):
    """The same, with lockdownd asking for TLS after StartSession (every real device does)."""

    @classmethod
    def setUpClass(cls):
        cls._certdir = tempfile.mkdtemp()
        cls.tls = make_cert(Path(cls._certdir))
        if not cls.tls:
            raise unittest.SkipTest('no openssl to make a test certificate')


class SharedApp(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def test_library_round_trip_and_replace(self):
        lib = shell.Library()
        lib.add(shell.Game('0100A', 'A', '/x/a'))
        lib.add(shell.Game('0100a', 'A2', '/x/a2'))
        lib.add(shell.Game('0100B', 'B', '/x/b'))
        lib.save(self.tmp)
        back = shell.Library.load(self.tmp)
        self.assertEqual([(g.titleID, g.name) for g in back.games], [('0100a', 'A2'), ('0100B', 'B')])
        self.assertEqual(json.loads((self.tmp / 'shell.json').read_text())['bundleID'], 'org.nxnative.shell')
        self.assertEqual(shell.Library.load(self.tmp / 'nothing').games, [])

    def test_built_framework_mirror_and_assemble(self):
        work = self.tmp / 'work'
        built = make_framework(work / 'shell-framework', '0100ABCD00000000', 'Zelda')
        self.assertEqual(shell.built_framework(work), built)
        root = self.tmp / 'root'
        game = shell.add_built_game(root, built)
        self.assertEqual((game.titleID, game.name), ('0100ABCD00000000', 'Zelda'))
        self.assertTrue((Path(game.framework) / 'game.manifest.json').is_file())
        self.assertNotEqual(Path(game.framework).parent, built.parent)    # a copy in the cache
        tpl = make_template(self.tmp / 'tpl')
        self.assertEqual(shell.template_problem(tpl), '')
        self.assertEqual(shell.template_version(tpl), '1.2.3')
        app = shell.assemble(root, tpl, shell.Library.load(root).present())
        self.assertTrue((app / 'Frameworks' / built.name / 'game.manifest.json').is_file())
        self.assertFalse((tpl / 'Frameworks').exists())                  # the template stays empty
        app2 = shell.assemble(root, tpl, shell.Library.load(root).present())   # again: a fresh copy
        self.assertEqual(app, app2)
        with self.assertRaises(ValueError):
            shell.assemble(root, tpl, [])

    def test_pending_data_follows_the_receipts_and_skips_an_overwritten_folder(self):
        root = self.tmp / 'root'
        a = shell.Game('0100AAAA00000000', 'A', '/x'); b = shell.Game('0100BBBB00000000', 'B', '/y')
        da, db = self.tmp / 'a', self.tmp / 'b'
        for d, body in ((da, b'a'), (db, b'b')):
            d.mkdir()
            (d / 'romfs.img').write_bytes(body)
        shell.remember_data(root, a.titleID, da)
        shell.remember_data(root, b.titleID, db)
        self.assertEqual(shell.pending_data(root, [a, b], {}), [(a.titleID, da), (b.titleID, db)])
        self.assertEqual(shell.pending_data(root, [a, b], {a.titleID: shell.data_stamp(da)}), [(b.titleID, db)])
        (db / 'romfs.img').write_bytes(b'another game now')   # the shared output folder, packed by a later build
        self.assertEqual(shell.pending_data(root, [a, b], {}), [(a.titleID, da)])
        self.assertEqual(shell.pending_data(self.tmp / 'none', [a], {}), [])

    def test_each_game_gets_its_banner_as_the_mac_puts_it(self):
        root = self.tmp / 'root'
        built = make_framework(self.tmp / 'w' / 'shell-framework', '0100ABCD00000000', 'Zelda')
        shell.add_built_game(root, built)
        make_framework(self.tmp / 'w2' / 'shell-framework', '0100EEEE00000000', 'Other')
        shell.add_built_game(root, self.tmp / 'w2' / 'shell-framework' / 'DmGame0100EEEE00000000.framework')
        art = self.tmp / 'zelda.png'
        art.write_bytes(b'png bytes')
        odd = self.tmp / 'odd.bmp'
        odd.write_bytes(b'bmp')
        pics = {'0100ABCD00000000': str(art), '0100EEEE00000000': None}
        app = shell.assemble(root, make_template(self.tmp / 'tpl'), shell.Library.load(root).present(), pics.get)
        fw = app / 'Frameworks'
        self.assertEqual((fw / 'DmGame0100ABCD00000000.framework' / 'banner.png').read_bytes(), b'png bytes')
        self.assertFalse(any((fw / 'DmGame0100EEEE00000000.framework').glob('banner.*')))   # no picture: the icon shows
        # an old banner goes, and a picture of another kind is named .jpg (ShellInstall.placeBanner)
        target = fw / 'DmGame0100EEEE00000000.framework'
        (target / 'banner.webp').write_bytes(b'old')
        self.assertEqual(shell.place_banner(target, str(odd)), str(odd))
        self.assertEqual(sorted(p.name for p in target.glob('banner.*')), ['banner.jpg'])
        self.assertIsNone(shell.place_banner(target, None))
        self.assertFalse(any(target.glob('banner.*')))

    def test_banner_waits_for_a_download_still_running(self):
        from unittest import mock
        from nspb_qt import device_model as dm

        class Art:
            def __init__(self, ready_after):
                self.calls, self.ready_after, self._fetching = 0, ready_after, set()
            def image_path(self, tid, repo=''):
                self.calls += 1
                return '/art.jpg' if self.ready_after is not None and self.calls > self.ready_after else None
            def request_banner_async(self, tid):
                self._fetching.add(tid.upper())

        owner = type('Owner', (), {'engine_path': ''})()
        with mock.patch.object(dm.time, 'sleep'):
            owner.artwork = Art(ready_after=2)          # cached on the second look after the request
            self.assertEqual(dm.DeviceMixin._banner_for(owner, '0100abcd00000000'), '/art.jpg')
            owner.artwork = Art(ready_after=None)       # a download that ends without a picture
            owner.artwork._fetching = set()
            owner.artwork.request_banner_async = lambda tid: None
            self.assertIsNone(dm.DeviceMixin._banner_for(owner, '0100ABCD00000000'))
            self.assertEqual(owner.artwork.calls, 2)    # it stops at once, not after BANNER_WAIT
            del owner.artwork
            self.assertIsNone(dm.DeviceMixin._banner_for(owner, '0100ABCD00000000'))

    def test_template_problems(self):
        self.assertIn('Info.plist', shell.template_problem(self.tmp))
        tpl = make_template(self.tmp / 't')
        (tpl / 'DmShell').unlink()
        self.assertIn('executable', shell.template_problem(tpl))

    def test_ipa_has_payload_and_unix_modes(self):
        from nspb_qt.device_model import write_ipa
        tpl = make_template(self.tmp / 'tpl')
        make_framework(tpl / 'Frameworks', '0100ABCD00000000')
        ipa = self.tmp / 'out' / 'NX2Apple.ipa'
        write_ipa(tpl, ipa)
        with zipfile.ZipFile(ipa) as z:
            modes = {i.filename: (i.external_attr >> 16) & 0o777 for i in z.infolist()}
        self.assertEqual(modes['Payload/DmShell.app/DmShell'], 0o755)
        self.assertEqual(modes['Payload/DmShell.app/Frameworks/DmGame0100ABCD00000000.framework/DmGame0100ABCD00000000'], 0o755)
        self.assertEqual(modes['Payload/DmShell.app/Info.plist'], 0o644)


class SignerWrapper(unittest.TestCase):
    def test_redact(self):
        text = ('Restoring session for jane.doe@example.com... Registering device: Jane (00008110-001A2B3C4D5E801E) '
                'team ABCDE12345 org.nxnative.shell.ABCDE12345 "xcode_gs_token": "abc.def" udid 0123456789abcdef0123456789abcdef01234567')
        out = signer.redact(text)
        for secret in ('jane.doe@example.com', '00008110-001A2B3C4D5E801E', 'ABCDE12345', 'abc.def',
                       '0123456789abcdef0123456789abcdef01234567'):
            self.assertNotIn(secret, out)
        self.assertIn('<apple id>', out)
        self.assertEqual(signer.redact('Installation progress: 50%'), 'Installation progress: 50%')
        self.assertEqual(signer.redact('title 0100ABCD00000000'), 'title 0100ABCD00000000')   # title IDs stay

    def test_the_sign_in_window_keeps_the_quotes_of_a_path_with_spaces(self):
        exe = r'C:\Users\Jane Doe\Downloads\NX2Apple-windows-x64 (2)\NX2Apple\tools\plumesign.exe'
        line = signer.login_command_line(exe, r'C:\Windows\system32\cmd.exe')
        self.assertNotIn('\\"', line)             # no escaped quote: cmd would take it for part of the name
        self.assertTrue(line.startswith('"C:\\Windows\\system32\\cmd.exe" /d /s /c "'))
        # what cmd /s /c runs: the text after /c without its first and last quote
        after = line.split(' /c ', 1)[1]
        self.assertEqual(after[0] + after[-1], '""')
        self.assertEqual(after[1:-1], f'"{exe}" account login & echo. & pause')

    def test_masked_and_classify_and_command(self):
        self.assertEqual(signer.masked('jane@example.com'), 'j…@example.com')
        self.assertEqual(signer.classify('Error: No account selected. Please login first'), 'win.sign.fail.noAccount')
        self.assertEqual(signer.classify('IO error: not a terminal'), 'win.sign.fail.teams')
        self.assertEqual(signer.classify('something else'), '')
        self.assertEqual(signer.classify('Error: Other error: Device ID 7 not found'), 'win.sign.fail.noDevice')
        self.assertEqual(signer.classify('HTTP status 401 from developerservices2'), 'win.sign.fail.session')
        self.assertEqual(signer.classify('copied 40192 bytes'), '')      # a 401 inside a number is not one
        cmd = signer.sign_command(Path('p'), Path('a.app'), 7)
        self.assertEqual(cmd[1:], ['sign', '--package', 'a.app', '--apple-id', '--udid', '7', '--register-and-install'])
        self.assertEqual(signer.child_env()['RUST_LOG'], 'info')


FAKE_SIGNER = r'''
import json, os, plistlib, sys
args = sys.argv[1:]
if args[:2] == ['account', 'list']:
    print('[2026-11-06T10:00:00Z INFO  plumesign] Saved accounts:', file=sys.stderr)
    print('[2026-11-06T10:00:00Z INFO  plumesign]  [Jane] jane@example.com (selected)', file=sys.stderr)
    sys.exit(0)
if args and args[0] == 'sign':
    app = args[args.index('--package') + 1]
    assert '--register-and-install' in args and '--apple-id' in args
    with open(os.path.join(app, 'Info.plist'), 'rb') as f:
        bid = plistlib.load(f)['CFBundleIdentifier'] + '.ABCDE12345'
    frameworks = sorted(os.listdir(os.path.join(app, 'Frameworks')))
    with open(os.environ['FAKE_SIGNER_OUT'], 'w') as f:
        json.dump({'bundle': bid, 'frameworks': frameworks, 'udid': args[args.index('--udid') + 1]}, f)
    print('Registering device: Test iPhone (00008110-001A2B3C4D5E801E)')
    print('Installation progress: 50%')
    print('Installation complete!')
    sys.exit(0)
sys.exit(2)
'''


@unittest.skipIf(os.name == 'nt', 'the pretend signer is a POSIX script')
class InstallEndToEnd(DeviceTestCase):
    def setUp(self):
        super().setUp()
        script = self.tmp / 'fake_signer.py'
        script.write_text(FAKE_SIGNER)
        self.exe = self.tmp / 'plumesign'
        self.exe.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{script}" "$@"\n')
        self.exe.chmod(self.exe.stat().st_mode | stat.S_IXUSR)
        self.out = self.tmp / 'signed.json'
        os.environ['FAKE_SIGNER_OUT'] = str(self.out)
        self.root = self.tmp / 'root'
        self.tpl = make_template(self.tmp / 'tpl')

    def test_account_from_list(self):
        acct = signer.account(self.exe)
        self.assertTrue(acct.signed_in)
        self.assertEqual(signer.masked(acct.email), 'j…@example.com')

    def test_install_signs_installs_copies_and_remembers(self):
        built = make_framework(self.tmp / 'w' / 'shell-framework', '0100ABCD00000000', 'Zelda')
        game = shell.add_built_game(self.root, built)
        data = self.tmp / 'romfs'
        data.mkdir()
        (data / 'romfs.img').write_bytes(b'R' * 5000)

        def installed_by_signer():
            # the pretend signer "installs": the app appears on the pretend device
            info = json.loads(self.out.read_text())
            self.dev.apps[info['bundle']] = {'CFBundleIdentifier': info['bundle'], 'CFBundleExecutable': 'DmShell'}
            return info

        orig = signer.sign_and_install

        def sign_and_install(*a, **k):
            r = orig(*a, **k)
            installed_by_signer()
            return r
        self.dev.developer_mode = False       # a device that only ever met Windows: no switch in Settings
        signer.sign_and_install = sign_and_install
        try:
            log, stages = [], []
            shell.remember_data(self.root, game.titleID, data)   # built while no device was connected
            out = wi.install(self.root, self.dev.udid, log=log.append,
                             stage=lambda *a: stages.append(a), template=self.tpl, signer_exe=self.exe)
        finally:
            signer.sign_and_install = orig
        self.assertTrue(out.ok, out)
        self.assertEqual(out.message[0], 'win.install.firstTime')   # trust the Apple ID, Developer Mode
        self.assertEqual(self.dev.revealed, 1)                       # its switch is shown, as Xcode does
        self.assertEqual(out.bundle_id, SHELL_ID)
        info = json.loads(self.out.read_text())
        self.assertEqual(info['frameworks'], ['DmGame0100ABCD00000000.framework'])
        self.assertEqual(info['udid'], '7')         # usbmuxd's device number: what plumesign's --udid matches
        self.assertEqual(self.dev.files['/Documents/games/0100ABCD00000000/romfs.img'], b'R' * 5000)
        joined = ''.join(log)
        self.assertNotIn(self.dev.udid, joined)              # the signer's lines are redacted
        self.assertIn(('win.install.stage.sign', 'done', 'Test iPhone', 100), stages)
        state = wi.Devices(self.root).get(self.dev.udid)
        self.assertEqual(state.bundle, SHELL_ID)
        self.assertEqual(out.copied_files, 1)
        self.assertEqual(shell.pending_data(self.root, shell.Library.load(self.root).present(), state.receipts), [])
        self.assertEqual(state.receipts['0100ABCD00000000'], wi.data_stamp(data))
        current = wi.library_hash(shell.Library.load(self.root).present(), self.tpl)
        self.assertFalse(wi.needs_update(state, current))
        self.assertTrue(wi.needs_update(state, current, now=time.time() + wi.RESIGN_AFTER + 1))
        self.assertTrue(wi.needs_update(state, 'another'))
        self.assertFalse(wi.needs_update(None, current))
        signer.sign_and_install = sign_and_install
        try:
            off = wi.install(self.root, self.dev.udid, template=self.tpl, signer_exe=self.exe)
            self.dev.developer_mode = True
            again = wi.install(self.root, self.dev.udid, template=self.tpl, signer_exe=self.exe)
        finally:
            signer.sign_and_install = orig
        self.assertEqual((off.ok, off.message[0]), (True, 'win.install.devModeOff'))
        self.assertEqual((again.ok, again.message[0], again.copied_files), (True, 'dev.installed', 0))
        self.assertEqual(self.dev.revealed, 2)                       # not asked once it is on

    def test_the_note_names_what_the_player_still_does(self):
        self.assertEqual(wi.done_message(True, None), 'win.install.firstTime')      # iOS 15 or unknown: say it all
        self.assertEqual(wi.done_message(True, False), 'win.install.firstTime')
        self.assertEqual(wi.done_message(True, True), 'win.install.firstTimeTrust')
        self.assertEqual(wi.done_message(False, False), 'win.install.devModeOff')
        self.assertEqual(wi.done_message(False, True), 'dev.installed')
        self.assertEqual(wi.done_message(False, None), 'dev.installed')

    def _signing(self):
        """sign_and_install that also "installs" the app on the pretend device, as the tool would."""
        orig = signer.sign_and_install

        def run(*a, **k):
            r = orig(*a, **k)
            info = json.loads(self.out.read_text())
            self.dev.apps[info['bundle']] = {'CFBundleIdentifier': info['bundle'], 'CFBundleExecutable': 'DmShell'}
            return r
        signer.sign_and_install = run
        self.addCleanup(setattr, signer, 'sign_and_install', orig)

    def test_the_app_holds_the_games_chosen_for_the_device(self):
        for tid in ('0100000000000A00', '0100000000000B00'):
            shell.add_built_game(self.root, make_framework(self.tmp / tid / 'shell-framework', tid))
        self._signing()
        out = wi.install(self.root, self.dev.udid, titles=['0100000000000B00'], template=self.tpl, signer_exe=self.exe)
        self.assertTrue(out.ok, out)
        self.assertEqual(json.loads(self.out.read_text())['frameworks'], ['DmGame0100000000000B00.framework'])
        self.assertEqual(wi.Devices(self.root).get(self.dev.udid).titles, ['0100000000000B00'])
        # an update without a choice keeps the device's games, not every built game
        again = wi.install(self.root, self.dev.udid, template=self.tpl, signer_exe=self.exe)
        self.assertTrue(again.ok, again)
        self.assertEqual(json.loads(self.out.read_text())['frameworks'], ['DmGame0100000000000B00.framework'])
        state = wi.Devices(self.root).get(self.dev.udid)
        self.assertEqual([g.titleID for g in wi.device_games(self.root, state)], ['0100000000000B00'])

    def test_a_device_on_an_older_ios_is_told_before_signing(self):
        shell.add_built_game(self.root, make_framework(self.tmp / 'w' / 'shell-framework', '0100000000000A00'))
        with open(self.tpl / 'Info.plist', 'rb') as f:
            info = plistlib.load(f)
        info['MinimumOSVersion'] = '26.0'
        with open(self.tpl / 'Info.plist', 'wb') as f:
            plistlib.dump(info, f)
        self.dev.ios = '18.5'
        out = wi.install(self.root, self.dev.udid, template=self.tpl, signer_exe=self.exe)
        self.assertEqual((out.ok, out.message[0], out.message[2:]), (False, 'win.install.oldIOS', ('18.5', '26.0')))
        self.assertFalse(self.out.exists())            # the signing tool never ran
        self.dev.ios = '26.1'
        self._signing()
        self.assertTrue(wi.install(self.root, self.dev.udid, template=self.tpl, signer_exe=self.exe).ok)

    def test_install_stops_early_with_a_reason(self):
        self.assertEqual(wi.install(self.root, self.dev.udid, template=self.tpl, signer_exe=self.exe).message,
                         ('win.install.noGames',))
        make_framework(self.root / 'frameworks', '0100ABCD00000000')
        lib = shell.Library()
        lib.add(shell.Game('0100ABCD00000000', 'Z', str(self.root / 'frameworks' / 'DmGame0100ABCD00000000.framework')))
        lib.save(self.root)
        self.assertEqual(wi.install(self.root, 'other-udid', template=self.tpl, signer_exe=self.exe).message,
                         ('win.install.notConnected',))
        self.dev.paired = False      # never trusted this PC: stop before the signing tool, with the way out
        out = wi.install(self.root, self.dev.udid, template=self.tpl, signer_exe=self.exe)
        self.assertEqual((out.message, out.failure), (('win.install.notPaired',), 'win.install.notPaired.next'))
        self.dev.paired = True
        if shell.find_template() is None:     # no app bundled beside this interpreter
            self.assertEqual(wi.install(self.root, self.dev.udid, signer_exe=self.exe).message, ('win.install.noTemplate',))


if __name__ == '__main__':
    unittest.main()
