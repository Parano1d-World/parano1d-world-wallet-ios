#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Keep the builder's home folder and checkout path (for example /Users/<name>) out of
# the shipped app: compiled Rust and C otherwise embed full source file paths.
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=$HOME=/home --remap-path-prefix=$PWD=/parano1d"
# No embedded bitcode: it would store these compiler settings, including local folder paths, inside the app.
export CFLAGS="${CFLAGS:-} -fembed-bitcode=off -ffile-prefix-map=$HOME=/home -ffile-prefix-map=$PWD=/parano1d"
if [[ "$(uname -s)" != Darwin ]]; then echo 'Xcode SDK required for the native node and database.' >&2; exit 1; fi
python3 Scripts/fetch-upstream.py --with-mobile
case "$(uname -m)" in
  x86_64) simulator_target=x86_64-apple-ios ;;
  arm64) simulator_target=aarch64-apple-ios-sim ;;
  *) echo 'Unsupported Mac architecture.' >&2; exit 1 ;;
esac
rustup target add aarch64-apple-ios "$simulator_target"
cargo test --locked --manifest-path Node/Cargo.toml
for target in aarch64-apple-ios "$simulator_target"; do
  if [[ "$target" == aarch64-apple-ios ]]; then sdk=iphoneos; else sdk=iphonesimulator; fi
  sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
  SDKROOT="$sdk_path" IPHONEOS_DEPLOYMENT_TARGET=17.0 BINDGEN_EXTRA_CLANG_ARGS="-isysroot $sdk_path" cargo build --locked --release --manifest-path Node/Cargo.toml --target "$target"
done
mac_args=()
if [[ "${PARANO1D_MAC_CATALYST:-}" == 1 ]]; then
  # Mac Catalyst (Intel and Apple silicon Macs): one universal slice.
  rustup target add x86_64-apple-ios-macabi aarch64-apple-ios-macabi
  mac_sdk="$(xcrun --sdk macosx --show-sdk-path)"
  for target in x86_64-apple-ios-macabi aarch64-apple-ios-macabi; do
    arch="${target%%-*}"
    SDKROOT="$mac_sdk" IPHONEOS_DEPLOYMENT_TARGET=17.0 \
      BINDGEN_EXTRA_CLANG_ARGS="-isysroot $mac_sdk --target=${arch/aarch64/arm64}-apple-ios17.0-macabi" \
      cargo build --locked --release --manifest-path Node/Cargo.toml --target "$target"
  done
  mkdir -p Node/target/maccatalyst
  lipo -create Node/target/x86_64-apple-ios-macabi/release/libparanoid_ios_node.a Node/target/aarch64-apple-ios-macabi/release/libparanoid_ios_node.a -output Node/target/maccatalyst/libparanoid_ios_node.a
  mac_args=(-library Node/target/maccatalyst/libparanoid_ios_node.a -headers Node/Headers)
fi
rm -rf "Node/Headers"
mkdir -p Node/Headers/ParanoidNode
cp Node/paranoid_node.h Node/module.modulemap Node/Headers/ParanoidNode/
rm -rf "Node/ParanoidNode.xcframework"
xcodebuild -create-xcframework \
 -library Node/target/aarch64-apple-ios/release/libparanoid_ios_node.a -headers Node/Headers \
 -library "Node/target/$simulator_target/release/libparanoid_ios_node.a" -headers Node/Headers \
 ${mac_args[@]+"${mac_args[@]}"} \
  -output Node/ParanoidNode.xcframework
