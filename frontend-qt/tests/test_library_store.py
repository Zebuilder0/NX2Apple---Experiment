"""The game library (library.json and the games-folder scan): the newest update is the highest version, a damaged
file is kept aside instead of being overwritten, saves are whole, and a game without a title ID is not recorded under a
made-up one. No PySide6.

    python3 -m unittest frontend-qt/tests/test_library_store.py -v
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
import threading
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import qt_sandbox  # noqa: E402,F401  (first: the tests never touch the player's settings or state)
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'frontend-qt'))

from nspb_qt import library as lib   # noqa: E402


class GamesFolderScan(unittest.TestCase):
    def test_the_newest_update_is_the_highest_version_not_the_last_name(self):
        d = Path(tempfile.mkdtemp())
        for n in ('Zelda [0100000000010000][v0].nsp', 'Zelda [0100000000010800][v65536].nsp',
                  'Zelda [0100000000010800][v196608].nsp', 'Zelda [0100000000010800][v131072].nsp'):
            (d / n).write_bytes(b'')
        games = lib.GameLibrary.discover_in_folder(str(d))
        self.assertEqual(len(games), 1)
        self.assertEqual([os.path.basename(p) for p in games[0].inputs['update']],
                         ['Zelda [0100000000010800][v196608].nsp'])


class LibraryFile(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())

    def game(self, tid='0100000000010000'):
        return lib.LibraryGame(title_id=tid, name='Zelda', ipa_path='', archive_path='', output_dir='', inputs={})

    def test_a_damaged_file_is_kept_aside_not_overwritten(self):
        f = self.dir / 'library.json'
        f.write_text('{"games": [{"titleID": "0100000000010000"', encoding='utf-8')   # cut off mid-write
        library = lib.GameLibrary(self.dir)
        self.assertEqual(library.games, [])
        self.assertIn('could not be read', library.load_problem)
        kept = [p for p in self.dir.iterdir() if p.name.startswith('library.json.bad-')]
        self.assertEqual(len(kept), 1)
        self.assertTrue(kept[0].read_text(encoding='utf-8').startswith('{"games"'))
        library.upsert(self.game())
        self.assertEqual(len(json.loads(f.read_text(encoding='utf-8'))['games']), 1)
        self.assertTrue(kept[0].exists(), 'the damaged file was replaced by the new save')

    def test_saves_are_whole_even_from_several_threads(self):
        library = lib.GameLibrary(self.dir)
        tids = [f'01000000000{n:02d}000' for n in range(20)]

        def add(t):
            library.upsert(self.game(t))
        threads = [threading.Thread(target=add, args=(t,)) for t in tids]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        on_disk = json.loads((self.dir / 'library.json').read_text(encoding='utf-8'))
        self.assertEqual(len(on_disk['games']), 20)
        self.assertFalse((self.dir / 'library.json.tmp').exists())
        self.assertEqual(lib.GameLibrary(self.dir).load_problem, '')

    def test_a_game_without_a_title_id_is_not_recorded_under_a_made_up_one(self):
        library = lib.GameLibrary(self.dir)
        self.assertIsNone(library.record_completed_ios(ipa_path='', archive_path='', base_path='/x/game.nsp',
                                                       output_dir='', inputs={}))
        self.assertEqual(library.games, [])

    def test_the_ipa_a_build_wrote_is_found_by_its_title_id(self):
        out = self.dir / 'out'
        out.mkdir()
        (out / '0100000000010000.ipa').write_bytes(b'PK')
        library = lib.GameLibrary(self.dir)
        g = library.remember_inputs(base_path=str(self.dir / 'Zelda [0100000000010000][v0].nsp'), update_path='',
                                    dlc_paths=[], keys_path='', output_dir=str(out))
        self.assertEqual(g.ipa_path, str(out / '0100000000010000.ipa'))


class TestSandbox(unittest.TestCase):
    def test_every_test_that_builds_the_app_keeps_the_players_state_out_of_reach(self):
        """A test module that builds the Model, the window or the library imports qt_sandbox first: the app has no
        test switch of its own, so without it the test would write into the player's settings."""
        import re
        here = Path(__file__).resolve().parent
        builds = re.compile(r'\bModel\(|\bMainWindow\(|\bGameLibrary\(|\bArtworkStore\(')
        missing = [f.name for f in sorted(here.glob('test_*.py'))
                   if builds.search(f.read_text(encoding='utf-8')) and 'import qt_sandbox' not in f.read_text(encoding='utf-8')]
        self.assertEqual(missing, [])

    def test_the_sandbox_is_where_the_state_and_the_settings_go(self):
        self.assertEqual(str(lib.default_state_dir()), qt_sandbox.STATE_DIR)
        self.assertFalse(lib.ArtworkStore.fetch_online)


if __name__ == '__main__':
    unittest.main()
