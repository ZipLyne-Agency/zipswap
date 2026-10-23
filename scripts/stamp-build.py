#!/usr/bin/env python3
"""Put a source receipt inside the app before its final signature."""
import datetime
import hashlib
import os
from pathlib import Path
import plistlib
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
app = Path(sys.argv[1])
digest = hashlib.sha256()
paths = list(root.glob('Sources/**/*.swift')) + list(root.glob('scripts/*.sh')) + list(root.glob('scripts/*.py'))
paths += [root / p for p in ['Package.swift', 'project.yml', 'Resources/Info.plist', 'Resources/ZipSwap.entitlements', '.github/workflows/release.yml']]
for file in sorted(set(paths)):
    if file.is_file() and not file.is_symlink():
        digest.update(str(file.relative_to(root)).encode() + b'\0' + file.read_bytes() + b'\0')
revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
dirty = bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=root))
fingerprint = digest.hexdigest()
with (app / 'Contents/Info.plist').open('rb') as source:
    info = plistlib.load(source)
info['ZipSwapSourceRevision'] = revision[:12] + (' dirty ' + fingerprint[:12] if dirty else '')
info['ZipSwapSourceFingerprint'] = fingerprint
info['ZipSwapBuildKind'] = 'CI' if os.environ.get('GITHUB_ACTIONS') == 'true' else 'Local'
info['ZipSwapBuiltAt'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
with (app / 'Contents/Info.plist').open('wb') as destination:
    plistlib.dump(info, destination)
print('source receipt: ' + info['ZipSwapSourceRevision'])
