// pnpm config:hash — prints keccak256 of the canonical config JSON.
// With --expect, exits non-zero unless the hash matches the spec's published value.
import { CONFIG_PATH, canonicalize, keccakHex, loadConfig } from './canonical';

const SPEC_HASH_V5_3_1 = '0x9ecedb63d5d10951caaf506032a1cf6d14b9e2196f236e2d2a45c200870463f7';

const canon = canonicalize(loadConfig());
const hash = keccakHex(canon);
console.log(`config:  ${CONFIG_PATH}`);
console.log(`chars:   ${canon.length}`);
console.log(`bytes:   ${Buffer.byteLength(canon, 'utf8')}`);
console.log(`keccak:  ${hash}`);

if (process.argv.includes('--expect')) {
  const ok = hash === SPEC_HASH_V5_3_1;
  console.log(ok ? '✓ matches spec v5.3.1 hash' : `✗ expected ${SPEC_HASH_V5_3_1}`);
  process.exit(ok ? 0 : 1);
}
