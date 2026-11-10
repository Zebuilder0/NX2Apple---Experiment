"""The Windows install on an iPhone or iPad: the USB client (win/device.py), the shared app as an install assembles
it (win/shell_export.py), the signing tool's wrapper (win/signer.py) and the install that joins them (win/install.py),
against a pretend device (fake_device.py) and a pretend plumesign. No PySide6, no device, no network."""
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
from nspb_qt.win import device as dv   # noqa: E402
from nspb_qt.win import install as wi   # noqa: E402
from nspb_qt.win import shell_export as se   # noqa: E402
from nspb_qt.win import signer   # noqa: E402

SHELL_ID = 'org.nxnative.shell.ABCDE12345'


def make_template(folder: Path) -> Path:
    """An empty shared app as tools/build_shell_template.py makes it: a real (minimal) arm64 executable, which the
    staging signs ad hoc with the memory entitlement, and its fonts already in place (no font tools run)."""
    from test_swift_parity import _make_arm64_macho
    from nspb_qt.win import toolchain as tc
    app = folder / 'DmShell.app'
    (app / 'dm' / 'font').mkdir(parents=True)
    (app / 'DmShell').write_bytes(_make_arm64_macho(tc.MH_EXECUTE))
    (app / 'dm' / 'font' / 'standard.ttf').write_bytes(b'STD_TTF')
    (app / 'dm' / 'font' / 'nintendo_ext.ttf').write_bytes(b'EXT_TTF')
    with open(app / 'Info.plist', 'wb') as f:
        plistlib.dump({'CFBundleExecutable': 'DmShell', 'CFBundleIdentifier': 'org.nxnative.shell',
                       'CFBundleShortVersionString': '1.2.3'}, f)
    return app


def make_framework(folder: Path, tid: str, name='Game') -> Path:
    fw = folder / f'DmGame{tid}.framework'
    fw.mkdir(parents=True)
    (fw / f'DmGame{tid}').write_bytes(b'\xcf\xfa\xed\xfe' + bytes(28))
    (fw / 'game.manifest.json').write_text(json.dumps({'title_id': tid, 'name': name, 'loader': 'FH',
                                                        'framework_executable': f'DmGame{tid}'}))
    return fw


def embedded_entitlements(path: Path) -> dict | None:
    """The entitlements a code-signing reader finds in a Mach-O, read the way apple-codesign does for plumesign
    (crates/plume_core/src/utils/macho.rs embedded_entitlements): LC_CODE_SIGNATURE's SuperBlob, its slot 5, a blob with
    the entitlements magic holding an XML plist dictionary. None when there is none."""
    import struct
    data = path.read_bytes()
    if data[:4] != b'\xcf\xfa\xed\xfe':
        return None
    ncmds = struct.unpack_from('<I', data, 16)[0]
    off = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', data, off)
        if cmd == 0x1D:                                     # LC_CODE_SIGNATURE
            dataoff, _datasize = struct.unpack_from('<II', data, off + 8)
            if dataoff + 12 > len(data):                    # a placeholder past the end: not signed yet
                return None
            magic, _length, count = struct.unpack_from('>III', data, dataoff)
            if magic != 0xFADE0CC0:                         # CSMAGIC_EMBEDDED_SIGNATURE
                return None
            for i in range(count):
                slot, blob_off = struct.unpack_from('>II', data, dataoff + 12 + 8 * i)
                if slot == 5:                               # CSSLOT_ENTITLEMENTS
                    bmagic, blen = struct.unpack_from('>II', data, dataoff + blob_off)
                    if bmagic != 0xFADE7171:                # CSMAGIC_EMBEDDED_ENTITLEMENTS
                        return None
                    body = data[dataoff + blob_off + 8:dataoff + blob_off + blen]
                    value = plistlib.loads(body)
                    return value if isinstance(value, dict) else None
            return None
        off += size
    return None


def add_built(root: Path, built: Path) -> se.ShellGame:
    """A built framework into the shared app's library, as the build's end does (shell_export.add_to_library)."""
    tid = se.title_id_of_framework(built)
    name = json.loads((built / 'game.manifest.json').read_text())['name']
    library, _notes, err = se.add_to_library(root, built, tid, name)
    assert library is not None, err
    return next(g for g in library.games if g.title_id == tid)


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

    def test_a_stopped_copy_is_cancelled_and_leaves_no_part_file(self):
        self.dev.apps = {SHELL_ID: {'CFBundleIdentifier': SHELL_ID, 'CFBundleExecutable': 'DmShell'}}
        data = self.tmp / 'romfs'
        data.mkdir()
        (data / 'romfs.img').write_bytes(os.urandom(9 << 20))
        d = dv.list_devices()[0]
        stop = []
        with self.assertRaises(dv.Cancelled):
            dv.copy_game_data(d, SHELL_ID, '0100ABCD00000000', data, progress=lambda a, b: stop.append(1),
                              cancelled=lambda: bool(stop))
        self.assertFalse(any(p.endswith('.part') for p in self.dev.files), self.dev.files.keys())
        self.assertNotIn('/Documents/games/0100ABCD00000000/romfs.img', self.dev.files)

    def test_a_pulled_cable_mid_copy_is_a_device_error(self):
        self.dev.apps = {SHELL_ID: {'CFBundleIdentifier': SHELL_ID, 'CFBundleExecutable': 'DmShell'}}
        self.dev.drop_after_writes = 1
        data = self.tmp / 'romfs'
        data.mkdir()
        (data / 'romfs.img').write_bytes(os.urandom(9 << 20))
        d = dv.list_devices()[0]
        with self.assertRaises(dv.DeviceError) as cm:
            dv.copy_game_data(d, SHELL_ID, '0100ABCD00000000', data)
        self.assertNotIsInstance(cm.exception, dv.Cancelled)
        self.assertIn('keep the device connected', str(cm.exception))

    def test_a_damaged_reply_is_a_device_error_and_the_name_stays_empty(self):
        d = dv.list_devices()[0]
        self.dev.damaged_mux = True
        with self.assertRaises(dv.DeviceError):
            dv.list_devices()
        self.assertEqual(dv.describe(dv.Device(d.udid, d.device_id)).name, '')   # no traceback, no name

    def test_a_refused_connection_closes_every_socket(self):
        opened = []
        real_init, real_close = dv.Mux.__init__, dv.Mux.close

        def init(m, *a, **k):
            real_init(m, *a, **k)
            opened.append(m)

        def close(m):
            m.closed = True
            real_close(m)

        def refuse(m, device_id, port):
            raise dv.DeviceError('refused')
        d = dv.list_devices()[0]
        from unittest import mock
        with mock.patch.object(dv.Mux, '__init__', init), mock.patch.object(dv.Mux, 'close', close), \
                mock.patch.object(dv.Mux, 'connect', refuse):
            with self.assertRaises(dv.DeviceError):
                dv.Lockdown(d)
        self.assertTrue(opened)
        self.assertTrue(all(getattr(m, 'closed', False) for m in opened), 'a Mux was left open')

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

    def test_built_framework_mirror_and_assemble(self):
        work = self.tmp / 'work'
        built = make_framework(work / 'shell-framework', '0100ABCD00000000', 'Zelda')
        self.assertEqual(se.built_framework(work), built)
        root = self.tmp / 'root'
        game = add_built(root, built)
        self.assertEqual((game.title_id, game.name), ('0100ABCD00000000', 'Zelda'))
        self.assertTrue((Path(game.framework) / 'game.manifest.json').is_file())
        self.assertNotEqual(Path(game.framework).parent, built.parent)    # a copy in the cache
        tpl = make_template(self.tmp / 'tpl')
        self.assertTrue(se.template_version(tpl).startswith('1.2.3:'))
        app = se.assemble_app(root, '', tpl, se.present_games(root), bundle_id='org.nxnative.shell')
        self.assertEqual(app, se.install_stage(root))
        self.assertTrue((app / 'Frameworks' / built.name / 'game.manifest.json').is_file())
        self.assertFalse((tpl / 'Frameworks').exists())                  # the template stays empty
        # the signing tool asks Apple for the capabilities the executable's entitlements name: the staging signs it
        # ad hoc with the Increased Memory Limit entitlement, as the IPA export does
        self.assertEqual(embedded_entitlements(app / 'DmShell'),
                         {'com.apple.developer.kernel.increased-memory-limit': True})
        self.assertIsNone(embedded_entitlements(tpl / 'DmShell'))
        app2 = se.assemble_app(root, '', tpl, se.present_games(root), bundle_id='org.nxnative.shell')   # a fresh copy
        self.assertEqual(app, app2)
        with self.assertRaises(ValueError):
            se.assemble_app(root, '', tpl, [], bundle_id='org.nxnative.shell')

    def test_a_game_whose_build_folder_is_gone_is_its_mirror(self):
        import shutil
        root = self.tmp / 'root'
        built = make_framework(self.tmp / 'w' / 'shell-framework', '0100ABCD00000000', 'Zelda')
        add_built(root, built)
        shutil.rmtree(self.tmp / 'w')
        games = se.present_games(root)
        self.assertEqual([g.title_id for g in games], ['0100ABCD00000000'])
        self.assertEqual(Path(games[0].framework), se.mirrored_framework(root, '0100ABCD00000000'))
        (Path(games[0].framework) / 'game.manifest.json').unlink()       # incomplete: left out, not installed
        self.assertEqual(se.present_games(root), [])
        self.assertEqual([g.title_id for g in se.present_titles(
            [se.ShellGame('0100A', 'A', '/a'), se.ShellGame('0100B', 'B', '/b')], ['0100b'])], ['0100B'])

    def test_a_new_template_changes_its_identity(self):
        tpl = make_template(self.tmp / 'tpl')
        before = se.template_version(tpl)
        with open(tpl / 'DmShell', 'ab') as f:
            f.write(b'\0' * 16)          # another launcher's template
        self.assertNotEqual(se.template_version(tpl), before)
        self.assertEqual(se.template_version(self.tmp / 'none'), '')
        self.assertEqual(se.template_min_ios(tpl), '')
        self.assertEqual(se.version_tuple('26.0.1'), (26, 0, 1))

    def test_pending_data_follows_the_receipts_and_skips_an_overwritten_folder(self):
        root = self.tmp / 'root'
        a = se.ShellGame('0100AAAA00000000', 'A', '/x'); b = se.ShellGame('0100BBBB00000000', 'B', '/y')
        da, db = self.tmp / 'a', self.tmp / 'b'
        for d, body in ((da, b'a'), (db, b'b')):
            d.mkdir()
            (d / 'romfs.img').write_bytes(body)
        wi.remember_data(root, a.title_id, da)
        wi.remember_data(root, b.title_id, db)
        self.assertEqual(wi.pending_data(root, [a, b], {}), [(a.title_id, da), (b.title_id, db)])
        self.assertEqual(wi.pending_data(root, [a, b], {a.title_id: wi.data_stamp(da)}), [(b.title_id, db)])
        (db / 'romfs.img').write_bytes(b'another game now')   # the shared output folder, packed by a later build
        self.assertEqual(wi.pending_data(root, [a, b], {}), [(a.title_id, da)])
        self.assertEqual(wi.pending_data(self.tmp / 'none', [a], {}), [])

    def test_each_game_gets_its_banner_as_the_mac_puts_it(self):
        root = self.tmp / 'root'
        built = make_framework(self.tmp / 'w' / 'shell-framework', '0100ABCD00000000', 'Zelda')
        add_built(root, built)
        add_built(root, make_framework(self.tmp / 'w2' / 'shell-framework', '0100EEEE00000000', 'Other'))
        art = self.tmp / 'zelda.png'
        art.write_bytes(b'png bytes')
        pics = {'0100ABCD00000000': str(art), '0100EEEE00000000': None}
        app = se.assemble_app(root, '', make_template(self.tmp / 'tpl'), se.present_games(root),
                              bundle_id='org.nxnative.shell', banner=pics.get)
        fw = app / 'Frameworks'
        self.assertEqual((fw / 'DmGame0100ABCD00000000.framework' / 'banner.png').read_bytes(), b'png bytes')
        self.assertFalse(any((fw / 'DmGame0100EEEE00000000.framework').glob('banner.*')))   # no picture: the icon shows

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

    def test_the_copy_rate_and_the_time_left(self):
        r = wi.CopyRate(window=30, least=3)
        r.add(0, 100.0)
        r.add(10_000_000, 101.0)
        self.assertIsNone(r.rate())                        # too soon to tell
        r.add(40_000_000, 104.0)
        self.assertEqual(r.rate(), 10_000_000)             # 40 MB in 4 s
        self.assertEqual(r.seconds_left(40_000_000, 140_000_000), 10.0)
        for i in range(1, 40):                             # only the last 30 s count
            r.add(40_000_000 + i * 20_000_000, 104.0 + i)
        self.assertAlmostEqual(r.rate(), 20_000_000, delta=1_000_000)
        r.add(5, 200.0)                                    # a count that starts over
        self.assertIsNone(r.rate())

    def test_the_copy_plan_counts_every_game(self):
        a, b = self.tmp / 'a', self.tmp / 'b'
        a.mkdir(); b.mkdir()
        (a / 'romfs.img').write_bytes(b'x' * 300)
        (b / 'romfs.img').write_bytes(b'y' * 700)
        plan = wi.CopyPlan([('A', 'Game A', a), ('B', 'Game B', b)])
        self.assertEqual(plan.report(1, 0, None), {'game': 'Game A', 'number': 1, 'count': 2, 'done': 0, 'total': 1000})
        self.assertEqual(plan.report(1, 100, 200)['total'], 900)     # the device lacked only 200 bytes of A
        plan.finish(1, 200)
        second = plan.report(2, 350, 700)
        self.assertEqual((second['game'], second['number'], second['done'], second['total']), ('Game B', 2, 550, 900))

    def test_which_devices_need_older_device_games(self):
        cases = {'iPhone15,3': 'older', 'iPhone15,4': 'older', 'iPhone12,1': 'older', 'iPhone16,1': 'new',
                 'iPhone17,5': 'new', 'iPad14,5': 'new', 'iPad13,16': 'new', 'iPad14,1': 'older', 'iPad13,18': 'older',
                 'iPad15,7': 'older', 'iPad16,3': 'new', 'iPod9,1': 'unknown', '': 'unknown'}
        for product, want in cases.items():
            self.assertEqual(dv.gpu_class(product), want, product)

    def test_a_game_plays_on_older_devices_by_its_env_or_its_profile(self):
        fw = make_framework(self.tmp / 'f', '0100F2C0115B6000')
        self.assertFalse(se.supports_older(fw))
        (fw / 'dm').mkdir()
        (fw / 'dm' / 'env.txt').write_text('# a comment\nDM_PROF_TEX_BC_CPU=1\n')
        self.assertTrue(se.supports_older(fw))
        (fw / 'dm' / 'env.txt').write_text('DM_TEX_BC_CPU=1\n')       # the name the engine never read
        self.assertFalse(se.supports_older(fw))
        eng = self.tmp / 'engine'
        (eng / 'dm' / 'games' / '0100F2C0115B6000').mkdir(parents=True)
        (eng / 'dm' / 'games' / '0100F2C0115B6000' / 'game.tsv').write_text('name\tZelda\ntex_bc_cpu\ton\n')
        self.assertTrue(se.supports_older(fw, str(eng)))           # the profile turns it on

    def test_the_signing_step_reads_the_tools_lines(self):
        self.assertEqual(wi.signer_step('[2026-11-06T10:00:00Z INFO  plumesign] Registering device'), 'Registering device')
        self.assertEqual(wi.signer_step('$ plumesign sign --package <shared app>'), '')
        self.assertEqual(wi.signer_step('Installation progress: 50%'), '')
        self.assertEqual(wi.signer_step('   '), '')
        self.assertEqual(len(wi.signer_step('x' * 200)), 70)

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
        game = add_built(self.root, built)
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
            log, stages, reports = [], [], []
            wi.remember_data(self.root, game.title_id, data)   # built while no device was connected
            out = wi.install(self.root, self.dev.udid, log=log.append, transfer=reports.append,
                             stage=lambda *a: stages.append(a), template=self.tpl, signer_exe=self.exe)
        finally:
            signer.sign_and_install = orig
        self.assertTrue(out.ok, out)
        # audit 2, P9: the signed copy (with its provisioning profile) is not left behind
        self.assertFalse(se.install_stage(self.root).parent.exists())
        self.assertEqual(out.message[0], 'win.install.firstTime')   # trust the Apple ID, Developer Mode
        self.assertEqual(self.dev.revealed, 1)                       # its switch is shown, as Xcode does
        self.assertEqual(out.bundle_id, SHELL_ID)
        info = json.loads(self.out.read_text())
        self.assertEqual(info['frameworks'], ['DmGame0100ABCD00000000.framework'])
        self.assertEqual(info['udid'], '7')         # usbmuxd's device number: what plumesign's --udid matches
        self.assertEqual(self.dev.files['/Documents/games/0100ABCD00000000/romfs.img'], b'R' * 5000)
        # the copy says which game, its number of all, and the bytes of every game together
        self.assertEqual((reports[0]['game'], reports[0]['number'], reports[0]['count'], reports[0]['done']),
                         ('Zelda', 1, 1, 0))
        self.assertEqual((reports[-1]['done'], reports[-1]['total']), (5000, 5000))
        joined = ''.join(log)
        self.assertNotIn(self.dev.udid, joined)              # the signer's lines are redacted
        self.assertIn(('win.install.stage.sign', 'done', 'Test iPhone', 100), stages)
        # while the tool works with Apple, the step shows its latest line instead of standing still at 0 %
        self.assertIn(('win.install.stage.sign', 'running', 'win.install.contactingApple', 0), stages)
        self.assertIn(('win.install.stage.sign', 'running', 'Registering device: Test iPhone (<device>)', 0), stages)
        self.assertIn(('win.install.stage.sign', 'running', '50%', 50), stages)
        state = wi.Devices(self.root).get(self.dev.udid)
        self.assertEqual(state.bundle, SHELL_ID)
        self.assertEqual(out.copied_files, 1)
        self.assertEqual(wi.pending_data(self.root, se.present_games(self.root), state.receipts), [])
        self.assertEqual(state.receipts['0100ABCD00000000'], wi.data_stamp(data))
        current = wi.library_hash(se.present_games(self.root), self.tpl)
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
            add_built(self.root, make_framework(self.tmp / tid / 'shell-framework', tid))
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
        self.assertEqual([g.title_id for g in wi.device_games(self.root, state)], ['0100000000000B00'])

    def test_an_older_device_is_warned_of_games_built_for_newer_ones(self):
        add_built(self.root, make_framework(self.tmp / 'w' / 'shell-framework', '0100000000000A00', 'Zelda'))
        self.dev.product = 'iPhone15,3'                 # an iPhone 14 Pro Max: A16, no BC textures
        self._signing()
        log = []
        out = wi.install(self.root, self.dev.udid, template=self.tpl, signer_exe=self.exe, log=log.append,
                         t=lambda key, *a: key + ':' + '|'.join(map(str, a)))
        self.assertTrue(out.ok, out)
        self.assertIn('win.install.olderWarn:Test iPhone|Zelda', ''.join(log))

    def test_a_device_on_an_older_ios_is_told_before_signing(self):
        add_built(self.root, make_framework(self.tmp / 'w' / 'shell-framework', '0100000000000A00'))
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
        lib = se.ShellLibrary()
        lib.add(se.ShellGame('0100ABCD00000000', 'Z', str(self.root / 'frameworks' / 'DmGame0100ABCD00000000.framework')))
        lib.save(self.root)
        self.assertEqual(wi.install(self.root, 'other-udid', template=self.tpl, signer_exe=self.exe).message,
                         ('win.install.notConnected',))
        self.dev.paired = False      # never trusted this PC: stop before the signing tool, with the way out
        out = wi.install(self.root, self.dev.udid, template=self.tpl, signer_exe=self.exe)
        self.assertEqual((out.message, out.failure), (('win.install.notPaired',), 'win.install.notPaired.next'))
        self.dev.paired = True
        if se.find_shell_template('', root=self.root) is None:     # no app bundled beside this interpreter
            self.assertEqual(wi.install(self.root, self.dev.udid, signer_exe=self.exe).message, ('win.install.noTemplate',))


class DevicesFile(unittest.TestCase):
    def test_two_installs_keep_each_others_device(self):
        root = Path(tempfile.mkdtemp())
        first, second = wi.Devices(root), wi.Devices(root)        # both read the file before either saved
        first.put('A', wi.DeviceState(bundle='org.nxnative.shell.T', signed=1.0))
        second.put('B', wi.DeviceState(bundle='org.nxnative.shell.T', signed=2.0))
        again = wi.Devices(root)
        self.assertEqual(sorted(again.items), ['A', 'B'])

    def test_a_damaged_entry_is_skipped_not_a_traceback(self):
        root = Path(tempfile.mkdtemp())
        (root / 'devices.json').write_text(json.dumps({
            'A': {'bundle': 'org.nxnative.shell.T', 'signed': 'yesterday'},
            'B': {'bundle': 'org.nxnative.shell.T', 'signed': 5, 'receipts': ['not', 'a', 'dict']},
            'C': {'bundle': 'org.nxnative.shell.T', 'signed': 7, 'titles': ['0100000000000a00']}}), encoding='utf-8')
        d = wi.Devices(root)
        self.assertEqual(sorted(d.items), ['C'])
        self.assertEqual(d.get('C').titles, ['0100000000000A00'])


if __name__ == '__main__':
    unittest.main()
