#!/bin/bash
# Mac gate for the public edition: build, Rust node tests, XCTest. No upload.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)" == Darwin ]] || { echo 'Run this on your Mac with Xcode installed.' >&2; exit 1; }
export PATH="$HOME/.cargo/bin:$PATH"
report="TestResults/PublicValidation-$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$report"
trap 'printf "Validation stopped. Read the failing log in %s. No upload occurred.\n" "$report" >&2' ERR
python3 Scripts/check-public-edition.py 2>&1 | tee "$report/compliance.log"
bash Scripts/build-public.sh 2>&1 | tee "$report/build.log"
cargo test --locked --manifest-path Node/Cargo.toml 2>&1 | tee "$report/node-tests.log"
bash Scripts/test-public.sh 2>&1 | tee "$report/xctest.log"
printf '%s\n' 'PUBLIC EDITION BUILD AND TESTS PASSED' > "$report/result.txt"
printf '\nPublic edition validation passed. Next: DEVICE=ipad bash Scripts/run-public-simulator.sh, then the device checklist in PUBLIC-EDITION.md.\n'
