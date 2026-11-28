# Offline payment semantics and current iOS implementation

The pinned Paramo1d README states that payments settle on the Parano1d network.
Bluetooth carries authorization and receipts; the local node checks inclusion.
Its Android report `Vendor/paramo1d/android/reports/redmi-15c-2026-11-10.md`
describes a round trip of the same already-authorized payment, proof checks on
both devices, and subsequent independent receipt verification. It does not
establish guaranteed settlement from two disconnected phones agreeing.

## Implemented source path (physical iPhone validation pending)

1. Send reviews a payment using slot proofs bound to locally verified chain state.
2. Fresh authentication authorizes it and saves its exact signed bytes before
   returning them. The pending journal blocks a conflicting local authorization.
3. Messaging can attach that pending authorization to an upstream Courier
   Transaction envelope for a selected contact. It does not sign a second spend
   or change the intended on-chain recipient. The current packet cap is 1 MiB;
   larger payments fail explicitly rather than being truncated.
4. The packet can be carried by the iOS BLE adapter or shared while offline.
   The recipient decrypts and verifies its owner authorization before displaying
   the payment card. Bluetooth write acknowledgment alone is NOT this proof check.
5. A connected recipient/carrier can explicitly forward the same signed bytes.
   No automatic spending follows receipt of a message. Submission is not settlement.
6. Receipt lookup synchronizes and verifies inclusion against accepted local
   chain state. Saved receipt evidence is protected on-device and reverified on
   reuse. Finalized receipt verification releases the sender's reservation as
   settled; verified expiry has the separate UNKNOWN outcome described below.

## Boundaries that must remain visible

- Authorization verified means the owner approved those exact terms. It does not
  prove the inputs are still spendable at a later network state.
- Another device restored from the same seed is not controlled by this device's
  local journal. Network consensus decides which conflicting spend, if any, is
  accepted. Local guards cannot promise both offline recipients will get paid.
- Offline Send now re-verifies the saved chain bundle and cached slot proofs.
  It requires an earlier successful online refresh with output-slot proofs.
  Cached proofs outside the locally known epoch are rejected. While disconnected,
  the device cannot know whether the live network has advanced into a new epoch
  or spent those inputs. Physical offline preparation tests are pending.
- iOS BLE is not compatible with upstream Android RFCOMM. Two- and three-iPhone
  carriage, loss/restart, duplicate delivery, reconnect and settlement tests remain.
  The iOS carrier does not implement Android's authenticated fresh-session
  Bluetooth link challenge; signed Courier packets and pinned contact keys
  authenticate content, not the BLE peer device.
- Encrypted RelayUpdate receipt replies can be prepared after local verification.
  Received peer status remains unverified until the local receipt verifier accepts
  it. Verified evidence is saved for the sender's pending-payment reconciliation.
  Receipt exchange over actual iPhone BLE remains untested.
- Payment expiry recovery verifies the saved authorization and the accepted
  local chain bundle. It releases the reservation only when finality covers the
  epoch's last eligible block, and archives settlement as UNKNOWN. This is not
  evidence that the recipient went unpaid. Native DEX/NFT authorizations use this
  path too: their V4 owner proof is verified, and trade validity deadlines can
  shorten the epoch window. Caller timestamps and peer status cannot release it.

This is development source, not a final build or a guarantee of mainnet safety.
