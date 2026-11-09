"""Checks on .github/workflows/build-qt.yml (the Windows build) that need only the file, not PySide6."""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / '.github' / 'workflows' / 'build-qt.yml'


def _workflow() -> str:
    return WORKFLOW.read_text(encoding='utf-8')


def _job(wf: str, name: str) -> str:
    """The text of one top-level job (from '  name:' to the next job or the end)."""
    m = re.search(r'^  %s:\n(.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)' % re.escape(name), wf, re.S | re.M)
    assert m, f'job {name} not found'
    return m.group(1)


class BuildWorkflowTests(unittest.TestCase):
    def test_the_windows_build_installs_only_pinned_hashed_packages(self) -> None:
        wf = _workflow()
        self.assertIn('--require-hashes --only-binary=:all: -r frontend-qt/requirements-build-windows.txt', wf)
        self.assertNotIn('pip install PySide6-Essentials pyinstaller', wf)
        self.assertNotIn('pip install --upgrade pip', wf)
        reqs = (ROOT / 'frontend-qt' / 'requirements-build-windows.txt').read_text(encoding='utf-8')
        lines = [ln for ln in reqs.splitlines() if ln.strip() and not ln.startswith('#')]
        self.assertTrue(any(ln.startswith('pyside6-essentials==') for ln in lines))
        for ln in lines:
            self.assertRegex(ln, r'^[a-z0-9-]+==[\w.]+ --hash=sha256:[0-9a-f]{64}$')

    def test_the_windows_build_never_makes_a_final_release(self) -> None:
        """build-mac-app.yml writes the reviewed notes only into a release it creates: one made by the Windows build
        first would ship with a one-line body."""
        wf = _workflow()
        creates = [ln for ln in wf.splitlines() if 'gh release create' in ln]
        self.assertTrue(creates)
        self.assertTrue(all('--prerelease' in ln for ln in creates), creates)
        self.assertIn('persist-credentials: false   # the job holds contents: write', wf)

    def test_every_release_step_is_gated_on_a_tag(self) -> None:
        """A workflow_dispatch run on a branch must never reach a release."""
        wf = _workflow()
        for m in re.finditer(r'^      - name: Attach to the release\n(.*?)(?=^      - |\Z)', wf, re.S | re.M):
            self.assertIn("if: startsWith(github.ref, 'refs/tags/v')", m.group(1))
        self.assertEqual(len(re.findall(r'(?m)^\s*gh release upload', wf)), 1)
        self.assertEqual(wf.count('Attach to the release'), 1)

    def test_the_build_needs_plumesign_and_packages_tools_plumesign_exe(self) -> None:
        wf = _workflow()
        self.assertRegex(_job(wf, 'build'), r'(?m)^    needs: \[[^\]]*\bplumesign\b[^\]]*\]')
        self.assertIn('plumesign:', wf)
        self.assertIn('cargo build -p plumesign --release --locked --target x86_64-pc-windows-gnu', wf)
        self.assertIn('git -C impactor apply ../frontend-qt/impactor/hardening.patch', wf)
        self.assertIn('NX2Apple/tools/plumesign.exe', wf)
        self.assertIn('cp ../../artifacts/plumesign/plumesign.exe NX2Apple/tools/', wf)
        self.assertIn('Usage: plumesign', wf)

    def test_the_build_needs_the_shell_template(self) -> None:
        self.assertRegex(_job(_workflow(), 'build'), r'(?m)^    needs: \[[^\]]*\bshell-template\b[^\]]*\]')

    def test_the_impactor_files_are_present_and_pinned(self) -> None:
        d = ROOT / 'frontend-qt' / 'impactor'
        for name in ('pin', 'README.md', 'hardening.patch', 'LICENSE-impactor.txt'):
            self.assertTrue((d / name).is_file(), name)
        pin = (d / 'pin').read_text(encoding='utf-8')
        self.assertRegex(pin, r'(?m)^commit\t[0-9a-f]{40}$')
        self.assertRegex(pin, r'(?m)^repo\thttps://github\.com/')

    def test_the_new_launcher_modules_are_hidden_imports(self) -> None:
        wf = _workflow()
        for mod in ('signals', 'device_model', 'queue_model', 'transfer', 'win.device', 'win.signer', 'win.install'):
            self.assertIn(f'--hidden-import nspb_qt.{mod} ', wf, mod)


if __name__ == '__main__':
    unittest.main()
