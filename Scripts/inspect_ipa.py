#!/usr/bin/env python3
"""Verify an IPA: valid ZIP, Payload/*.app present, Info.plist readable."""
import plistlib
import sys
import zipfile

path = sys.argv[1]
with zipfile.ZipFile(path) as z:
    names = z.namelist()
    apps = [n for n in names if n.startswith("Payload/") and n.count("/") == 2
            and n.endswith(".app/")]
    assert apps, "No Payload/*.app found"
    app = apps[0].rstrip("/")
    info = f"{app}/Info.plist"
    assert info in names, "Info.plist missing"
    with z.open(info) as f:
        pl = plistlib.load(f)
    print("app:", app)
    print("bundle_id:", pl.get("CFBundleIdentifier"))
    print("name:", pl.get("CFBundleDisplayName") or pl.get("CFBundleName"))
    print("version:", pl.get("CFBundleShortVersionString"),
          "build:", pl.get("CFBundleVersion"))
    print("min_os:", pl.get("MinimumOSVersion"))
print("IPA structure OK:", path)
