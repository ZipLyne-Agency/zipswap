import contextlib
import io
import os
from pathlib import Path
import plistlib
import runpy
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'install-app.py'

class InstallTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix='zipswap-install-test-'))
        self.addCleanup(shutil.rmtree, self.root)
        self.source = self.root / 'source.app'
        self.destination = self.root / 'Applications/ZipSwap.app'
        for app, content in [(self.source, 'new'), (self.destination, 'old')]:
            (app / 'Contents').mkdir(parents=True)
            (app / 'payload').write_text(content)
            with (app / 'Contents/Info.plist').open('wb') as file:
                plistlib.dump({'CFBundleIdentifier': 'agency.ziplyne.zipswap'}, file)
    def install(self, reject_signature=False):
        def command(args, check):
            if args[0] == 'ditto':
                shutil.copytree(args[1], args[2])
            elif args[0] == 'codesign' and reject_signature:
                raise subprocess.CalledProcessError(1, args)
            return subprocess.CompletedProcess(args, 0)
        with patch('pathlib.Path.home', return_value=self.root), patch('subprocess.run', side_effect=command), \
             patch.dict(os.environ, {'ZIPSWAP_BUILD_DIR': str(self.root / 'build')}), \
             patch('sys.argv', [str(SCRIPT), str(self.source)]), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            runpy.run_path(str(SCRIPT), run_name='__main__')
    def test_verified_build_is_atomically_exchanged_and_old_app_retained(self):
        self.install()
        self.assertEqual((self.destination / 'payload').read_text(), 'new')
        backups = list((self.root / 'build/rollback').glob('*.app'))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / 'payload').read_text(), 'old')
    def test_failed_signature_keeps_the_installed_app(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.install(reject_signature=True)
        self.assertEqual((self.destination / 'payload').read_text(), 'old')
    def test_foreign_installation_is_never_replaced(self):
        with (self.destination / 'Contents/Info.plist').open('wb') as file:
            plistlib.dump({'CFBundleIdentifier': 'another.app'}, file)
        with self.assertRaises(SystemExit):
            self.install()
        self.assertEqual((self.destination / 'payload').read_text(), 'old')
    def test_symlink_installation_is_never_followed(self):
        shutil.rmtree(self.destination)
        self.destination.symlink_to(self.source, target_is_directory=True)
        with self.assertRaises(SystemExit):
            self.install()
        self.assertEqual((self.source / 'payload').read_text(), 'new')

if __name__ == '__main__':
    unittest.main()
