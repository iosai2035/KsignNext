# Tests/Fixtures/Archive/

## minimal-ipa-method8.zip (566 bytes)

SHA-256: `0d8ac6ee3a1f31c580d8abd490acffeabc9fd86860806030c11100076671f330`

A minimal synthetic IPA used by `ArchiveEngineTests` as the regression
fixture for the deflate bug (see
`Documentation/Import-Deflate-Diagnosis-2026-11-28.md`).

Contents:

| Entry | Method | Compressed | Uncompressed |
|---|---|---:|---:|
| `Payload/TestApp.app/Info.plist` | 8 (deflate) | 256 | 526 |
| `Payload/TestApp.app/TestApp` | 0 (stored) | 22 | 22 |

The `Info.plist` is a small valid plist (`CFBundleIdentifier`
`com.example.TestApp`, executable `TestApp`, minimum OS 16.0). The
`TestApp` entry is 22 dummy bytes — it is NOT a real Mach-O executable;
it exists only as a stored-entry (method 0) control so the fixture
exercises both code paths in one file.

### How it was built

```sh
python3 - <<'EOF'
import zipfile
plist = open("Info.plist", "rb").read()  # the plist above
with zipfile.ZipFile("minimal-ipa-method8.zip", "w",
                     compression=zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    z.writestr("Payload/TestApp.app/Info.plist", plist)
    z.writestr("Payload/TestApp.app/TestApp", b"dummy-executable-bytes",
               compress_type=zipfile.ZIP_STORED)
EOF
unzip -t minimal-ipa-method8.zip   # must report "No errors detected"
```

### Why it exists

The old ZIP reader decoded method 8 through a fake zlib wrapper
(`0x78 0x9C` + zero Adler-32) and rejected every real IPA, while CI
stayed green because every test fixture used stored (method 0) entries
only (finding M10). This fixture is the smallest archive that would
have caught that bug: a real method-8 entry that must decode
byte-for-byte. `ArchiveEngineTests.testMinimalIPA_method8InfoPlistExtracts`
reads it through the full `listEntries` → `readEntryData` path and
asserts the decoded plist matches the expected bytes exactly.

### How tests find it

The test target does not bundle fixture files (the project generator
only adds `.swift` files under `Tests/`), so the test locates this file
via `#filePath`: it walks up from
`Tests/UnitTests/Engines/ArchiveEngineTests.swift` until a directory
containing `Fixtures/Archive/minimal-ipa-method8.zip` exists (bounded
search, 8 levels), falling back to the documented 3-level path. It
works in CI because tests run on the same checkout they were built
from. If the project generator later bundles `Tests/Fixtures/` as test
resources, the test should switch to `Bundle(for:)` — until then, do
not move this file without updating the test.
