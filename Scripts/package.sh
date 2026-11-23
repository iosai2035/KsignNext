#!/bin/bash
# Package the exported IPA: verify Payload/.app exist and hash the result.
set -euo pipefail
IPA="${1:-./build/Export/KsignNext.ipa}"
python3 Scripts/inspect_ipa.py "$IPA"
shasum -a 256 "$IPA"
