# What this edition contains

- **Self-custody NOID wallet:** create, import and back up a wallet, send and receive NOID, check receipts, keep an address book, and manage several wallets and accounts.
- **On-device node:** it verifies the chain proofs on the device. Optional backup node endpoints are under Settings → Network, and Paranoid mode checks balances, sends and receipts directly through mainnet peers.
- **Tokens and NFTs:** view the ones you own and send them to another wallet.
- **Private chat:** end-to-end encrypted chat between connected contacts, with payment requests.
- **Public `#parano1d` room:** signed, public, not encrypted. It has a rules gate, local screening, report, block and a signed moderation list.
- **Mining:** pair your own mining computer with its one-time code. The phone gets its own signing key (Secure Enclave where available), and you can revoke it on the computer. The phone shows what the rig reports and can start or stop mining, but it can't change the payout address, pool or miner programs.
- **Ecosystem:** links to Parano1d World, the Parano1d project sites and independent services. All of them open in the system browser after a leaving notice.
- **Apple Watch:** balance, pay saved contacts, requests, receipts, private chat and NFTs (view only). Watch sends are off by default and are confirmed with the app PIN. The iPhone signs; the watch holds no keys.
- **Mac:** the same app built with Mac Catalyst.

## Not in this edition
- Exchange, token markets, launchpad and swaps
- Buying, listing or selling NFTs
- An in-app website browser
- Copying the master key to websites

`Scripts/check-public-edition.py` stops the build if any of these are wired back in. Nearby Bluetooth relay is off by default and opt-in.

## Device checklist
- [ ] Fresh install: create a wallet, back it up, lock and unlock, then receive and send a small amount of NOID.
- [ ] The device node reaches a verified boundary, and the installed NFT State matches the verified height.
- [ ] Send one token and one NFT between two disposable wallets and check the receipts.
- [ ] Chat: the rules sheet shows on first open; connect a contact; send, report, block and unblock.
- [ ] Mining: pair a test computer, start and stop it, unpair it, and check that a revoked phone is refused.
- [ ] iPad in both orientations, Apple Watch features, and a Mac build: same wallet flows.
- [ ] Offline mode stops network access, and nearby relay stays off until you turn it on.
