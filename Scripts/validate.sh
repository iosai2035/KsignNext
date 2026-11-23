#!/bin/bash
# Validate the built IPA on macOS (codesign check) — placeholder until the
# first real archive exists. Fails loudly if the IPA is missing.
set -euo pipefail
IPA="${1:-./build/Export/KsignNext.ipa}"
test -f "$IPA" || { echo "IPA not found: $IPA"; exit 1; }
python3 Scripts/inspect_ipa.py "$IPA"
codesign --verify --verbose=2 "$IPA" 2>&1 | head -20 || true
