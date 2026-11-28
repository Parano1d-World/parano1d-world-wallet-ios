# Private NOID: code findings and proposed research boundary

Status: executable accounting specification, NOT a deployed privacy protocol.
Inspected 2026-11-10. Exact source revisions are in Vendor/sources.json.

## What the existing code exposes

At Parano1d e6d324ff70fa7d1da9965ba4221ad72c4aebc2e3:

- `noid_tx/src/types.rs`: `TxInput` has slot_index, amount, creation_id;
  `TxOutput` has slot_index, amount, owner; `TxBody` has fee and input_owner.
  The file explicitly calls these canonical transparent transaction types.
- `noid_tx/src/public_logic.rs`: public integer accounting checks the input
  and output sums. Encryption of those fields would break current validation.
- `noid_tx/src/owner_auth.rs`: canonical authorization binds the public body
  hash and input owner. Secret hiding is not recipient or amount hiding.
- `noid_chain/src/fri_state.rs`: live State stores value and owner limbs.
- Native DEX/NFT transactions also have public market/listing State. Making a
  wallet private does not hide liquidity reserves, NFT serials, listings or fills.
- Paramo1d's README explicitly identifies X25519/XSalsa20-Poly1305 messaging.
  Its payment authorization and its chat encryption have different assumptions.

Official documentation: https://docs.parano1d.org/
Source: https://github.com/ignotusnemo/parano1d
Mobile: https://github.com/ignotusnemo/paramo1d
SDK: https://github.com/ignotusnemo/parano1d-sdk

## Proposed route: a consensus-verified shielded pool

This is a design hypothesis, not a demonstrated capability of today's ABI.
Native integration needs protocol maintainers and network adoption. An isolated
fork can test it but is not mainnet NOID. A separate custody service is not an
acceptable substitute for trustless privacy.

A new note would commit to an asset identity, value, recipient authority,
unique note randomness and fresh high-entropy blinding. Initially restrict to
native NOID. Public State would accumulate note commitments and spent nullifiers,
not publish the note openings. A spend proves membership in an accepted root,
authority, correct nullifier derivation, output formation, range constraints and
value conservation, while keeping the openings and membership paths private.

A proof must bind chain/network identity, protocol version, root, ordered
nullifiers, output commitments, public fee, withdrawal value and recipient,
expiry, and hashes of encrypted recipient payloads. Canonical serialization
must tag and count variable-length fields. Reject duplicate nullifiers both
within a transaction and across all transactions in a block.

Deposits and withdrawals need an explicit consensus turnstile: authenticate the
public deposit exactly once, lock native value, and release it only with a valid
shielded proof. Enforce reserve accounting and reorg-safe atomic updates. Public
entry/exit values and timing remain correlation channels.

### Required work beyond the model

1. Formalize the complete relation and its soundness/zero-knowledge assumptions.
2. Implement a zero-knowledge circuit and verifier. Existing Owner capsules do
   not automatically prove hidden membership and shielded balance constraints.
   Establish whether the current proof stack can express and efficiently compose
   that relation. Prototype costs before choosing an implementation.
3. Choose and analyze domain-separated commitment/nullifier functions, entropy,
   parameter sizes and quantum security; no security level follows merely from
   choosing SHA3 or from the chain's existing authorization claim.
4. Implement authenticated recipient note encryption with a reviewed hybrid/PQ
   construction, key distribution, recovery, viewing keys and downgrade rejection.
   Do not invent a KEM or message ratchet. Post-quantum note encryption must also
   address sender authentication and forward-secrecy requirements separately.
5. Implement authenticated wallet scanning and note availability. Commitments
   alone cannot recover lost encrypted notes. Ciphertexts/receipts need durable
   availability or explicit, tested wallet backup requirements.
6. Modify canonical wire formats, block validation, State roots, recursion,
   snapshots, mempool admission, fees, RPC and iOS proving. Preserve versioned
   upgrade/fork boundaries and anti-replay rules.
7. Resolve accumulation costs. Append-only commitments and nullifiers can grow
   indefinitely and conflict with assumptions behind a bounded/pruned State.
   A compact accumulator needs its own update, membership and availability story.
8. Run adversarial tests, independent cryptographic review, testnet deployment,
   audit and real-device benchmarks before enabling value transfers.

## Privacy on public markets

Inside a future shielded pool, transfers could conceal details under its proved
security model. Exiting to a transparent public market exposes the public trade.
Returning proceeds to the pool does not erase that link. NFTs can be distinctive
identifiers even without a public owner address. Private swaps would need a
separate private settlement/market design, liquidity, and MEV analysis.

## Comparison target: Zcash, not an unsupported superiority claim

Primary references:
- https://zips.z.cash/protocol/protocol.pdf
- https://zcash.github.io/orchard/design/nullifiers.html
- https://github.com/zcash/orchard/blob/main/src/note/commitment.rs

Zcash already has implemented shielded note commitments, nullifiers and proof
relations. Its deployed design is the comparison baseline. This project has no
implemented shielded proof and no measured anonymity set. A post-quantum design
might offer a different cryptographic threat profile if proved, but that alone
would not establish better overall privacy.

Evaluate: sender/recipient/value leakage; entry/exit correlation; active tagging;
network metadata and RPC access patterns; ciphertext security against stored-data
attacks; anonymity-set size; proof size and verification/proving latency; mobile
memory; wallet recovery; audit maturity; and usability. No numbers or winner can
be claimed until measured against equivalent threat models and workloads.

## What runs now

`Research/privacy/model.py` checks a proposed single-asset accounting relation.
The validator intentionally sees every note and secret. There is no ZK proof,
private network, ciphertext, Merkle proof, production accumulator, fork handling,
consensus integration, or wallet implementation. SHA3 hashes are specification
placeholders, not proof of post-quantum privacy. Never send secrets to this model
as a service. Its tests expose accounting mistakes early; passing them is not
cryptographic validation.

The iOS source has device access control, ephemeral dApp browsing, explicit
read-only consent, origin checks, expiring sessions and disconnect-on-background.
It does not yet store spending secrets, send payments, or enable encrypted chat.
