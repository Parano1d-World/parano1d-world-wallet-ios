import test from 'node:test';
import assert from 'node:assert/strict';
import {acquisitionFee, noidInputFee} from './fee-reference.mjs';

test('NOID acquisition pays a rounded 1% from the actual NOID output', () => {
  assert.deepEqual(acquisitionFee({grossNoidOutput:'1000000',minimumNoidReceive:'990000'}), {
    grossNoidOutput:'1000000',operatorFeeNoid:'10000',userReceivesNoid:'990000',minimumNoidReceive:'990000'});
  assert.equal(acquisitionFee({grossNoidOutput:'101',minimumNoidReceive:'99'}).operatorFeeNoid,'2');
});
test('a lower execution price cannot silently violate the approved net minimum', () => {
  assert.throws(()=>acquisitionFee({grossNoidOutput:'999999',minimumNoidReceive:'990000'}),/Minimum/);
});
test('a NOID input charge is deducted before the existing pool fee', () => {
  assert.deepEqual(noidInputFee({grossNoidInput:'1000000'}), {
    grossNoidInput:'1000000',operatorFeeNoid:'10000',poolInputNoid:'990000'});
});
test('malformed, overflowing and dust inputs fail closed', () => {
  for (const amount of ['1e6','01','-1','1.0','18446744073709551616']) {
    assert.throws(()=>acquisitionFee({grossNoidOutput:amount,minimumNoidReceive:'0'}));
  }
  assert.throws(()=>acquisitionFee({grossNoidOutput:'1',minimumNoidReceive:'0'}),/consumes/);
  assert.throws(()=>noidInputFee({grossNoidInput:'0'}),/Empty/);
});
