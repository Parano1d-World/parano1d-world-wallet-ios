#!/bin/bash
# Installs the public edition on an iPhone or iPad simulator and takes review
# screenshots of launch. DEVICE=ipad uses an iPad simulator.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)" == Darwin ]] || { echo 'Run this on your Mac.' >&2; exit 1; }
app="$PWD/DerivedData-Public/Build/Products/Debug-iphonesimulator/Parano1dWallet.app"
[[ -d "$app" ]] || { echo 'Run bash Scripts/build-public.sh first.' >&2; exit 1; }
prefix=iPhone; [[ "${DEVICE:-}" == ipad ]] && prefix=iPad
if [[ -z "${SIMULATOR_ID:-}" ]]; then
  SIMULATOR_ID="$(xcrun simctl list devices available --json | python3 -c 'import json,sys; d=json.load(sys.stdin); p=[x for v in d["devices"].values() for x in v if x.get("isAvailable") and x.get("name","").startswith(sys.argv[1])]; p.sort(key=lambda x:(x.get("state")!="Booted",x["name"])); print(p[0]["udid"] if p else "")' "$prefix")"
fi
[[ -n "$SIMULATOR_ID" ]] || { echo "Create an $prefix simulator in Xcode first." >&2; exit 1; }
xcrun simctl boot "$SIMULATOR_ID" 2>/dev/null || true
open -a Simulator --args -CurrentDeviceUDID "$SIMULATOR_ID"
xcrun simctl bootstatus "$SIMULATOR_ID" -b
xcrun simctl install "$SIMULATOR_ID" "$app"
xcrun simctl launch --terminate-running-process "$SIMULATOR_ID" com.koajent.parano1d.wallet
mkdir -p TestResults/Screenshots
sleep 4
shot="TestResults/Screenshots/public-$prefix-launch-$(date -u +%Y%m%dT%H%M%SZ).png"
xcrun simctl io "$SIMULATOR_ID" screenshot "$shot"
printf 'Launched. Screenshot: %s\nNavigate each tab and press Cmd+S in Simulator to save more screenshots for review.\n' "$shot"
