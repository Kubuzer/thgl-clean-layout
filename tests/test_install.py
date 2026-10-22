"""Offline regression tests. Python standard library plus PowerShell 5.1 or 7.

Run: python tests/test_install.py --pwsh powershell.exe
No production endpoints, scheduled tasks, or administrator privileges are used.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

parser = argparse.ArgumentParser(add_help=False)
parser.add_argument('--pwsh', default=shutil.which('pwsh') or shutil.which('powershell.exe'))
options, remaining = parser.parse_known_args()
if not options.pwsh:
    parser.error('Specify --pwsh with a PowerShell executable.')
REPO = Path(__file__).resolve().parents[1]


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='thgl-tests-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.root = self.base / 'override folder'

    def invoke(self, *, uninstall=False, phase='1', response='', fail_write=False,
               fail_delete=False, root=None, success=True):
        environment = dict(os.environ, THGL_TEST_REPO=str(REPO),
                           THGL_TEST_ROOT=str(root if root is not None else self.root),
                           THGL_TEST_UNINSTALL='1' if uninstall else '0',
                           THGL_TEST_PHASE=phase, THGL_TEST_RESPONSE=response,
                           THGL_TEST_FAIL_WRITE='1' if fail_write else '0',
                           THGL_TEST_FAIL_DELETE='1' if fail_delete else '0')
        result = subprocess.run([options.pwsh, '-NoLogo', '-NoProfile', '-NonInteractive',
                                 '-File', str(REPO / 'tests/fixtures/install.ps1')],
                                env=environment, cwd=self.base, text=True, capture_output=True, timeout=45)
        output = result.stdout + result.stderr
        if success:
            self.assertEqual(result.returncode, 0, output)
        else:
            self.assertNotEqual(result.returncode, 0, output)
            self.assertNotIn('Uninstalled.', output)
        return output

    def manifest(self):
        return json.loads((self.root / 'manifest.json').read_text(encoding='utf-8-sig'))

    def save_manifest(self, document):
        self.root.mkdir(parents=True, exist_ok=True)
        (self.root / 'manifest.json').write_text(json.dumps(document), encoding='utf-8')

    def snapshot(self):
        return {str(p.relative_to(self.root)): p.read_bytes()
                for p in self.root.rglob('*') if p.is_file()}

    def test_install_repeat_refresh_uninstall(self):
        self.invoke()
        first = Path(self.manifest()['overrideFile'])
        self.assertEqual(first.name, 'small1.css')
        self.assertTrue(first.read_text().endswith((REPO / 'clean-layout.css').read_text()))
        content = first.read_bytes()
        self.invoke()
        self.assertEqual(first.read_bytes(), content)
        sentinel = first.parent / 'user-file.txt'
        sentinel.write_text('preserve')
        (self.root / 'watchdog.log').write_text('current log')
        (self.root / 'watchdog.log.1').write_text('previous log')
        self.invoke(phase='2')
        self.assertFalse(first.exists())
        self.assertTrue(first.with_name('small2.css').is_file())
        self.invoke(uninstall=True)
        self.assertEqual(sentinel.read_text(), 'preserve')
        self.assertFalse((self.root / 'manifest.json').exists())
        self.assertFalse((self.root / 'watchdog.log.1').exists())
        self.invoke(uninstall=True)  # Idempotent and does not delete the sentinel.
        self.assertEqual(sentinel.read_text(), 'preserve')

    def test_relative_root_and_trailing_separator(self):
        self.invoke(root=os.path.relpath(self.root, self.base) + os.sep)
        self.assertTrue(Path(self.manifest()['overrideFile']).is_absolute())
        self.invoke(uninstall=True)
        self.assertFalse(self.root.exists())

    def test_unicode_root_survives_manifest_round_trip(self):
        self.root = self.base / 'u\u017cytkownik-\u0142\u00f3d\u017a'
        self.invoke()
        self.assertEqual(Path(self.manifest()['overrideFile']).parents[4], self.root)
        self.invoke(phase='2')
        self.invoke(uninstall=True)
        self.assertFalse(self.root.exists())

    def test_manifest_cannot_escape_or_select_non_css_files(self):
        outside = self.base / 'outside.txt'
        outside.write_text('owned canary')
        self.root.mkdir()
        inside = self.root / 'user-file.txt'
        inside.write_text('owned canary')
        values = [str(outside), str(self.root / '..' / outside.name),
                  [str(outside), str(inside)], [str(outside), str(outside)],
                  str(inside), None, 42, True, {'path': str(outside)}]
        for value in values:
            for uninstall in (False, True):
                with self.subTest(value=value, uninstall=uninstall):
                    self.save_manifest({'overrideFile': value})
                    before = self.snapshot()
                    self.invoke(uninstall=uninstall, success=False)
                    self.assertEqual(self.snapshot(), before)
                    self.assertEqual(outside.read_text(), 'owned canary')

    def test_directory_cannot_masquerade_as_css(self):
        target = self.root / 'static.th.gl/_next/static/chunks/fake.css'
        target.mkdir(parents=True)
        self.save_manifest({'overrideFile': str(target)})
        self.invoke(uninstall=True, success=False)
        self.assertTrue(target.is_dir())

    def directory_link(self, link, target):
        if os.name == 'nt':
            result = subprocess.run(['cmd', '/c', 'mklink', '/J', str(link), str(target)], capture_output=True)
            if result.returncode:
                self.skipTest('Windows junction creation unavailable')
        else:
            link.symlink_to(target, target_is_directory=True)

    def test_linked_root_is_rejected(self):
        target = self.base / 'outside'
        target.mkdir()
        sentinel = target / 'keep.txt'
        sentinel.write_text('preserve')
        self.directory_link(self.root, target)
        for uninstall in (False, True):
            self.invoke(uninstall=uninstall, success=False)
        self.assertEqual(sentinel.read_text(), 'preserve')
        self.assertEqual(len(list(target.iterdir())), 1)

    def test_linked_css_directory_is_rejected(self):
        self.invoke()
        css = Path(self.manifest()['overrideFile'])
        external = self.base / 'external-chunks'
        shutil.move(str(css.parent), str(external))
        self.directory_link(css.parent, external)
        before = (external / css.name).read_bytes()
        for uninstall in (False, True):
            self.invoke(uninstall=uninstall, success=False)
        self.assertEqual((external / css.name).read_bytes(), before)

    def test_unknown_file_is_not_overwritten(self):
        target = self.root / 'static.th.gl/_next/static/chunks/small1.css'
        target.parent.mkdir(parents=True)
        target.write_text('user authored CSS')
        self.invoke(success=False)
        self.assertEqual(target.read_text(), 'user authored CSS')
        self.assertFalse((self.root / 'manifest.json').exists())

    def test_modified_managed_files_are_preserved(self):
        self.invoke()
        for target in (Path(self.manifest()['overrideFile']), self.root / 'watchdog.ps1'):
            with self.subTest(target=target.name):
                original = target.read_bytes()
                target.write_bytes(original + b'/* user modification */')
                before = self.snapshot()
                for uninstall in (False, True):
                    self.invoke(uninstall=uninstall, success=False)
                    self.assertEqual(self.snapshot(), before)
                target.write_bytes(original)

    def test_replacement_does_not_write_through_a_css_hard_link(self):
        self.invoke()
        css = Path(self.manifest()['overrideFile'])
        external = self.base / 'external-canary.css'
        os.link(css, external)
        original = external.read_bytes()
        self.invoke(response='changed')
        self.assertNotEqual(css.read_bytes(), original)
        self.assertEqual(external.read_bytes(), original)
        self.invoke(uninstall=True)
        self.assertEqual(external.read_bytes(), original)

    def test_legacy_upgrade_preserves_originals_as_backups(self):
        self.invoke()
        legacy = self.manifest()
        original_css = Path(legacy['overrideFile']).read_bytes()
        original_watchdog = (self.root / 'watchdog.ps1').read_bytes()
        for field in ('schemaVersion', 'overrideSha256', 'watchdogSha256'):
            del legacy[field]
        self.save_manifest(legacy)
        self.invoke(phase='2')
        self.assertEqual(self.manifest()['schemaVersion'], 2)
        backups = [p.read_bytes() for p in (self.root / 'backups').iterdir()]
        self.assertIn(original_css, backups)
        self.assertIn(original_watchdog, backups)
        self.invoke(uninstall=True)
        self.assertEqual(len(list((self.root / 'backups').iterdir())), 2)

    def test_failed_write_restores_same_and_changed_css_url(self):
        self.invoke()
        before = self.snapshot()
        for phase in ('1', '2'):
            with self.subTest(phase=phase):
                self.invoke(phase=phase, response='changed', fail_write=True, success=False)
                self.assertEqual(self.snapshot(), before)
                self.assertFalse(list(self.root.rglob('.thgl-*.tmp')))

    def test_failed_old_css_cleanup_rolls_back_upgrade(self):
        self.invoke()
        before = self.snapshot()
        self.invoke(phase='2', fail_delete=True, success=False)
        self.assertEqual(self.snapshot(), before)

    def test_failed_uninstall_preserves_manifest_and_files(self):
        self.invoke()
        before = self.snapshot()
        self.invoke(uninstall=True, fail_delete=True, success=False)
        self.assertEqual(self.snapshot(), before)
        self.invoke(uninstall=True)
        self.assertFalse(self.root.exists())

    def test_invalid_css_response_preserves_working_install(self):
        self.invoke()
        before = self.snapshot()
        for response in ('html', 'empty', 'wrong-type'):
            with self.subTest(response=response):
                self.invoke(phase='2', response=response, success=False)
                self.assertEqual(self.snapshot(), before)

    def test_malformed_manifest_does_not_change_existing_files(self):
        self.invoke()
        (self.root / 'manifest.json').write_text('{broken JSON')
        before = self.snapshot()
        self.invoke(uninstall=True, success=False)
        self.assertEqual(self.snapshot(), before)


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0], *remaining], verbosity=2)
