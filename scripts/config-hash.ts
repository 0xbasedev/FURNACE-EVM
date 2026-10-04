// pnpm config:hash — prints keccak256 of the canonical config JSON (spec §23).
// Source: the default export of furnace.config.ts.
// --expect  exit non-zero unless the hash equals the spec's published v5.3.1 hash
//           AND config/furnace.config.canonical.json mirrors the .ts exactly.
import furnaceConfig from '../furnace.config';
import { CONFIG_PATH, canonicalize, keccakHex, loadConfig } from './canonical';

const SPEC_HASH_V5_3_1 = '0x9ecedb63d5d10951caaf506032a1cf6d14b9e2196f236e2d2a45c200870463f7';

const canon = canonicalize(furnaceConfig);
const hash = keccakHex(canon);
console.log(`source:  furnace.config.ts`);
console.log(`chars:   ${canon.length}`);
console.log(`bytes:   ${Buffer.byteLength(canon, 'utf8')}`);
console.log(`keccak:  ${hash}`);

if (process.argv.includes('--expect')) {
  const hashOk = hash === SPEC_HASH_V5_3_1;
  const mirrorOk = canonicalize(loadConfig(CONFIG_PATH)) === canon;
  console.log(hashOk ? '✓ matches spec v5.3.1 hash' : `✗ expected ${SPEC_HASH_V5_3_1}`);
  console.log(mirrorOk ? `✓ ${CONFIG_PATH} mirrors furnace.config.ts` : `✗ ${CONFIG_PATH} is stale — regenerate it from furnace.config.ts`);
  process.exit(hashOk && mirrorOk ? 0 : 1);
}
