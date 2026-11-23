# Ksign Next — Readiness Report (Phase 1, 2026-11-23)

## What was done
1. Read the full master prompt (`workspace/user/files/51.txt`, sections
   1–30) in full.
2. Checked the build environment on this machine.
3. Verified every reference repository live via GitHub.
4. Created the project workspace skeleton exactly per prompt §4, plus
   `Scripts/build.sh`, `Scripts/package.sh`, `Scripts/validate.sh`,
   `Scripts/inspect_ipa.py`, `README.md`, `THIRD_PARTY_NOTICES.md`
   (draft) and `Documentation/Architecture.md` (Phase 1 draft).
5. No Swift source written yet — intentionally, pending the user's
   Ksign file and a go-ahead on the reference repos (see §4).

## Environment — verified
- This machine: Linux (x86_64), 150 GB disk (135 GB free), git 2.43,
  Python 3.12, Node/npm present.
- **No Xcode, no `xcodebuild`, no Swift toolchain.** A real iOS build
  and a real IPA can only happen on macOS + Xcode (or a GitHub Actions
  macOS runner). On this machine I can do: full architecture, all Swift
  source, scripts, docs, tests design, and logic that can be checked
  with Python / a Linux Swift toolchain if installed — but I will not
  claim a build succeeded until `xcodebuild` actually runs on macOS.
- This matches the prompt §30: complete everything possible here, build
  a ready-to-build project, and state plainly what needs Xcode.

## Reference repositories — verified live
- Nyasami/Ksign — exists (main, GPL-3.0, Swift, ~42 MB). Cloned shallow.
- Feather — the `khcrysalis/Feather` path moved: now
  `claration/feather` (GPL-3.0). Cloned shallow.
- Zsign — moved: now `claration/zsign`, branch master (MIT).
  Cloned shallow (94 MB — includes history/blobs in the shallow clone).
- IDeviceKit — moved: now `claration/idevicekit` (MIT).
- AltSourceKit — **original `khcrysalis/AltSourceKit` returns 404**;
  only forks remain (e.g. pxx917144686/AltSourceKit). Unresolved:
  use a fork, re-implement, or drop it — decision after the Ksign file.
- apple/swift-nio (main, Apache-2.0), weichsel/ZIPFoundation (main,
  MIT), tsolomko/SWCompression (develop, MIT), apple/swift-crypto,
  openssl/openssl — all exist.
- Licence consequence: Ksign/Feather are GPL-3.0 — reference only,
  no code copied; otherwise the whole app would become GPL-3.0.

## §4 — Security check on the cloned references
The three shallow clones are in
`workspace/ksign-next/research/references/` (Ksign, feather, zsign).
A security check flagged that cloned content: I have **not opened,
inspected, run, or copied anything from those clones**, and I will not
do so until you say so in plain words. The prompt's Phase 1 asks me to
inspect them (module map, file inventory, licences) — that step is
waiting on your go-ahead, because inspecting downloaded code can run
hooks/filters during ordinary processing.

## What is ready
- Workspace: `workspace/ksign-next/` with the full §4 folder tree.
- Architecture draft, third-party notices draft, build/package/
  validate/inspect scripts.
- Known limits documented: no macOS/Xcode here; AltSourceKit gone;
  khcrysalis repos renamed to `claration/*`; SwiftData needs iOS 17
  so Core Data is the likely store for the iOS 16 floor.

## Next step — waiting on the user
1. Send the Ksign app file (as you said) — I will compare it against
   the prompt, learn from it, and record what to reuse / replace.
2. Say whether I may inspect the three cloned reference repos.
3. Then Phase 1 completes (module map + function-to-engine table) and
   Phase 2 (Xcode project + SPM + real source) begins.
