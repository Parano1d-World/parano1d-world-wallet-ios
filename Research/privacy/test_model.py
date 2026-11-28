import unittest
from model import Ledger, Note, SpendWitness, owner, MAX

def note(value, secret=b'a'*32, nonce=1):
    return Note(value, owner(secret), nonce.to_bytes(32,'big'), (nonce+100).to_bytes(32,'big'))

class PrivacyRelationTests(unittest.TestCase):
    def setUp(self):
        self.chain=b'c'*32; self.key=b'a'*32; self.ledger=Ledger(self.chain)
        self.input=note(100); self.ledger.deposit(b'd'*32,self.input)
    def call(self, outputs, **kwargs):
        return self.ledger.transact(self.chain,self.ledger.root(),SpendWitness((self.input,),(self.key,),tuple(outputs)),**kwargs)
    def snapshot(self):
        return (self.ledger.root(),set(self.ledger.nullifiers),self.ledger.reserve)
    def test_transfer_and_withdrawal(self):
        next_note=note(99,nonce=2)
        self.call([next_note],fee=1)
        self.ledger.transact(self.chain,self.ledger.root(),SpendWitness((next_note,),(self.key,),()),withdrawal=99,recipient=b'r'*32)
        self.assertEqual(self.ledger.reserve,0)
    def test_double_spend_rejected(self):
        self.call([note(100,nonce=2)])
        with self.assertRaises(ValueError): self.call([note(100,nonce=3)])
    def test_duplicate_input_rejected(self):
        with self.assertRaises(ValueError): self.ledger.transact(self.chain,self.ledger.root(),SpendWitness((self.input,self.input),(self.key,self.key),(note(200,nonce=2),)))
    def test_inflation_atomic(self):
        before=self.snapshot()
        with self.assertRaises(ValueError): self.call([note(101,nonce=2)])
        self.assertEqual(before,self.snapshot())
    def test_wrong_owner(self):
        with self.assertRaises(ValueError): self.ledger.transact(self.chain,self.ledger.root(),SpendWitness((self.input,),(b'z'*32,),(note(100,nonce=2),)))
    def test_wrong_chain(self):
        with self.assertRaises(ValueError): self.ledger.transact(b'x'*32,self.ledger.root(),SpendWitness((self.input,),(self.key,),()))
    def test_stale_root(self):
        root=self.ledger.root(); self.ledger.deposit(b'e'*32,note(10,nonce=2))
        with self.assertRaises(ValueError): self.ledger.transact(self.chain,root,SpendWitness((self.input,),(self.key,),()))
    def test_replayed_deposit(self):
        with self.assertRaises(ValueError): self.ledger.deposit(b'd'*32,note(10,nonce=2))
    def test_duplicate_output(self):
        with self.assertRaises(ValueError): self.call([note(50,nonce=2),note(50,nonce=2)])
    def test_negative_or_bool_values(self):
        for v in (-1, True, 0, MAX+1):
            with self.assertRaises(ValueError): note(v).commitment(self.chain)
    def test_missing_member(self):
        with self.assertRaises(ValueError): self.ledger.transact(self.chain,self.ledger.root(),SpendWitness((note(100,nonce=4),),(self.key,),(note(100,nonce=2),)))
    def test_withdrawal_requires_recipient(self):
        with self.assertRaises(ValueError): self.call([],withdrawal=100)
    def test_blinding_changes_commitment(self):
        self.assertNotEqual(note(100).commitment(self.chain),note(100,nonce=2).commitment(self.chain))
    def test_nullifiers_bind_chain(self):
        self.assertNotEqual(self.input.nullifier(self.chain,self.key),self.input.nullifier(b'x'*32,self.key))
    def test_public_record_excludes_note_plaintext(self):
        record=self.call([note(100,nonce=2)])
        self.assertNotIn('notes',record); self.assertNotIn('secrets',record)
        # This is a schema test, NOT a cryptographic privacy test.

if __name__=='__main__': unittest.main()
