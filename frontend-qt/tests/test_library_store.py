"""The game library's file (library.json): a damaged file is kept aside instead of being overwritten, saves are whole
even from several threads, a game without a title ID is not recorded under a made-up one, and the IPA a build wrote is
found by its title ID. The banners (ArtworkStore): only an image from the Mac's image hosts is saved. No PySide6, no
Model, no window, no network: every library and artwork folder lives in a temporary folder.

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

sys.path.insert(0, str(Path(__file__).resolve().parent))
import qt_sandbox  # noqa: E402,F401  (first: the tests never touch the player's settings or state)

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


class BannerDownloadTests(unittest.TestCase):
    """A banner is saved only when it is an image from one of the image hosts: it is shown as the game's picture and
    never fetched again once a file is there, so anything else saved would stay broken for good."""

    TID = '0400486024DEC000'   # has a fallback banner on cdn2.steamgriddb.com

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.updated: list[str] = []
        self.store = lib.ArtworkStore(state_dir=self.tmp / 'art', on_updated=self.updated.append)
        self.store.banners_dir.mkdir(parents=True)
        # a title list is already saved, so the test never asks the network for one
        (self.store.banners_dir / 'banners_index.json').write_text('{"0000000000000001": "x"}', encoding='utf-8')
        self.urls: list[str] = []
        self.reads: list[int] = []

    def fetch(self, body: bytes, status: int = 200, tid: str = TID, final_url: str | None = None) -> None:
        test = self

        class Resp:
            def __init__(self) -> None:
                self.status = status
                if final_url is not None:
                    self.url = final_url        # where urllib ended up after the redirects

            def read(self, n: int = -1) -> bytes:
                test.reads.append(n)
                return body if n < 0 else body[:n]

            def __enter__(self) -> Resp:
                return self

            def __exit__(self, *a: object) -> None:
                pass

        def urlopen(req, timeout=15):
            self.urls.append(req.full_url)
            return Resp()

        with mock.patch('urllib.request.urlopen', side_effect=urlopen):
            self.store._fetch_one(tid)

    def saved(self) -> list[str]:
        return sorted(p.name for p in self.store.banners_dir.iterdir() if p.name != 'banners_index.json')

    def asking_online(self) -> None:
        """The tests' sandbox turns banner downloads off (ArtworkStore.fetch_online, qt_sandbox.py). These tests ask for
        the download itself, so this store may fetch (the network is mocked)."""
        self.store.fetch_online = True

    def test_an_error_page_is_not_saved_as_the_banner(self) -> None:
        self.fetch(b'<!DOCTYPE html><html><body>' + b'Sign in to the network ' * 200 + b'</body></html>')
        self.assertEqual(self.saved(), [])
        self.assertEqual(self.updated, [])
        self.assertIsNone(self.store.image_path(self.TID))

    def test_an_image_with_an_error_status_is_not_saved(self) -> None:
        self.fetch(b'\x89PNG\r\n\x1a\n' + b'P' * 4096, status=203)
        self.assertEqual(self.saved(), [])

    def test_a_png_and_a_jpeg_are_saved_whole_under_their_own_kind(self) -> None:
        png = b'\x89PNG\r\n\x1a\n' + b'P' * 4096
        self.fetch(png)
        self.assertEqual(self.saved(), [f'{self.TID}.png'])
        self.assertEqual((self.store.banners_dir / f'{self.TID}.png').read_bytes(), png)
        self.assertEqual(self.updated, [self.TID])
        jpg_tid = '0400E88025B1A000'
        self.fetch(b'\xff\xd8\xff\xe0' + b'J' * 4096, tid=jpg_tid)
        self.assertEqual(self.store.image_path(jpg_tid), str(self.store.banners_dir / f'{jpg_tid}.jpg'))

    def test_a_redirect_to_another_host_or_to_http_is_not_saved(self) -> None:
        """Audit 2, P12: only the first link was checked; urllib follows a redirect anywhere."""
        png = b'\x89PNG\r\n\x1a\n' + b'P' * 4096
        for final in ('https://example.com/banner.png', 'http://img-eshop.cdn.nintendo.net/i/a.png'):
            with self.subTest(final):
                self.fetch(png, final_url=final)
                self.assertEqual(self.saved(), [])
        self.fetch(png, final_url='https://img-eshop.cdn.nintendo.net/i/b.png')   # to an image host: kept
        self.assertEqual(self.saved(), [f'{self.TID}.png'])

    def test_a_tiny_image_is_not_saved(self) -> None:
        self.fetch(b'\x89PNG\r\n\x1a\n' + b'P' * 100)
        self.assertEqual(self.saved(), [])

    def test_the_download_is_read_only_up_to_the_limit(self) -> None:
        self.fetch(b'\x89PNG\r\n\x1a\n' + b'P' * (lib.ArtworkStore.MAX_BANNER_BYTES + 10))
        self.assertEqual(self.reads, [lib.ArtworkStore.MAX_BANNER_BYTES + 1])
        self.assertEqual(self.saved(), [])

    def test_a_banner_is_written_whole_or_not_at_all(self) -> None:
        with mock.patch.object(lib.os, 'replace', side_effect=OSError(28, 'No space left on device')):
            self.fetch(b'\x89PNG\r\n\x1a\n' + b'P' * 4096)
        self.assertEqual(self.saved(), [], 'a half-written banner or its .part file was left')
        self.assertEqual(self.updated, [])

    def test_a_link_to_another_host_or_over_http_is_not_downloaded(self) -> None:
        tid = '0100000000010000'
        for link in ('https://example.com/banner.jpg', 'http://img-eshop.cdn.nintendo.net/i/a.jpg',
                     'https://img-eshop.cdn.nintendo.net.example.com/a.jpg', 'file:///etc/passwd',
                     'https://img-eshop.cdn.nintendo.net@example.com/a.jpg'):
            with self.subTest(link):
                (self.store.banners_dir / 'banners_index.json').write_text(json.dumps({tid: link}), encoding='utf-8')
                self.fetch(b'\x89PNG\r\n\x1a\n' + b'P' * 4096, tid=tid)
                self.assertEqual(self.urls, [])
        (self.store.banners_dir / 'banners_index.json').write_text(
            json.dumps({tid: 'https://img-eshop.cdn.nintendo.net/i/a.jpg'}), encoding='utf-8')
        self.fetch(b'\xff\xd8\xff\xe0' + b'J' * 4096, tid=tid)
        self.assertEqual(self.urls, ['https://img-eshop.cdn.nintendo.net/i/a.jpg'])

    def test_a_page_an_older_launcher_saved_is_removed_and_fetched_again(self) -> None:
        bad = self.store.banners_dir / f'{self.TID}.jpg'
        bad.write_bytes(b'<html>' + b'x' * 4096)
        self.assertIsNone(self.store.image_path(self.TID))
        self.assertFalse(bad.exists())
        bad.write_bytes(b'<html>' + b'x' * 4096)      # and through the other way in: the banner request
        self.asking_online()
        with mock.patch.object(lib.threading, 'Thread') as thread:
            self.store.request_banner_async(self.TID)
        thread.assert_called_once()
        self.assertFalse(bad.exists())

    def test_a_saved_image_is_not_fetched_again(self) -> None:
        (self.store.banners_dir / f'{self.TID}.png').write_bytes(b'\x89PNG\r\n\x1a\n' + b'P' * 4096)
        self.asking_online()
        with mock.patch.object(lib.threading, 'Thread') as thread:
            self.store.request_banner_async(self.TID)
        thread.assert_not_called()
        self.assertEqual(self.store.image_path(self.TID), str(self.store.banners_dir / f'{self.TID}.png'))

    def test_the_image_hosts_are_the_macs(self) -> None:
        import re
        swift = (ROOT / 'frontend' / 'Sources' / 'NX2Apple' / 'Artwork.swift').read_text(encoding='utf-8')
        hosts = re.search(r'static let imageHosts: Set<String> = \[([^\]]*)\]', swift)
        self.assertIsNotNone(hosts)
        self.assertEqual(set(re.findall(r'"([^"]+)"', hosts.group(1))), set(lib.ArtworkStore.IMAGE_HOSTS))
        for url in lib.ArtworkStore.FALLBACK_BANNERS.values():
            self.assertTrue(self.store._allowed(url), url)


if __name__ == '__main__':
    unittest.main()
