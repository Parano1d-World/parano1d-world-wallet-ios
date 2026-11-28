// Reference arithmetic for a proposed protocol upgrade. NOT a live NOID
// contract, quote source, authorization, escrow or transaction constructor.
// All values are exact base units. The proposed convenience fee is paid in
// NOID and must be included in the user's exact minimum-receive review.
const MAX_U64 = (1n << 64n) - 1n;
const BPS = 10_000n;
export const CONVENIENCE_BPS = 100n;

function units(value, name) {
  if (typeof value !== 'string' || !/^(0|[1-9][0-9]*)$/.test(value)) {
    throw new TypeError(`${name} must be an exact nonnegative decimal integer`);
  }
  const amount = BigInt(value);
  if (amount > MAX_U64) throw new RangeError(`${name} exceeds u64`);
  return amount;
}

function ceilDiv(n, d) { return (n + d - 1n) / d; }

export function acquisitionFee({ grossNoidOutput, minimumNoidReceive }) {
  const gross = units(grossNoidOutput, 'grossNoidOutput');
  const minimum = units(minimumNoidReceive, 'minimumNoidReceive');
  if (gross === 0n) throw new RangeError('Empty NOID fill');
  // Fee on delivered NOID: users acquiring their first NOID need no NOID
  // balance before the fill. Source-chain gas is separate.
  const fee = ceilDiv(gross * CONVENIENCE_BPS, BPS);
  if (fee >= gross) throw new RangeError('Fee consumes the fill');
  const net = gross - fee;
  if (net < minimum) throw new RangeError('Minimum NOID receive not met');
  return Object.freeze({grossNoidOutput: gross.toString(), operatorFeeNoid: fee.toString(),
    userReceivesNoid: net.toString(), minimumNoidReceive: minimum.toString()});
}

export function noidInputFee({ grossNoidInput }) {
  const gross = units(grossNoidInput, 'grossNoidInput');
  if (gross === 0n) throw new RangeError('Empty NOID input');
  const fee = ceilDiv(gross * CONVENIENCE_BPS, BPS);
  if (fee >= gross) throw new RangeError('Fee consumes the input');
  return Object.freeze({grossNoidInput:gross.toString(), operatorFeeNoid:fee.toString(),
    poolInputNoid:(gross-fee).toString()});
}
