#!/bin/bash
# Builds the App Store public edition (iPhone, iPad, Apple Watch) for the
# Simulator. Uses the same Rust frameworks as the internal build.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)" == Darwin ]] || { echo 'A Mac with Xcode is required.' >&2; exit 1; }
command -v xcodegen >/dev/null || { echo 'Install XcodeGen first (brew install xcodegen).' >&2; exit 1; }
simulator_arch="$(uname -m)"
bash Scripts/build-native.sh
bash Scripts/build-node.sh
python3 Scripts/fetch-node-parameters.py --output Node/NodeParameters
xcodegen generate --spec project-public.yml
xcodebuild -project Parano1dPublic.xcodeproj -scheme Parano1dPublic -destination 'generic/platform=iOS Simulator' \
  -configuration Debug -derivedDataPath "$PWD/DerivedData-Public" ARCHS="$simulator_arch" ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual clean build
printf '%s\n' 'Public edition built. Run bash Scripts/test-public.sh, then bash Scripts/run-public-simulator.sh.'
