"""A pretend iPhone behind a pretend usbmuxd, for the tests of nspb_qt/win/device.py and install.py.

One TCP server plays usbmuxd (point NSPB_USBMUXD at it). After a `Connect` the connection is a
tunnel to the device: port 62078 is lockdownd (with TLS after StartSession when `tls` is set),
the ports StartService hands out are house_arrest (AFC on an in-memory file system) and
installation_proxy (Browse). Only what the client uses is implemented, framed as Apple frames it.
"""
from __future__ import annotations

import plistlib
import socket
import socketserver
import ssl
import struct
import subprocess
import tempfile
import threading
from pathlib import Path

LOCKDOWN = 62078
HOUSE_ARREST_PORT = 49001
INSTPROXY_PORT = 49002
AFC_HEADER = struct.Struct('<8sQQQQ')


def make_cert(folder: Path) -> tuple[bytes, bytes] | None:
    """A throwaway self-signed certificate and key (PEM) made with openssl, or None without it."""
    key, crt = folder / 'k.pem', folder / 'c.pem'
    try:
        r = subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-subj', '/CN=test',
                            '-days', '1', '-keyout', str(key), '-out', str(crt)], capture_output=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode or not key.is_file():
        return None
    return crt.read_bytes(), key.read_bytes()


def _exact(sock, n: int) -> bytes:
    buf = b''
    while len(buf) < n:
        c = sock.recv(n - len(buf))
        if not c:
            raise EOFError
        buf += c
    return buf


class FakeDevice:
    def __init__(self, *, udid='00008110-001A2B3C4D5E801E', name='Test iPhone', paired=True,
                 tls: tuple[bytes, bytes] | None = None, free=50_000_000_000, locked=False):
        self.udid, self.name, self.paired, self.tls, self.free, self.locked = udid, name, paired, tls, free, locked
        self.apps: dict[str, dict] = {}
        self.files: dict[str, bytes] = {}          # AFC paths of the vended container
        self.dirs: set[str] = {'/', '/Documents'}
        self.vended: list[str] = []
        self.lock = threading.Lock()
        dev = self

        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                try:
                    dev._mux(self.request)
                except (EOFError, ConnectionError, OSError, ssl.SSLError):
                    pass

        self.server = socketserver.ThreadingTCPServer(('127.0.0.1', 0), Handler)
        self.server.daemon_threads = True
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()

    @property
    def address(self) -> str:
        return f'127.0.0.1:{self.port}'

    # ---- usbmuxd
    def _mux(self, s):
        while True:
            size, _v, msg, tag = struct.unpack('<IIII', _exact(s, 16))
            req = plistlib.loads(_exact(s, size - 16))
            mt = req.get('MessageType')
            if mt == 'ListDevices':
                reply = {'DeviceList': [{'DeviceID': 7, 'MessageType': 'Attached', 'Properties': {
                    'SerialNumber': self.udid, 'ConnectionType': 'USB', 'DeviceID': 7}}]}
            elif mt == 'ReadPairRecord':
                if not self.paired or req.get('PairRecordID') != self.udid:
                    reply = {'MessageType': 'Result', 'Number': 2}
                else:
                    cert, key = self.tls or (b'-----BEGIN CERTIFICATE-----\n', b'-----BEGIN PRIVATE KEY-----\n')
                    rec = {'HostID': 'HOST', 'SystemBUID': 'BUID', 'HostCertificate': cert, 'HostPrivateKey': key}
                    reply = {'PairRecordData': plistlib.dumps(rec)}
            elif mt == 'Connect':
                port = socket.ntohs(req['PortNumber'])
                self._send_mux(s, tag, {'MessageType': 'Result', 'Number': 0})
                self._tunnel(s, port)
                return
            else:
                reply = {'MessageType': 'Result', 'Number': 1}
            self._send_mux(s, tag, reply)

    @staticmethod
    def _send_mux(s, tag, d):
        body = plistlib.dumps(d)
        s.sendall(struct.pack('<IIII', 16 + len(body), 1, 8, tag) + body)

    def _tunnel(self, s, port):
        if port == LOCKDOWN:
            self._lockdown(s)
        elif port == HOUSE_ARREST_PORT:
            self._house_arrest(s)
        elif port == INSTPROXY_PORT:
            self._instproxy(s)

    # ---- plist service framing
    @staticmethod
    def _recv(s) -> dict:
        (n,) = struct.unpack('>I', _exact(s, 4))
        return plistlib.loads(_exact(s, n))

    @staticmethod
    def _send(s, d):
        b = plistlib.dumps(d)
        s.sendall(struct.pack('>I', len(b)) + b)

    def _server_tls(self, s):
        if not self.tls:
            return s
        with tempfile.NamedTemporaryFile('wb', suffix='.pem', delete=False) as f:
            f.write(self.tls[0] + b'\n' + self.tls[1])
            path = f.name
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(path)
        Path(path).unlink()
        return ctx.wrap_socket(s, server_side=True)

    def _lockdown(self, s):
        try:
            self._lockdown_loop(s)
        except (EOFError, ConnectionError, OSError, ssl.SSLError):
            pass

    def _lockdown_loop(self, s):
        opened = [s]       # the plain socket, then the TLS one: the last is closed at the end
        try:
            self._lockdown_requests(s, opened)
        finally:
            opened[-1].close()

    def _lockdown_requests(self, s, opened):
        while True:
            req = self._recv(s)
            r = req.get('Request')
            if r == 'QueryType':
                self._send(s, {'Request': r, 'Type': 'com.apple.mobile.lockdown'})
            elif r == 'StartSession':
                ok = req.get('HostID') == 'HOST'
                self._send(s, {'Request': r, 'SessionID': 'S', 'EnableSessionSSL': bool(self.tls)} if ok
                           else {'Request': r, 'Error': 'InvalidHostID'})
                if ok:
                    s = self._server_tls(s)
                    opened.append(s)
            elif r == 'GetValue':
                if req.get('Key') == 'DeviceName':
                    self._send(s, {'Request': r, 'Value': self.name})
                elif req.get('Key') == 'AmountDataAvailable':
                    self._send(s, {'Request': r, 'Value': self.free})
                else:
                    self._send(s, {'Request': r, 'Error': 'MissingValue'})
            elif r == 'StartService':
                if self.locked:
                    self._send(s, {'Request': r, 'Error': 'PasswordProtected'})
                    continue
                port = {'com.apple.mobile.house_arrest': HOUSE_ARREST_PORT,
                        'com.apple.mobile.installation_proxy': INSTPROXY_PORT}.get(req.get('Service'))
                self._send(s, {'Request': r, 'Port': port, 'EnableServiceSSL': False} if port
                           else {'Request': r, 'Error': 'InvalidService'})
            elif r == 'StopSession':
                self._send(s, {'Request': r})
                return

    def _instproxy(self, s):
        req = self._recv(s)
        assert req['Command'] == 'Browse'
        with self.lock:
            apps = list(self.apps.values())
        self._send(s, {'Status': 'BrowsingApplications', 'CurrentList': apps})
        self._send(s, {'Status': 'Complete'})

    def _house_arrest(self, s):
        req = self._recv(s)
        if req.get('Command') != 'VendDocuments' or req.get('Identifier') not in self.apps:
            self._send(s, {'Error': 'ApplicationLookupFailed'})
            return
        self.vended.append(req['Identifier'])
        self._send(s, {'Status': 'Complete'})
        handles: dict[int, str] = {}
        while True:
            magic, whole, this, num, op = AFC_HEADER.unpack(_exact(s, AFC_HEADER.size))
            assert magic == b'CFA6LPAA'
            data = _exact(s, this - AFC_HEADER.size)
            payload = _exact(s, whole - this)
            status, body, rop = 0, b'', 1

            def path(b: bytes) -> str:
                return b.split(b'\0')[0].decode()
            with self.lock:
                if op == 0x0A:      # GET_FILE_INFO
                    p = path(data)
                    if p in self.files:
                        rop, body = 2, b'st_size\0%d\0st_ifmt\0S_IFREG\0' % len(self.files[p])
                    elif p in self.dirs:
                        rop, body = 2, b'st_size\0 0\0st_ifmt\0S_IFDIR\0'
                    else:
                        status = 4          # a real device answers GetFileInfo on a missing path with READ_ERROR
                elif op == 0x09:    # MAKE_DIR
                    p = path(data)
                    parts = p.strip('/').split('/')
                    for i in range(1, len(parts) + 1):
                        self.dirs.add('/' + '/'.join(parts[:i]))
                elif op == 0x0D:    # FILE_OPEN
                    mode = struct.unpack_from('<Q', data)[0]
                    p = path(data[8:])
                    assert mode == 3
                    if p.rsplit('/', 1)[0] not in self.dirs:
                        status = 8
                    else:
                        h = len(handles) + 1
                        handles[h] = p
                        self.files[p] = b''
                        rop, body = 0x0E, struct.pack('<Q', h)
                elif op == 0x10:    # WRITE
                    assert this == 48
                    h = struct.unpack_from('<Q', data)[0]
                    self.files[handles[h]] += payload
                elif op == 0x14:    # FILE_CLOSE
                    handles.pop(struct.unpack_from('<Q', data)[0], None)
                elif op == 0x08:    # REMOVE_PATH
                    p = path(data)
                    if p in self.files:
                        del self.files[p]
                    else:
                        status = 8
                elif op == 0x18:    # RENAME_PATH
                    a, b = data.split(b'\0')[:2]
                    self.files[b.decode()] = self.files.pop(a.decode())
                else:
                    status = 1
            if rop == 1:
                body = struct.pack('<Q', status)
            s.sendall(AFC_HEADER.pack(b'CFA6LPAA', AFC_HEADER.size + len(body), AFC_HEADER.size + len(body), num, rop) + body)
