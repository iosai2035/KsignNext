# Vendored zsign — patches

This directory vendors **zsign** (upstream `zhlynn/zsign`, MIT — see
`LICENSE-zsign` in this directory) so Ksign Next can sign IPA bundles on
device. The vendored copy is otherwise byte-identical to the upstream
reference kept at `research/references/zsign/` (verified with `diff`
on `bundle.cpp`, `archo.cpp`, `signing.cpp`, `macho.cpp` — no
differences); the patch below is the only divergence.

## Patch 1 — fail closed when a CodeDirectory cannot be built (H1 rescope), plus a load-command bounds fix (M6)

Found by a full-code Gemini audit (2026-11-28,
`Documentation/Gemini-Full-Audit-2026-11-28.md`, findings H1 and M6)
and verified against the sources — including an empirical test on a
Linux host (vendored sources compiled with `g++ -std=c++11`, adhoc
signing of a test `.app` holding a loose dylib, superblob parsed
afterwards).

### What the audit claimed, and what verification showed

The audit claimed `ZBundle::SignNode` signs nested loose Mach-O files
(injected tweak dylibs, helper tools) with an **empty bundleId**, so
`ZSign::SlotBuildCodeDirectory` returns `false`, the superblob has **no
CodeDirectory**, yet signing reports success and iOS rejects the dylib.

That mechanism is **refuted** for this code. `ZMachO::Sign`
(`macho.cpp:132-141`) intercepts an empty bundleId before it can reach
the CodeDirectory builder: it first reads the file's embedded
`__info_plist` section for a `CFBundleIdentifier`, and if there is
none (the usual case for a tweak dylib) it falls back to the file
basename (`ZUtil::GetBaseName`). The empirical test proves it: a
loose `Tweak.dylib` signed by the stock code comes back with a
CodeDirectory whose identifier is `'Tweak.dylib'`, and the main
executable with `'com.h1test.app'`. The empty string therefore never
reaches `SlotBuildCodeDirectory`, and the basename identifier is the
same rule Apple `codesign` uses for loose non-bundle Mach-O files
(embedded `CFBundleIdentifier` if present, else the file basename).

For that reason the audit's suggested fix — passing the node's
`bundle_id` for every loose file — is **deliberately NOT applied**:
it would override the embedded-`CFBundleIdentifier`-then-basename
selection for every loose file (a dylib with its own embedded
identifier would silently be re-identified as the app), and it would
make all loose dylibs in one app share a single CodeDirectory
identifier. That is a policy change with real regression risk for
IPAs that sign fine today, not a fix for the observed behaviour.

What the audit got **right**, and what this patch fixes, is the
fail-open half of the claim: `ZArchO::BuildCodeSignature` ignores
both `SlotBuildCodeDirectory` return values (`archo.cpp:395,414`),
and `ZArchO::Sign` ignores `BuildCodeSignature`'s own return value
(`archo.cpp:566`), checking only whether the assembled blob string
is empty — which it is not when the requirements/entitlements slots
exist. So a CodeDirectory build failure **for any other reason**
(zero-length code, missing team id on a non-adhoc asset, a future
regression) would silently emit a CodeDirectory-less superblob and
report success. The forced-failure test proves it: with both
CodeDirectory calls made to fail, the stock code returns `SignFolder:
OK` and writes blobs whose slot lists are `[REQUIREMENTS,
DER_ENTITLEMENTS]` — no CodeDirectory anywhere.

### Patched behaviour

Files: `bundle.cpp` (`ZBundle::SignNode`), `archo.cpp`
(`ZArchO::BuildCodeSignature`, `ZArchO::Sign`,
`ZArchO::ReallocCodeSignSpace`).

1. `BuildCodeSignature` checks both `SlotBuildCodeDirectory` return
   values. On `false` it logs `">>> Build CodeDirectory (SHA-1 /
   SHA-256) failed!"`, clears the output blob and returns `false`.
   With the app's SHA-256-only asset only the SHA-256 call runs, and
   its output is swapped to become the primary CodeDirectory
   afterwards, so the check on that call is the one that matters in
   practice.
2. `ZArchO::Sign` checks `BuildCodeSignature`'s boolean return value
   (the existing empty-blob check stays as a second line of defence).
   With the same forced failure the patched code returns
   `SignFolder: FAIL` with the two error lines above.
3. `SignNode` validates the node up front: every node built by
   `GetSignFolderInfo` carries a non-empty `bundle_id`, so a node
   without one is corrupt (e.g. a stale cache entry). It now fails
   before any of its files are signed instead of after — the old
   check only ran after the files loop. The files loop itself still
   passes `""`, intentionally, so the identifier selection in
   `ZMachO::Sign` is unchanged.
4. M6 — `ReallocCodeSignSpace`: the free-space guard was
   `m_uLoadCommandsFreeSpace < 4`, but the code then writes a full
   16-byte `codesignature_command` (`common/mach-o.h`: four
   `uint32_t`s) into that space, so 4–15 bytes free overflowed into
   the following data. The guard is now
   `< sizeof(codesignature_command)`, matching the neighbouring
   `InjectDylib` check (`archo.cpp:674`), which already compares
   against the actual command size. The audit notes free space is
   8-byte aligned in practice, so 8 bytes was the realistic
   trigger.

### Verified behaviour (unchanged for valid IPAs)

Patched code signing the same test `.app` succeeds and produces
byte-identical signing results to the stock code: loose dylib
CodeDirectory identifier `'Tweak.dylib'`, main executable
`'com.h1test.app'`, same slot lists. The patch changes nothing for
an IPA that signs fine today; it only turns a silent broken
signature into a loud failure, and closes a 16-byte overflow.

## Re-vendoring

To update to a newer zsign commit: replace this directory with the
new upstream sources, re-apply the diff in
`Documentation/H1-Fix-Proposal.diff`, and re-run the host checks in
the proposal (syntax check, adhoc sign of a test `.app` with a loose
dylib, superblob slot inspection). If upstream fixes the ignored
return values or the `< 4` check, drop the corresponding hunk here
and note the upstream commit.
