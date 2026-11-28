# Offline asset delivery acceptance criteria

## Trust boundary

The phone may sign against a locally accepted, bounded chain snapshot. It must display the snapshot's height, hash, timestamp, asset identity, fee and expiry. The last seen gallery cache is presentation data only. A Bluetooth peer may authenticate the sender's signed intent and carry it unchanged; only the network and a device-verified finalized receipt can establish settlement. No mesh acknowledgement releases a spend reservation.

## NOID in Build 120

1. Review uses device-verified cached proofs from the same valid epoch and reserves input/output slots in the protected journal.
2. Authorization writes signed bytes and offline delivery metadata atomically. Relaunch keeps the same txid and bytes.
3. A trusted chat contact can carry an encrypted copy over BLE. On reconnect, the originating phone retries its saved authorization; duplicate submissions use the same txid.
4. The phone first checks for a matching finalized receipt, then verified signed-epoch expiry. A missing lookup is not evidence of failure. Historical status remains unknown when expiry releases a reservation.

## Native token and NFT transfer still requires implementation

- Persist a chain-bound proof of exact owner, asset ID, collection ID and serial, not merely the displayed inventory. Include the verified native State root and catalog boundary, plus a bounded validity window.
- Extend the native transfer planner and signer to accept that proof offline, validate fee and destination, and reserve exact native inputs in the same durable journal. Resolve multiple pending authorizations and replacements without double use.
- Carry the exact signed native intent without decrypting it at intermediate peers. On reconnection, check current chain State and epoch; submit only when admissible, otherwise show a recoverable terminal reason.
- Verify final receipt, ownership change and asset identity on the phone before marking sent/received. Preserve an audit trail across reinstall/restart and explicit wallet restore.
- Test three physical iPhones with internet loss, background suspension, Bluetooth denial, app termination, duplicate relay, old snapshots, chain reorganization, spent assets, conflicting authorizations, and recipient offline. Test current iOS versions; system restoration does not guarantee a permanently running relay.

Until those criteria are met, the cached token/NFT list may be viewed but offline native transfer remains disabled. This prevents a stale gallery row from authorizing an invalid or duplicate spend.
