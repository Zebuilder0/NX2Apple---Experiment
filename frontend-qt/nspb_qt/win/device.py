"""A small iPhone and iPad client over Apple's USB service, standard library only.

What the Windows launcher needs from a connected device, and nothing more: list the devices,
read a device's name and free space, find the shared app on it, and copy a game's data into the
app's `Documents/games/<title ID>/`. Signing and installing are the signing tool's job
(`signer.py`).

The protocols are Apple's and are the ones libimobiledevice and pymobiledevice3 speak:

* **usbmuxd**: Apple Mobile Device Service (iTunes) on Windows listens on 127.0.0.1:27015, the
  Mac and Linux daemons on `/var/run/usbmuxd`. Packets are a 16-byte little-endian header
  (length, version 1, message 8 = plist, tag) and an XML plist. `Connect` turns the socket into a
  tunnel to a port on the device.
* **lockdownd** on port 62078: big-endian 32-bit length and a plist. `StartSession` with the
  pair record's HostID and SystemBUID, then TLS with the pair record's host certificate when the
  device asks for it. `StartService` names a port for a service.
* **house_arrest** `VendDocuments` opens the app's container over AFC, the file protocol
  (40-byte `CFA6LPAA` header, little-endian), with the app's Documents at `/Documents`.
* **installation_proxy** `Browse` lists the installed apps.

The pair record is the one this PC already has with the device: iTunes, the Apple Devices app or
the signing tool make it when the device is plugged in and the player taps Trust. Nothing here
pairs a device, signs anything or talks to Apple's servers.
"""
from __future__ import annotations

import os
import plistlib
import socket
import ssl
import struct
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable

USBMUX_TCP = ('127.0.0.1', 27015)
USBMUX_UNIX = '/var/run/usbmuxd'
LOCKDOWN_PORT = 62078
LABEL = 'NX2Apple'

HOUSE_ARREST = 'com.apple.mobile.house_arrest'
INSTALLATION_PROXY = 'com.apple.mobile.installation_proxy'

#: Developer Mode (iOS 16 and later): its state is a lockdown value, and the AMFI service shows its
#: switch in Settings (action 0, what Xcode asks when a device is plugged in; libimobiledevice's
#: idevicedevmodectl reveal, pymobiledevice3's amfi reveal-developer-mode)
AMFI = 'com.apple.amfi.lockdown'
AMFI_DOMAIN = 'com.apple.security.mac.amfi'
AMFI_REVEAL = 0

#: The shared app's executable: how the app is found on a device whatever bundle ID the signing
#: tool gave it (it appends the team ID to `org.nxnative.shell`).
SHELL_EXECUTABLE = 'DmShell'
SHELL_BUNDLE_PREFIX = 'org.nxnative.shell'

# AFC
AFC_MAGIC = b'CFA6LPAA'
AFC_HEADER = struct.Struct('<8sQQQQ')   # magic, entire length, this length, packet number, operation
AFC_STATUS, AFC_DATA, AFC_READ_DIR = 0x01, 0x02, 0x03
AFC_REMOVE_PATH, AFC_MAKE_DIR, AFC_GET_FILE_INFO = 0x08, 0x09, 0x0A
AFC_FILE_OPEN, AFC_FILE_OPEN_RES, AFC_WRITE, AFC_FILE_CLOSE = 0x0D, 0x0E, 0x10, 0x14
AFC_RENAME_PATH = 0x18
AFC_MODE_WRONLY = 3            # "w": write, create, truncate
AFC_READ_ERROR, AFC_OBJECT_NOT_FOUND = 4, 8
#: What a missing path answers: GetFileInfo says READ_ERROR on a device (pymobiledevice3's stat
#: maps it to "no such file"), RemovePath says OBJECT_NOT_FOUND
AFC_MISSING = (AFC_READ_ERROR, AFC_OBJECT_NOT_FOUND)
AFC_WRITE_CHUNK = 4 << 20


class DeviceError(Exception):
    """A device operation failed. `str()` is a sentence for the log."""


class NotPaired(DeviceError):
    """This PC has no pair record for the device: plug it in, unlock it and tap Trust."""


class Locked(DeviceError):
    """The device is locked with a passcode: unlock it and try again."""


class AppMissing(DeviceError):
    """The app is not installed on the device."""


@dataclass
class Device:
    udid: str
    device_id: int
    connection: str = 'USB'     # 'USB' or 'Network'
    name: str = ''
    ios: str = ''               # its iOS version (ProductVersion), '' until describe() read it

    @property
    def wired(self) -> bool:
        return self.connection == 'USB'


# ---------------------------------------------------------------- usbmuxd

def _recv_exact(sock: socket.socket, n: int) -> bytes:
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise DeviceError('the device connection closed')
        buf += chunk
    return bytes(buf)


def _mux_socket(timeout: float) -> socket.socket:
    addr = os.environ.get('NSPB_USBMUXD')   # tests and odd setups: host:port or a socket path
    if addr and ':' in addr and not addr.startswith('/'):
        host, port = addr.rsplit(':', 1)
        return socket.create_connection((host, int(port)), timeout=timeout)
    if sys.platform == 'win32' and not addr:
        return socket.create_connection(USBMUX_TCP, timeout=timeout)
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(addr or USBMUX_UNIX)
    return s


class Mux:
    """One connection to usbmuxd (plist protocol). After `connect()` it is a tunnel."""

    def __init__(self, timeout: float = 10.0):
        try:
            self.sock = _mux_socket(timeout)
        except OSError as e:
            raise DeviceError(f'Apple Mobile Device Service is not reachable ({e}): install iTunes '
                              'from apple.com, then plug the device in again') from e
        self.tag = 1

    def close(self) -> None:
        try:
            self.sock.close()
        except OSError:
            pass

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def send(self, msg: dict) -> int:
        body = plistlib.dumps({'ClientVersionString': LABEL, 'ProgName': LABEL,
                               'kLibUSBMuxVersion': 3, **msg})
        tag = self.tag
        self.tag += 1
        self.sock.sendall(struct.pack('<IIII', 16 + len(body), 1, 8, tag) + body)
        return tag

    def recv(self) -> dict:
        size, _version, message, _tag = struct.unpack('<IIII', _recv_exact(self.sock, 16))
        body = _recv_exact(self.sock, size - 16)
        if message != 8:
            raise DeviceError(f'usbmuxd sent message type {message}, not a plist')
        return plistlib.loads(body)

    def request(self, msg: dict) -> dict:
        self.send(msg)
        return self.recv()

    def list_devices(self) -> list[Device]:
        r = self.request({'MessageType': 'ListDevices'})
        out: list[Device] = []
        for item in r.get('DeviceList') or []:
            props = item.get('Properties') or {}
            udid = props.get('SerialNumber') or ''
            if udid:
                out.append(Device(udid=udid, device_id=int(item.get('DeviceID', props.get('DeviceID', 0))),
                                  connection=props.get('ConnectionType', 'USB')))
        return out

    def pair_record(self, udid: str) -> dict | None:
        r = self.request({'MessageType': 'ReadPairRecord', 'PairRecordID': udid})
        data = r.get('PairRecordData')
        if data:
            return plistlib.loads(data)
        return lockdown_folder_record(udid)


    def connect(self, device_id: int, port: int) -> socket.socket:
        r = self.request({'MessageType': 'Connect', 'DeviceID': device_id,
                          'PortNumber': socket.htons(port)})
        if r.get('MessageType') != 'Result' or r.get('Number', 1) != 0:
            raise DeviceError(f'the device refused a connection to port {port} (usbmuxd result '
                              f'{r.get("Number")}): keep it connected and unlocked')
        return self.sock


def lockdown_folder_record(udid: str) -> dict | None:
    """The pair record iTunes keeps in `%ALLUSERSPROFILE%\\Apple\\Lockdown\\<UDID>.plist`, for an Apple
    Mobile Device Service that does not hand it out (pymobiledevice3 reads the same file). None
    when it is not there or this user may not read it."""
    if sys.platform != 'win32':
        return None
    base = Path(os.environ.get('ALLUSERSPROFILE') or r'C:\ProgramData') / 'Apple' / 'Lockdown'
    try:
        with open(base / f'{udid}.plist', 'rb') as f:
            return plistlib.load(f)
    except (OSError, plistlib.InvalidFileException, ValueError):
        return None


def is_paired(udid: str, timeout: float = 5.0) -> bool:
    """Whether this PC has a pair record for the device (the player tapped Trust once)."""
    try:
        with Mux(timeout=timeout) as m:
            return bool(m.pair_record(udid))
    except (DeviceError, OSError, ValueError, struct.error):
        return False


def service_running(timeout: float = 2.0) -> bool:
    """Whether usbmuxd (Apple Mobile Device Service) answers."""
    try:
        with Mux(timeout=timeout) as m:
            m.list_devices()
        return True
    except (DeviceError, OSError, plistlib.InvalidFileException, ValueError, struct.error):
        return False


def list_devices(timeout: float = 5.0) -> list[Device]:
    """The connected devices, one entry per device (a cable wins over Wi-Fi)."""
    with Mux(timeout=timeout) as m:
        devices = m.list_devices()
    best: dict[str, Device] = {}
    for d in devices:
        if d.udid not in best or (d.wired and not best[d.udid].wired):
            best[d.udid] = d
    return list(best.values())


# ---------------------------------------------------------------- lockdownd and services

class PlistSocket:
    """A service connection that frames plists with a big-endian 32-bit length."""

    def __init__(self, sock: socket.socket):
        self.sock = sock

    def send(self, msg: dict) -> None:
        body = plistlib.dumps(msg)
        self.sock.sendall(struct.pack('>I', len(body)) + body)

    def recv(self) -> dict:
        (size,) = struct.unpack('>I', _recv_exact(self.sock, 4))
        if size > 64 << 20:
            raise DeviceError(f'a device reply of {size} bytes is not a plist')
        return plistlib.loads(_recv_exact(self.sock, size))

    def request(self, msg: dict) -> dict:
        self.send(msg)
        return self.recv()

    def close(self) -> None:
        try:
            self.sock.close()
        except OSError:
            pass


def tls_context(record: dict) -> ssl.SSLContext:
    """The client TLS context lockdownd and its services expect: the pair record's host
    certificate and key, no server verification (the device's certificate is self-signed),
    legacy ciphers allowed (older pair records use SHA-1)."""
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    try:
        ctx.set_ciphers('ALL:!aNULL:!eNULL:@SECLEVEL=0')
    except ssl.SSLError:
        ctx.set_ciphers('ALL:!aNULL:!eNULL')
    ctx.options |= 0x4             # OP_LEGACY_SERVER_CONNECT
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    cert, key = record.get('HostCertificate'), record.get('HostPrivateKey')
    if not cert or not key:
        raise NotPaired('the pair record has no host certificate: unplug the device, plug it in '
                        'again and tap Trust')
    # load_cert_chain reads files only. The file holds the PC's own pairing key for this device,
    # so it lives only for this call and is deleted at once (the key is already on this disk in
    # the pair record store).
    fd, path = tempfile.mkstemp(prefix='nx2apple-pair-', suffix='.pem')
    try:
        with os.fdopen(fd, 'wb') as f:
            f.write(bytes(cert) + b'\n' + bytes(key))
        ctx.load_cert_chain(path)
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass
    return ctx


class Lockdown:
    """A lockdownd session on one device. Use as a context manager."""

    def __init__(self, device: Device, timeout: float = 15.0):
        self.device = device
        self.timeout = timeout
        with Mux(timeout=timeout) as m:
            record = m.pair_record(device.udid)
        if not record:
            raise NotPaired(f'this PC is not paired with {device.udid}: plug it in with a cable, '
                            'unlock it and tap Trust')
        self.record = record
        self._mux = Mux(timeout=timeout)
        self.conn = PlistSocket(self._mux.connect(device.device_id, LOCKDOWN_PORT))
        try:
            self._start_session(record)
        except BaseException:
            self.conn.close()          # a refused session must not leave the connection open
            raise

    def _start_session(self, record: dict) -> None:
        r = self.conn.request({'Label': LABEL, 'Request': 'QueryType'})
        if r.get('Type') != 'com.apple.mobile.lockdown':
            raise DeviceError(f'port {LOCKDOWN_PORT} is not lockdownd ({r.get("Type")})')
        r = self.conn.request({'Label': LABEL, 'Request': 'StartSession',
                               'HostID': record.get('HostID'), 'SystemBUID': record.get('SystemBUID')})
        if r.get('Error'):
            if r['Error'] in ('InvalidHostID', 'PairingDialogResponsePending'):
                raise NotPaired('the device does not trust this PC yet: unlock it and tap Trust')
            raise DeviceError(f'the device refused a session: {r["Error"]}')
        if r.get('EnableSessionSSL'):
            self.conn.sock = tls_context(record).wrap_socket(self.conn.sock)

    def close(self) -> None:
        try:
            self.conn.request({'Label': LABEL, 'Request': 'StopSession'})
        except (DeviceError, OSError, ValueError):
            pass
        self.conn.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def get_value(self, key: str | None = None, domain: str | None = None):
        msg = {'Label': LABEL, 'Request': 'GetValue'}
        if key:
            msg['Key'] = key
        if domain:
            msg['Domain'] = domain
        r = self.conn.request(msg)
        if r.get('Error'):
            raise DeviceError(f'GetValue {domain or ""} {key or ""}: {r["Error"]}')
        return r.get('Value')

    def service(self, name: str) -> PlistSocket:
        r = self.conn.request({'Label': LABEL, 'Request': 'StartService', 'Service': name})
        if r.get('Error'):
            if r['Error'] == 'PasswordProtected':
                raise Locked('the device is locked: unlock it and keep it unlocked during the copy')
            raise DeviceError(f'the device refused {name}: {r["Error"]}')
        mux = Mux(timeout=self.timeout)
        sock = mux.connect(self.device.device_id, int(r['Port']))
        if r.get('EnableServiceSSL'):
            sock = tls_context(self.record).wrap_socket(sock)
        return PlistSocket(sock)

    def name(self) -> str:
        try:
            return str(self.get_value('DeviceName') or '')
        except DeviceError:
            return ''

    def free_bytes(self) -> int | None:
        try:
            v = self.get_value('AmountDataAvailable', 'com.apple.disk_usage')
            return int(v) if v is not None else None
        except (DeviceError, ValueError, TypeError):
            return None


def installed_apps(lockdown: Lockdown) -> dict[str, dict]:
    """The user apps on the device: bundle ID → a few Info.plist keys."""
    svc = lockdown.service(INSTALLATION_PROXY)
    try:
        svc.send({'Command': 'Browse', 'ClientOptions': {
            'ApplicationType': 'User',
            'ReturnAttributes': ['CFBundleIdentifier', 'CFBundleExecutable', 'CFBundleDisplayName',
                                 'CFBundleShortVersionString']}})
        apps: dict[str, dict] = {}
        while True:
            r = svc.recv()
            if r.get('Error'):
                raise DeviceError(f'the app list: {r["Error"]}')
            for a in r.get('CurrentList') or []:
                if a.get('CFBundleIdentifier'):
                    apps[a['CFBundleIdentifier']] = a
            if r.get('Status') == 'Complete':
                return apps
    finally:
        svc.close()


def shell_bundles(apps: dict[str, dict]) -> list[str]:
    """The bundle IDs of the shared app on a device (executable DmShell), ours first."""
    found = [b for b, a in apps.items() if a.get('CFBundleExecutable') == SHELL_EXECUTABLE]
    return sorted(found, key=lambda b: (not b.startswith(SHELL_BUNDLE_PREFIX), b))


# ---------------------------------------------------------------- AFC over house_arrest

class Afc:
    """AFC on a vended app container (`/Documents/...`)."""

    def __init__(self, conn: PlistSocket):
        self.sock = conn.sock
        self.packet = 0

    def close(self) -> None:
        try:
            self.sock.close()
        except OSError:
            pass

    def op(self, operation: int, data: bytes = b'', payload: bytes = b'') -> tuple[int, bytes]:
        """Send one packet (`data` is the header part, `payload` the bulk data) and return the
        answer's operation and body. A failure status raises, with the AFC error code."""
        this = AFC_HEADER.size + len(data)
        whole = this + len(payload)
        self.sock.sendall(AFC_HEADER.pack(AFC_MAGIC, whole, this, self.packet, operation) + data + payload)
        self.packet += 1
        magic, whole, this, _num, rop = AFC_HEADER.unpack(_recv_exact(self.sock, AFC_HEADER.size))
        if magic != AFC_MAGIC:
            raise DeviceError('the device sent a damaged file-transfer reply')
        body = _recv_exact(self.sock, whole - AFC_HEADER.size) if whole > AFC_HEADER.size else b''
        if rop == AFC_STATUS:
            code = struct.unpack_from('<Q', body)[0] if len(body) >= 8 else 0
            if code:
                raise AfcError(code)
        return rop, body

    @staticmethod
    def _path(p: str) -> bytes:
        return p.encode('utf-8') + b'\0'

    def stat(self, path: str) -> dict | None:
        try:
            _, body = self.op(AFC_GET_FILE_INFO, self._path(path))
        except AfcError as e:
            if e.code in AFC_MISSING:
                return None
            raise
        parts = body.split(b'\0')
        return {parts[i].decode(): parts[i + 1].decode() for i in range(0, len(parts) - 1, 2)}

    def size(self, path: str) -> int | None:
        st = self.stat(path)
        return int(st.get('st_size', 0)) if st and st.get('st_ifmt') != 'S_IFDIR' else None

    def makedirs(self, path: str) -> None:
        self.op(AFC_MAKE_DIR, self._path(path))   # makes the missing parents too

    def remove(self, path: str) -> None:
        try:
            self.op(AFC_REMOVE_PATH, self._path(path))
        except AfcError as e:
            if e.code not in AFC_MISSING:
                raise

    def rename(self, src: str, dst: str) -> None:
        self.op(AFC_RENAME_PATH, self._path(src) + self._path(dst))

    def put(self, local: Path, remote: str, progress: Callable[[int], None] | None = None,
            cancelled: Callable[[], bool] | None = None) -> None:
        """Copy a file to `remote` through `remote.part`, renamed at the end: a stopped copy never
        leaves a file the app could take for whole."""
        part = remote + '.part'
        _, body = self.op(AFC_FILE_OPEN, struct.pack('<Q', AFC_MODE_WRONLY) + self._path(part))
        handle = struct.pack('<Q', struct.unpack_from('<Q', body)[0])
        try:
            with open(local, 'rb') as f:
                while True:
                    if cancelled and cancelled():
                        raise DeviceError('the copy was stopped')
                    chunk = f.read(AFC_WRITE_CHUNK)
                    if not chunk:
                        break
                    self.op(AFC_WRITE, handle, chunk)
                    if progress:
                        progress(len(chunk))
        finally:
            try:
                self.op(AFC_FILE_CLOSE, handle)
            except (DeviceError, OSError):
                pass
        self.remove(remote)
        self.rename(part, remote)


class AfcError(DeviceError):
    def __init__(self, code: int):
        self.code = code
        super().__init__(f'the device refused a file operation (AFC error {code})')


def open_documents(lockdown: Lockdown, bundle_id: str) -> Afc:
    """The app's container over AFC (`VendDocuments`: its Documents are at `/Documents`)."""
    svc = lockdown.service(HOUSE_ARREST)
    r = svc.request({'Command': 'VendDocuments', 'Identifier': bundle_id})
    if r.get('Error'):
        svc.close()
        if r['Error'] == 'ApplicationLookupFailed':
            raise AppMissing(f'{bundle_id} is not installed on the device')
        raise DeviceError(f'the device would not open {bundle_id}\'s files: {r["Error"]}')
    return Afc(svc)


# ---------------------------------------------------------------- the game data

def local_files(folder: Path) -> dict[str, int]:
    """The game data to copy: every file under `folder` (romfs.img, aoc/...) → its size, keyed
    by its path relative to `folder` with forward slashes, as the app reads it."""
    out: dict[str, int] = {}
    folder = Path(folder)
    if not folder.is_dir():
        return out
    for p in sorted(folder.rglob('*')):
        if p.is_file() and not p.name.endswith('.part'):
            out[p.relative_to(folder).as_posix()] = p.stat().st_size
    return out


def files_to_copy(local: dict[str, int], remote: dict[str, int | None],
                  force: Iterable[str] = ()) -> list[str]:
    """The files the device lacks or holds at another size, plus `force` (romfs.img when its
    identity changed): the same rule as the Mac launcher's ShellInstall.filesToCopy."""
    forced = set(force)
    return [p for p, n in local.items() if p in forced or remote.get(p) != n]


def game_folder(title_id: str) -> str:
    return f'/Documents/games/{title_id.upper()}'


def copy_game_data(device: Device, bundle_id: str, title_id: str, folder: Path, *,
                   force: Iterable[str] = (), log: Callable[[str], None] = lambda s: None,
                   progress: Callable[[int, int], None] | None = None,
                   cancelled: Callable[[], bool] | None = None,
                   margin: int = 2_000_000_000) -> tuple[int, int]:
    """Copy the files of `folder` the device lacks into the app's `Documents/games/<title ID>/`.
    Returns (files copied, bytes copied). Raises DeviceError with a sentence for the player."""
    local = local_files(folder)
    if not local:
        raise DeviceError(f'no game data in {folder}')
    with Lockdown(device) as ld:
        afc = open_documents(ld, bundle_id)
        try:
            base = game_folder(title_id)
            remote = {p: afc.size(f'{base}/{p}') for p in local}
            todo = files_to_copy(local, remote, force)
            if not todo:
                log('game data: already on the device\n')
                return 0, 0
            need = sum(local[p] for p in todo)
            free = ld.free_bytes()
            if free is not None and need + margin > free:
                raise DeviceError(f'not enough space on the device: the game data needs '
                                  f'{need / 1e9:.1f} GB and {free / 1e9:.1f} GB are free')
            log(f'game data: {len(todo)} file(s), {need / 1e9:.2f} GB\n')
            done = 0
            for p in todo:
                parent = f'{base}/{p}'.rsplit('/', 1)[0]
                afc.makedirs(parent)

                def step(n: int, _p=p) -> None:
                    nonlocal done
                    done += n
                    if progress:
                        progress(done, need)
                afc.put(Path(folder) / p, f'{base}/{p}', step, cancelled)
                log(f'game data: {p}\n')
            return len(todo), need
        finally:
            afc.close()


def describe(device: Device) -> Device:
    """`device` with its name and iOS version read from the device (empty when it is not paired yet)."""
    try:
        with Lockdown(device, timeout=8) as ld:
            device.name = ld.name()
            try:
                device.ios = str(ld.get_value('ProductVersion') or '')
            except DeviceError:
                device.ios = ''
    except DeviceError:
        pass
    return device


def developer_mode(device: Device) -> bool | None:
    """Whether Developer Mode is on, None when the device does not say (iOS 15 and earlier have
    none). A development-signed app, which a free Apple ID makes, opens only with it on."""
    with Lockdown(device, timeout=8) as ld:
        try:
            v = ld.get_value('DeveloperModeStatus', AMFI_DOMAIN)
        except DeviceError:
            return None
    return bool(v) if v is not None else None


def reveal_developer_mode(device: Device) -> None:
    """Make the Developer Mode switch appear in Settings, Privacy & Security. iOS hides it until a
    development tool asks for it: Xcode does when a device is plugged into a Mac, which is why the
    switch was there on a Mac and not from Windows. Turning it on stays the player's (iOS restarts
    and asks for the passcode)."""
    with Lockdown(device, timeout=8) as ld:
        amfi = ld.service(AMFI)
        try:
            r = amfi.request({'action': AMFI_REVEAL})
        finally:
            amfi.close()
    if r.get('Error') or not r.get('success', False):
        raise DeviceError(f'the device did not show the Developer Mode switch: {r.get("Error") or r}')


def find_shell(device: Device, preferred: str = '') -> str:
    """The shared app's bundle ID on the device: `preferred` when installed, else the first one
    whose executable is DmShell, else ''."""
    with Lockdown(device) as ld:
        found = shell_bundles(installed_apps(ld))
    if preferred and preferred in found:
        return preferred
    return found[0] if found else ''
