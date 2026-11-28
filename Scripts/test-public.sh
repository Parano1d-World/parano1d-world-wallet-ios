#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)" == Darwin ]] || { echo 'A Mac with Xcode is required.' >&2; exit 1; }
simulator_arch="$(uname -m)"
if [[ -z "${SIMULATOR_ID:-}" ]]; then
  SIMULATOR_ID="$(xcrun simctl list devices available --json | python3 -c 'import json,sys; d=json.load(sys.stdin); p=[x for v in d["devices"].values() for x in v if x.get("isAvailable") and x.get("name","").startswith("iPhone")]; p.sort(key=lambda x:(x.get("state")!="Booted",x["name"])); print(p[0]["udid"] if p else "")')"
fi
[[ -n "$SIMULATOR_ID" ]] || { echo 'Create an iPhone simulator in Xcode first.' >&2; exit 1; }
mkdir -p TestResults
xcodebuild -project Parano1dPublic.xcodeproj -scheme Parano1dPublic -destination "platform=iOS Simulator,id=$SIMULATOR_ID,arch=$simulator_arch" \
  -resultBundlePath "TestResults/PublicTests-$(date -u +%Y%m%dT%H%M%SZ).xcresult" -derivedDataPath "$PWD/DerivedData-Public" \
  ARCHS="$simulator_arch" ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual test
