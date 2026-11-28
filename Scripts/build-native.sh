#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Keep the builder's home folder and checkout path (for example /Users/<name>) out of
# the shipped app: compiled Rust and C otherwise embed full source file paths.
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=$HOME=/home --remap-path-prefix=$PWD=/parano1d"
# No embedded bitcode: it would store these compiler settings, including local folder paths, inside the app.
export CFLAGS="${CFLAGS:-} -fembed-bitcode=off -ffile-prefix-map=$HOME=/home -ffile-prefix-map=$PWD=/parano1d"
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'Apple SDKs and Xcode are required for iOS compilation.' >&2
  exit 1
fi
python3 Scripts/fetch-upstream.py --with-mobile
case "$(uname -m)" in
  x86_64) simulator_target=x86_64-apple-ios ;;
  arm64) simulator_target=aarch64-apple-ios-sim ;;
  *) echo 'Unsupported Mac architecture.' >&2; exit 1 ;;
esac
rustup target add aarch64-apple-ios "$simulator_target"
cargo test --locked --manifest-path Native/Cargo.toml
for target in aarch64-apple-ios "$simulator_target"; do
  cargo build --locked --release --manifest-path Native/Cargo.toml --target "$target"
done
mac_args=()
if [[ "${PARANO1D_MAC_CATALYST:-}" == 1 ]]; then
  # Mac Catalyst (Intel and Apple silicon Macs): one universal slice.
  rustup target add x86_64-apple-ios-macabi aarch64-apple-ios-macabi
  for target in x86_64-apple-ios-macabi aarch64-apple-ios-macabi; do
    cargo build --locked --release --manifest-path Native/Cargo.toml --target "$target"
  done
  mkdir -p Native/target/maccatalyst
  lipo -create Native/target/x86_64-apple-ios-macabi/release/libparanoid_ios_core.a Native/target/aarch64-apple-ios-macabi/release/libparanoid_ios_core.a -output Native/target/maccatalyst/libparanoid_ios_core.a
  mac_args=(-library Native/target/maccatalyst/libparanoid_ios_core.a -headers Native/Headers)
fi
rm -rf "Native/Headers"
mkdir -p Native/Headers/ParanoidCore
cp Native/paranoid_ios.h Native/module.modulemap Native/Headers/ParanoidCore/
rm -rf "Native/ParanoidCore.xcframework"
xcodebuild -create-xcframework \
  -library Native/target/aarch64-apple-ios/release/libparanoid_ios_core.a -headers Native/Headers \
  -library "Native/target/$simulator_target/release/libparanoid_ios_core.a" -headers Native/Headers \
  ${mac_args[@]+"${mac_args[@]}"} \
  -output Native/ParanoidCore.xcframework
