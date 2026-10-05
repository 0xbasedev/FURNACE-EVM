// pnpm config:hash — independent recomputation of the canonical config hash.
// --expect  exit non-zero unless it equals both the package manifest
//           (canonical/results/manifest.json) and the RECORDED entry for the version.
import { readFileSync } from 'node:fs';
import furnaceConfig from '../canonical/furnace.config';
import { canonicalize, keccakHex } from './canonical';

/** Every adopted revision. History: docs/REVISIONS.md. */
const RECORDED: Record<string, string> = {
  '5.3.1': '0x9ecedb63d5d10951caaf506032a1cf6d14b9e2196f236e2d2a45c200870463f7',
  '5.3.2': '0xbaeb97a2a062763bc986f78e270812214d439bba2044fcdbdc99ad5c00b17270', // superseded, never deployed
  '5.5.0': '0x24f38f4aa11919503354bb5f8263978c7b3edc29723760928cb1eecdbafbe5ae',
};

const canon = canonicalize(furnaceConfig);
const hash = keccakHex(canon);
console.log(`source:  canonical/furnace.config.ts v${furnaceConfig.version}`);
console.log(`bytes:   ${Buffer.byteLength(canon, 'utf8')}`);
console.log(`keccak:  ${hash}`);

if (process.argv.includes('--expect')) {
  const manifest = JSON.parse(readFileSync(new URL('../canonical/results/manifest.json', import.meta.url), 'utf8'));
  const checks: [string, boolean][] = [
    [`matches RECORDED v${furnaceConfig.version}`, RECORDED[furnaceConfig.version] === hash],
    ['matches canonical/results/manifest.json fullConfigHash', manifest.fullConfigHash === hash && manifest.version === furnaceConfig.version],
  ];
  for (const [what, ok] of checks) console.log(`${ok ? '✓' : '✗'} ${what}`);
  process.exit(checks.every(([, ok]) => ok) ? 0 : 1);
}
