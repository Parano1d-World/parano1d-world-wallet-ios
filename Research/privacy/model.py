"""Executable accounting specification ONLY. No ZK proof, encryption, or network.
The validator intentionally receives note plaintext to test the relation that a
future circuit must enforce. NEVER deploy this as a private transaction system.
"""
from dataclasses import dataclass
from hashlib import sha3_256
from typing import Tuple

MAX = 2**64 - 1
DOMAIN = b"PARANOID-SHIELDED-RESEARCH-v0\x00"

def h(label: bytes, *parts: bytes) -> bytes:
    return sha3_256(DOMAIN + len(label).to_bytes(4, 'big') + label + b''.join(len(p).to_bytes(8,'big') + p for p in parts)).digest()

def amount(value: int) -> bytes:
    if type(value) is not int or not 0 < value <= MAX: raise ValueError('amount outside u64 positive range')
    return value.to_bytes(8, 'big')

def owner(secret: bytes) -> bytes:
    if len(secret) != 32: raise ValueError('secret length')
    return h(b'owner', secret)

@dataclass(frozen=True)
class Note:
    value: int
    owner: bytes
    rho: bytes
    blind: bytes
    def commitment(self, chain: bytes) -> bytes:
        if any(len(x) != 32 for x in (chain, self.owner, self.rho, self.blind)): raise ValueError('identity length')
        return h(b'note', chain, amount(self.value), self.owner, self.rho, self.blind)
    def nullifier(self, chain: bytes, secret: bytes) -> bytes:
        if owner(secret) != self.owner: raise ValueError('not authorized')
        return h(b'nullifier', chain, secret, self.commitment(chain))

@dataclass(frozen=True)
class SpendWitness:
    # Private circuit inputs in a future implementation, NEVER wire-format fields.
    notes: Tuple[Note, ...]
    secrets: Tuple[bytes, ...]
    outputs: Tuple[Note, ...]

class Ledger:
    def __init__(self, chain: bytes):
        if len(chain) != 32: raise ValueError('chain length')
        self.chain = chain
        self.commitments = set()
        self.nullifiers = set()
        self.reserve = 0
        self.issued = 0
        self.withdrawn = 0
        self.fees = 0
        self.deposit_ids = set()

    def root(self):
        # Set digest for testing, NOT a Merkle accumulator or membership proof.
        return h(b'reference-set-root', *sorted(self.commitments))

    def deposit(self, event: bytes, note: Note):
        # Consensus must independently authenticate and consume the L1 deposit.
        if len(event) != 32 or event in self.deposit_ids: raise ValueError('deposit replay')
        cm = note.commitment(self.chain)
        if cm in self.commitments: raise ValueError('duplicate commitment')
        if self.reserve + note.value > MAX: raise ValueError('reserve overflow')
        self.deposit_ids.add(event)
        self.commitments.add(cm)
        self.reserve += note.value
        self.issued += note.value
        return cm

    def transact(self, chain: bytes, root: bytes, witness: SpendWitness, fee=0, withdrawal=0, recipient=b''):
        if chain != self.chain or root != self.root(): raise ValueError('wrong chain or stale root')
        if type(fee) is not int or type(withdrawal) is not int or min(fee, withdrawal) < 0 or max(fee, withdrawal) > MAX: raise ValueError('public value range')
        if withdrawal and len(recipient) != 32: raise ValueError('withdrawal recipient required')
        if not withdrawal and recipient: raise ValueError('unexpected public recipient')
        if not 1 <= len(witness.notes) <= 8 or not 0 <= len(witness.outputs) <= 8: raise ValueError('shape')
        if len(witness.notes) != len(witness.secrets): raise ValueError('missing authorization')
        cms = [n.commitment(chain) for n in witness.notes]
        nfs = [n.nullifier(chain, key) for n, key in zip(witness.notes, witness.secrets)]
        out = [n.commitment(chain) for n in witness.outputs]
        if any(c not in self.commitments for c in cms): raise ValueError('no membership')
        if len(set(nfs)) != len(nfs) or any(n in self.nullifiers for n in nfs): raise ValueError('double spend')
        if len(set(out)) != len(out) or any(c in self.commitments for c in out): raise ValueError('duplicate output')
        incoming = sum(n.value for n in witness.notes)
        outgoing = sum(n.value for n in witness.outputs)
        if incoming > MAX or outgoing > MAX: raise ValueError('sum overflow')
        if incoming != outgoing + fee + withdrawal: raise ValueError('value not conserved')
        if fee + withdrawal > self.reserve: raise ValueError('reserve underflow')
        # Public statement must bind all these fields, including ciphertext hashes
        # once an encryption scheme exists. This digest is NOT a proof.
        statement = h(b'statement', chain, root, len(nfs).to_bytes(4,'big'), *nfs, len(out).to_bytes(4,'big'), *out, fee.to_bytes(8,'big'), withdrawal.to_bytes(8,'big'), recipient)
        self.nullifiers.update(nfs)
        self.commitments.update(out)
        self.reserve -= fee + withdrawal
        self.withdrawn += withdrawal
        self.fees += fee
        assert self.reserve + self.withdrawn + self.fees == self.issued
        return {'statement': statement, 'nullifiers': tuple(nfs), 'commitments': tuple(out), 'fee': fee, 'withdrawal': withdrawal, 'recipient': recipient}
