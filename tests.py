"""Offline sanity tests: not a substitute for compiling with the iOS SDK."""
from pathlib import Path
import plistlib

ROOT = Path(__file__).parent
app = plistlib.loads((ROOT / 'NFCPrank/Info.plist').read_bytes())
ent = plistlib.loads((ROOT / 'entitlements.plist').read_bytes())
src = (ROOT / 'NFCViewController.m').read_text()
assert app['CFBundleIdentifier'] == 'com.thxrealx7.nfcprank'
assert app['NFCReaderUsageDescription']
assert {'NDEF', 'TAG'}.issubset(ent['com.apple.developer.nfc.readersession.formats'])
for layout in ('{0x29, 0x2A, 0x2B, 0x2C, 0x27}',
               '{0x83, 0x84, 0x85, 0x86, 0x81}',
               '{0xE3, 0xE4, 0xE5, 0xE6, 0xE1}'):
    assert layout in src
for token in ('0x60', '0x30', '0xA2', '0x1B', '0xFF', '0x04',
              '0x58, 0x37', 'created by thxrealx7'):
    assert token in src
assert 'writeLockWithCompletionHandler' not in src
assert 'CFGLCK' in src
print('Static project checks passed (not an iOS compile).')
