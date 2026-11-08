"""The signing tool of the Windows launcher: Impactor's `plumesign`, run as a separate program.

The launcher never sees the player's Apple ID password. The player signs in once in
`plumesign`'s own console window (`plumesign account login`, with the password hidden), and
Impactor keeps the session in `%APPDATA%\\PlumeImpactor`. Each install is then one command:

    plumesign sign --package <DmShell.app> --apple-id --udid <device> --register-and-install

which signs the shared app and every game framework in it with the player's free (or paid)
Apple ID, registers the device, asks Apple for the Increased Memory Limit the app's executable
requests, and installs the app over USB. Saves and game data stay: the bundle ID is the same
each time (`org.nxnative.shell.<team ID>`).

The bundled `plumesign.exe` is built by `build-qt.yml` from a pinned Impactor commit with
`frontend-qt/impactor/hardening.patch` (certificate checks on, a hidden password prompt, no
debug log by default). See `frontend-qt/impactor/README.md`.
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

EXE = 'plumesign.exe' if os.name == 'nt' else 'plumesign'

#: How long one sign-and-install may take (a big shared app over a slow cable).
SIGN_TIMEOUT = 40 * 60
#: After the tool exits, how long its last output may take to arrive (a program it started may still hold the pipe).
OUTPUT_GRACE = 10


def end_tree(p: subprocess.Popen) -> None:
    """End the tool and every program it started: taskkill /T on Windows, the process group elsewhere (sign_and_install
    starts it in its own). A plain kill left a child holding the output pipe, and the run waited for it."""
    try:
        if os.name == 'nt':
            subprocess.run(['taskkill', '/F', '/T', '/PID', str(p.pid)], capture_output=True, timeout=30, **_no_window())
        else:
            import signal
            os.killpg(p.pid, signal.SIGKILL)
    except (OSError, subprocess.SubprocessError):
        pass
    try:
        p.kill()
    except OSError:
        pass


def data_dir() -> Path:
    """Where Impactor keeps its session and keys (the same folder its desktop app uses)."""
    if os.name == 'nt':
        return Path(os.environ.get('APPDATA') or Path.home() / 'AppData' / 'Roaming') / 'PlumeImpactor'
    base = os.environ.get('XDG_CONFIG_HOME') or str(Path.home() / '.config')
    return Path(base) / 'PlumeImpactor'


def candidates() -> list[Path]:
    """Where the bundled signer may be, most specific first."""
    out: list[Path] = []
    if env := os.environ.get('NSPB_PLUMESIGN'):
        out.append(Path(env))
    meipass = getattr(sys, '_MEIPASS', None)
    if meipass:
        out += [Path(meipass) / 'tools' / EXE, Path(meipass).parent / 'tools' / EXE]
    exe_dir = Path(sys.executable).resolve().parent
    out += [exe_dir / 'tools' / EXE, exe_dir / '_internal' / 'tools' / EXE]
    try:
        from . import toolchain as tc
        out.append(tc.tools_dir() / 'plumesign' / EXE)
    except Exception:
        pass
    if found := shutil.which('plumesign'):
        out.append(Path(found))
    return out


def find() -> Path | None:
    for p in candidates():
        if p.is_file():
            return p
    return None


def child_env() -> dict[str, str]:
    """The signer's environment: info-level output only (its debug log prints the developer
    services' replies), no colours in the log."""
    env = dict(os.environ)
    env['RUST_LOG'] = 'info'
    env['NO_COLOR'] = '1'
    env['CLICOLOR'] = '0'
    return env


def _run(exe: Path, args: list[str], timeout: float = 60) -> tuple[int, str]:
    try:
        r = subprocess.run([str(exe), *args], capture_output=True, text=True, encoding='utf-8',
                           errors='replace', env=child_env(), stdin=subprocess.DEVNULL, timeout=timeout,
                           **_no_window())
    except (OSError, subprocess.SubprocessError) as e:
        return -1, str(e)
    return r.returncode, (r.stdout or '') + (r.stderr or '')


def _no_window() -> dict:
    if os.name == 'nt':
        return {'creationflags': getattr(subprocess, 'CREATE_NO_WINDOW', 0x08000000)}
    return {}


def works(exe: Path | None = None) -> bool:
    exe = exe or find()
    if not exe:
        return False
    code, out = _run(exe, ['--help'], timeout=30)
    return code == 0 and 'sign' in out


# ---------------------------------------------------------------- the account

_SELECTED = re.compile(r'\[[^\]]*\]\s+(\S+@\S+)\s+\(selected\)')


@dataclass
class Account:
    signed_in: bool
    email: str = ''          # the selected Apple ID, for display only (masked by `masked()`)
    error: str = ''          # why the check could not tell


def account(exe: Path | None = None) -> Account:
    """Whether Impactor has a selected Apple ID, from `plumesign account list` (the launcher
    does not read Impactor's files)."""
    exe = exe or find()
    if not exe:
        return Account(False, error='no signer')
    code, out = _run(exe, ['account', 'list'])
    if code != 0:
        return Account(False, error=redact(out.strip().splitlines()[-1] if out.strip() else f'exit {code}'))
    m = _SELECTED.search(out)
    return Account(bool(m), m.group(1) if m else '')


def masked(email: str) -> str:
    """`j…@gmail.com`: enough to recognise the account, not enough to copy it into a bug report."""
    if '@' not in email:
        return email
    user, host = email.split('@', 1)
    return (user[:1] + '…' if user else '') + '@' + host


def login_console(exe: Path | None = None) -> subprocess.Popen | None:
    """Open `plumesign account login` in its own console window, where the player types the
    Apple ID, the password (hidden) and the two-factor code. The window stays open at the end so
    the result can be read. Returns the process, which ends when the window closes."""
    exe = exe or find()
    if not exe:
        return None
    if os.name == 'nt':
        line = login_command_line(exe, os.environ.get('ComSpec') or 'cmd.exe')
        return subprocess.Popen(line, env=child_env(),
                                creationflags=getattr(subprocess, 'CREATE_NEW_CONSOLE', 0x10))
    return subprocess.Popen([str(exe), 'account', 'login'], env=child_env())   # a terminal run (tests, not the Windows app)


def login_command_line(exe: Path, comspec: str = 'cmd.exe') -> str:
    """The sign-in window's command line: cmd runs `plumesign account login`, then waits for a key
    so the result can be read. It is one string, which Windows gets as it is. A list made Python
    escape the quotes around the path as \\", cmd took them for part of the name, and a path with
    a space ("NX2Apple-windows-x64 (2)") was "not recognized as an internal or external command".
    /s makes cmd remove only the outer pair of quotes after /c, so the path keeps its own."""
    return f'"{comspec}" /d /s /c ""{exe}" account login & echo. & pause"'


def logout(exe: Path | None = None) -> tuple[bool, str]:
    """`plumesign account logout`: removes the selected Apple ID and its session token."""
    exe = exe or find()
    if not exe:
        return False, 'no signer'
    code, out = _run(exe, ['account', 'logout'])
    return code == 0, redact(out.strip())


# ---------------------------------------------------------------- sign and install

def sign_command(exe: Path, app: Path, device_id: int | str) -> list[str]:
    """`--udid` takes usbmuxd's device number, not the UDID its name says: plumesign looks the
    device up with `d.device_id.to_string() == device_id` (plume_utils get_device_for_id), and a
    UDID stopped with "Device ID ... not found". The number is the one usbmuxd gives the connected
    device now (it changes when the device is plugged in again), so it is read just before."""
    return [str(exe), 'sign', '--package', str(app), '--apple-id', '--udid', str(device_id),
            '--register-and-install']


_PROGRESS = re.compile(r'Installation progress:\s*(\d+)%')

#: Signer output → what the player does about it (keys of en.json).
FAILURES = (
    ('No account selected', 'win.sign.fail.noAccount'),
    ('not a terminal', 'win.sign.fail.teams'),
    ('NotTerminal', 'win.sign.fail.teams'),
    ('No devices connected', 'win.sign.fail.noDevice'),
    ('Device not found', 'win.sign.fail.noDevice'),
    (re.compile(r'Device ID \S+ not found'), 'win.sign.fail.noDevice'),   # plumesign's get_device_for_id
    ('PasswordProtected', 'win.sign.fail.locked'),
    ('maximum number of', 'win.sign.fail.limit'),
    ('anisette', 'win.sign.fail.network'),
    ('error sending request', 'win.sign.fail.network'),
    ('dns error', 'win.sign.fail.network'),
    (re.compile(r'\b401\b'), 'win.sign.fail.session'),
    ('Unauthorized', 'win.sign.fail.session'),
)


def classify(output: str) -> str:
    """The en.json key that explains a failed sign-and-install, '' when nothing matches."""
    low = output.lower()
    for needle, key in FAILURES:
        if needle.search(output) if isinstance(needle, re.Pattern) else needle.lower() in low:
            return key
    return ''


@dataclass
class Result:
    ok: bool
    output: str = ''
    failure: str = ''     # an en.json key from FAILURES, '' when unknown


def sign_and_install(app: Path, device_id: int | str, *, log: Callable[[str], None] = lambda s: None,
                     progress: Callable[[int], None] | None = None,
                     started: Callable[[subprocess.Popen], None] | None = None,
                     exe: Path | None = None) -> Result:
    """Sign `app` (a folder, in place) with the selected Apple ID and install it on the device
    usbmuxd numbers `device_id` (see sign_command).
    stdin is closed, so a question the signer would ask (an Apple ID with several teams) fails
    at once instead of waiting forever. Every output line goes to `log`, redacted."""
    exe = exe or find()
    if not exe:
        return Result(False, 'the signing tool (plumesign) is missing', 'win.sign.fail.missing')
    cmd = sign_command(exe, app, device_id)
    log('$ plumesign sign --package <shared app> --apple-id --udid <device> --register-and-install\n')
    try:
        # its own process group on macOS and Linux (the tests' pretend signer): the time limit ends it with whatever it
        # started. Windows ends the tree with taskkill /T (end_tree).
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             stdin=subprocess.DEVNULL, text=True, encoding='utf-8',
                             errors='replace', env=child_env(), start_new_session=os.name != 'nt', **_no_window())
    except OSError as e:
        return Result(False, str(e), 'win.sign.fail.missing')
    if started:
        started(p)
    # The output is read on a thread of its own and the limit is a wait on the process: reading in this thread ends only
    # when every holder of the pipe has closed it, which a hung tool never does (the old wait after the read loop never
    # got the chance to time out), and which a program the tool started can keep from happening after the tool is ended.
    tail: list[str] = []
    assert p.stdout is not None

    def read() -> None:
        nonlocal tail
        try:
            for line in p.stdout:
                clean = redact(line.rstrip('\n'))
                tail = (tail + [clean])[-60:]
                log(clean + '\n')
                if progress and (m := _PROGRESS.search(line)):
                    progress(int(m.group(1)))
        except (OSError, ValueError):
            pass                      # the pipe was closed under the reader: the run is over
    reader = threading.Thread(target=read, daemon=True)
    reader.start()
    try:
        p.wait(timeout=SIGN_TIMEOUT)
    except subprocess.TimeoutExpired:
        end_tree(p)
        reader.join(5)
        return Result(False, 'the signing tool did not finish in time', 'win.sign.fail.network')
    reader.join(OUTPUT_GRACE)         # what the tool wrote before it exited; not forever if a child keeps the pipe
    out = '\n'.join(tail)
    ok = p.returncode == 0 and 'Installation complete' in out
    return Result(ok, out, '' if ok else classify(out))


# ---------------------------------------------------------------- the log

_EMAIL = re.compile(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}')
_UDID = re.compile(r'\b(?:[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9a-fA-F]{40})\b')
_TEAM = re.compile(r'\b(?=[A-Z0-9]*\d)(?=[A-Z0-9]*[A-Z])[A-Z0-9]{10}\b')
_TOKEN = re.compile(r'(?i)(token|adsid|password|secret)(["\']?\s*[:=]\s*["\']?)[^\s"\',}]+')


def redact(text: str) -> str:
    """The signer's output without what identifies the player: Apple ID emails, device UDIDs,
    team IDs and anything that looks like a token. Applied to the log and the diagnostics."""
    text = _TOKEN.sub(lambda m: m.group(1) + m.group(2) + '<hidden>', text)
    text = _EMAIL.sub('<apple id>', text)
    text = _UDID.sub('<device>', text)
    return _TEAM.sub('<team>', text)
