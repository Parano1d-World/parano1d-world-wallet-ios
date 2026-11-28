# Parano1d World Wallet (App Store edition)

Self-custody NOID wallet for iPhone, iPad, Apple Watch and Mac, published by KoAjent LLC (Parano1d World).

- **Keys stay on your device.** They're created on the device and stored in its Keychain. That item requires a device passcode, asks for Face ID, Touch ID or the passcode to use, and is never synced to iCloud.
- **On-device node.** The app verifies the chain proofs on the device instead of trusting a server.
- **No trading.** There's no exchange, token market or NFT sale in this edition. You can view and send what you own.
- **Private chat.** End-to-end encrypted between contacts who exchange signed invitations, plus a moderated public room.
- **Mining monitor.** You can pair your own mining computer to see its status and start or stop it. The phone never mines.

This repository is published for review and audit. See `LICENSE` for what you may do with it, and `SECURITY.md` to report a vulnerability privately.

## Build

You need a Mac with Xcode, XcodeGen and the Rust toolchain in `rust-toolchain.toml`.

```
bash Scripts/validate-public.sh                    # compliance check, build, Rust tests, XCTest
DEVICE=ipad bash Scripts/run-public-simulator.sh   # or leave DEVICE unset for iPhone
KOAJENT_TEAM_ID=<your team> bash Scripts/build-mac.sh
```

Signed archives need your own Apple Developer team. The archive scripts never upload anything.

## Layout

| Folder | What it holds |
| --- | --- |
| `App/` | iPhone, iPad and Mac app (SwiftUI) |
| `WatchApp/`, `WatchWidgets/` | Apple Watch app and complications |
| `Native/`, `Node/` | Rust wallet core and on-device node |
| `Vendor/` | pinned upstream sources; hashes in `Vendor/sources.json` and `GITHUB-SOURCE-MANIFEST.json` |
| `Tests/` | Swift and Rust tests |
| `Docs/`, `Research/` | design notes and research models (not shipped in the app) |
