#!/usr/bin/env python3
"""Stage, verify and atomically exchange a local app; retain one rollback copy.

Running applications are left to their owner. Restart after installing to load
this build. No auth state, settings or user process is modified here.
"""
import ctypes
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import uuid

source = Path(sys.argv[1]).resolve()
destination = Path.home() / 'Applications/ZipSwap.app'
destination.parent.mkdir(parents=True, exist_ok=True)
staging = destination.parent / ('.ZipSwap-stage-' + str(uuid.uuid4()) + '.app')
backup_root = Path(os.environ.get('ZIPSWAP_BUILD_DIR', str(Path.home() / 'Assets/ZipSwap/temporary/build'))) / 'rollback'
backup_root.mkdir(parents=True, exist_ok=True)
backup = backup_root / ('ZipSwap-' + str(uuid.uuid4()) + '.app')

def identity(app):
    with (app / 'Contents/Info.plist').open('rb') as file:
        return plistlib.load(file).get('CFBundleIdentifier')

if identity(source) != 'agency.ziplyne.zipswap':
    raise SystemExit('The build is not a ZipSwap app.')
if destination.is_symlink():
    raise SystemExit('The installation path is a symbolic link; it was left unchanged.')
if destination.exists() and identity(destination) != 'agency.ziplyne.zipswap':
    raise SystemExit('The installation path belongs to another application.')
subprocess.run(['ditto', str(source), str(staging)], check=True)
try:
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(staging)], check=True)
    if destination.exists():
        system = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
        exchange = system.renamex_np
        exchange.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        exchange.restype = ctypes.c_int
        if exchange(os.fsencode(staging), os.fsencode(destination), 2) != 0: # RENAME_SWAP
            raise OSError(ctypes.get_errno(), 'The app exchange failed; the installed app was retained.')
        os.rename(staging, backup)
        print('Rollback app: ' + str(backup))
    else:
        os.rename(staging, destination)
    print('Installed ' + str(destination) + '. Restart ZipSwap to load this build.')
except BaseException:
    # A failed verification keeps its task-owned staged artifact for diagnosis.
    print('Installer diagnostic artifact (if present): ' + str(staging), file=sys.stderr)
    raise
