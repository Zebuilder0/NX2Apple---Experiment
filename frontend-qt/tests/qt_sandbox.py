"""Imported first by every test that builds the Model, the window or the library: a test run never reads or writes the
player's own settings, library or artwork, and never downloads banners.

The app keeps its state in one folder (library.default_state_dir: NSPB_STATE_DIR when set) and its settings beside it
(model.app_settings). This points both at a temporary folder for the whole run. The app itself has no test switch:
before, it treated the offscreen Qt platform as "a test" and then skipped saving the player's choices, so the tests
never ran that code.

    import qt_sandbox  # noqa: F401  (first, before nspb_qt is imported)
"""
from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
STATE_DIR = os.environ.setdefault('NSPB_STATE_DIR', tempfile.mkdtemp(prefix='nspb-tests-'))
# The per-user folders the Windows code paths write to (the shim and tools under %LOCALAPPDATA%, Impactor's session under
# %APPDATA%, its Linux/macOS twin under XDG_CONFIG_HOME): a test that runs them with the Windows branch switched on, or on
# a real Windows PC, writes into the sandbox, never into the player's own folders. A test that needs other values sets them.
for _var in ('LOCALAPPDATA', 'APPDATA', 'XDG_CONFIG_HOME'):
    os.environ[_var] = os.path.join(STATE_DIR, _var.lower())

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from nspb_qt import library as _library   # noqa: E402

_library.ArtworkStore.fetch_online = False   # banners come from the eShop: no network in a test

# Each Model a test builds gets settings of its own, empty: a choice one test saves (Play on, the output folder) must
# not be the next test's starting point. A test that checks what a restart keeps passes its own QSettings.
try:
    from nspb_qt import model as _model
except ImportError:              # no PySide6 (or no Qt libraries): the window tests skip themselves
    pass
else:
    import itertools
    _count = itertools.count()

    def _own_settings():
        # model.QSettings looked up at each call: a test that patches it (a dict of its own, an ini of its own) keeps
        # getting what it patched in
        qs = _model.QSettings
        return qs(str(Path(STATE_DIR) / f'settings-{next(_count)}.ini'), getattr(qs, 'IniFormat', None))
    _model.app_settings = _own_settings
