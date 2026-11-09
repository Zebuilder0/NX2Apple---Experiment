"""The game library's file (library.json): a damaged file is kept aside instead of being overwritten, saves are whole
even from several threads, a game without a title ID is not recorded under a made-up one, and the IPA a build wrote is
found by its title ID. No PySide6, no Model, no window: every library lives in a temporary folder.

    python3 -m unittest frontend-qt/tests/test_library_store.py -v
"""
from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'frontend-qt'))

from nspb_qt import library as lib   # noqa: E402


def game(tid: str = '0100000000010000') -> lib.LibraryGame:
    return lib.LibraryGame(title_id=tid, name='Zelda', ipa_path='', archive_path='', output_dir='', inputs={})


class LibraryFile(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.logged: list[str] = []

    def kept(self) -> list[Path]:
        return sorted(p for p in self.dir.iterdir() if p.name.startswith('library.json.bad-'))

    def test_a_damaged_file_is_kept_aside_not_overwritten(self) -> None:
        f = self.dir / 'library.json'
        f.write_text('{"games": [{"titleID": "0100000000010000"', encoding='utf-8')   # cut off mid-write
        library = lib.GameLibrary(self.dir, log=self.logged.append)
        self.assertEqual(library.games, [])
        self.assertIn('could not be read', library.load_problem)
        kept = self.kept()
        self.assertEqual(len(kept), 1)
        self.assertIn(kept[0].name, library.load_problem)
        self.assertEqual(kept[0].read_text(encoding='utf-8'), '{"games": [{"titleID": "0100000000010000"')
        self.assertEqual(self.logged, [library.load_problem + '\n'], 'the launcher log says where the file went')
        library.upsert(game())
        self.assertEqual(len(json.loads(f.read_text(encoding='utf-8'))['games']), 1)
        self.assertTrue(kept[0].exists(), 'the damaged file was replaced by the new save')

    def test_a_file_that_is_not_a_library_is_kept_aside_too(self) -> None:
        for text in ('null', '42', '{"games": 7}', '{"games": [{"titleID": "0100000000010000", "addedAt": "soon"}]}'):
            with self.subTest(text):
                for p in self.dir.iterdir():
                    p.unlink()
                (self.dir / 'library.json').write_text(text, encoding='utf-8')
                library = lib.GameLibrary(self.dir)
                self.assertIn('could not be read', library.load_problem)
                self.assertEqual([p.read_text(encoding='utf-8') for p in self.kept()], [text])

    def test_a_file_that_cannot_be_moved_aside_is_not_written_over(self) -> None:
        f = self.dir / 'library.json'
        f.write_text('{"games": [', encoding='utf-8')
        real_replace = os.replace

        def locked(src, dst):                    # Windows: another program holds the damaged file open
            if Path(src) == f:
                raise PermissionError(13, 'The process cannot access the file')
            return real_replace(src, dst)
        with mock.patch.object(lib.os, 'replace', side_effect=locked):
            library = lib.GameLibrary(self.dir)
            self.assertIn('could not be moved aside', library.load_problem)
            library.upsert(game())
            self.assertEqual(f.read_text(encoding='utf-8'), '{"games": [', 'a save wrote over the unreadable file')
        library.upsert(game('0100000000020000'))   # once it can be moved, it is kept aside and the save goes ahead
        self.assertEqual([p.read_text(encoding='utf-8') for p in self.kept()], ['{"games": ['])
        self.assertEqual(len(json.loads(f.read_text(encoding='utf-8'))['games']), 2)

    def test_saves_are_whole_even_from_several_threads(self) -> None:
        library = lib.GameLibrary(self.dir)
        tids = [f'01000000000{n:02d}000' for n in range(20)]
        start = threading.Barrier(len(tids))

        def add(t: str) -> None:
            start.wait()
            library.upsert(game(t))
        threads = [threading.Thread(target=add, args=(t,)) for t in tids]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        on_disk = json.loads((self.dir / 'library.json').read_text(encoding='utf-8'))
        self.assertEqual(sorted(g['titleID'] for g in on_disk['games']), sorted(tids))
        self.assertEqual([p.name for p in self.dir.iterdir() if p.name.endswith('.tmp')], [])
        again = lib.GameLibrary(self.dir)
        self.assertEqual(again.load_problem, '')
        self.assertEqual(len(again.games), 20)

    def test_the_swift_fields_survive_the_atomic_save(self) -> None:
        payload = {'folder': '/Users/test/Games', 'libraryVersion': 3,
                   'games': [{'id': 'B6F6DB62-D0D5-47A2-941D-BA37A1CFCA0C', 'titleID': '0100E65002BB8000',
                              'name': 'Stardew Valley', 'lastTarget': 'iPhone / iPad'}]}
        (self.dir / 'library.json').write_text(json.dumps(payload), encoding='utf-8')
        library = lib.GameLibrary(self.dir)
        library.upsert(lib.LibraryGame(title_id='0100E65002BB8000', name='Stardew Valley'))
        saved = json.loads((self.dir / 'library.json').read_text(encoding='utf-8'))
        self.assertEqual(saved['folder'], '/Users/test/Games')
        self.assertEqual(saved['libraryVersion'], 3)
        self.assertEqual(saved['games'][0]['id'], 'B6F6DB62-D0D5-47A2-941D-BA37A1CFCA0C')
        self.assertEqual(saved['games'][0]['lastTarget'], 'iPhone / iPad')


class LibraryRecords(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir, True)

    def test_a_game_without_a_title_id_is_not_recorded_under_a_made_up_one(self) -> None:
        logged: list[str] = []
        library = lib.GameLibrary(self.dir / 'state', log=logged.append)
        for base in ('/x/game.nsp', '/x/other game.nsp'):
            self.assertIsNone(library.record_completed_ios(ipa_path='', archive_path='', base_path=base,
                                                           output_dir='', inputs={'base': [base]}))
        self.assertEqual(library.games, [])
        self.assertFalse(any(g.title_id == '0100000000000000' for g in lib.GameLibrary(self.dir / 'state').games))
        self.assertEqual(len(logged), 2)
        self.assertIn('game.nsp was not added to the library: no title ID', logged[0])

    def test_a_game_with_a_title_id_is_still_recorded(self) -> None:
        library = lib.GameLibrary(self.dir / 'state')
        g = library.record_completed_ios(ipa_path='', archive_path='', base_path='/x/Zelda [0100000000010000][v0].nsp',
                                         output_dir='', inputs={})
        self.assertIsNotNone(g)
        self.assertEqual(g.title_id, '0100000000010000')

    def test_the_ipa_a_build_wrote_is_found_by_its_title_id(self) -> None:
        out = self.dir / 'out'
        out.mkdir()
        (out / '0100000000010000.ipa').write_bytes(b'PK')
        library = lib.GameLibrary(self.dir / 'state')
        g = library.remember_inputs(base_path=str(self.dir / 'Zelda [0100000000010000][v0].nsp'), update_path='',
                                    dlc_paths=[], keys_path='', output_dir=str(out))
        self.assertEqual(g.ipa_path, str(out / '0100000000010000.ipa'))

    def test_an_ipa_named_after_the_game_is_still_found(self) -> None:
        out = self.dir / 'out'
        out.mkdir()
        (out / 'Zelda.ipa').write_bytes(b'PK')
        library = lib.GameLibrary(self.dir / 'state')
        g = library.remember_inputs(base_path=str(self.dir / 'Zelda [0100000000010000][v0].nsp'), update_path='',
                                    dlc_paths=[], keys_path='', output_dir=str(out))
        self.assertEqual(g.ipa_path, str(out / 'Zelda.ipa'))


if __name__ == '__main__':
    unittest.main()
