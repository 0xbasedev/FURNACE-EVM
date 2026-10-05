// pnpm canonical:sums — every file listed in canonical/SHA256SUMS.json must match
// byte-for-byte. The canonical package is imported unchanged; edits belong in a
// new named revision, never in place.
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';

const root = new URL('../canonical/', import.meta.url);
const sums = JSON.parse(readFileSync(new URL('SHA256SUMS.json', root), 'utf8'));
let bad = 0;
for (const [path, want] of Object.entries(sums)) {
  let got = 'MISSING';
  try { got = createHash('sha256').update(readFileSync(new URL(path, root))).digest('hex'); } catch { /* missing */ }
  if (got !== want) { bad++; console.log(`✗ ${path}`); }
}
console.log(bad ? `✗ ${bad} file(s) differ from SHA256SUMS.json` : `✓ ${Object.keys(sums).length} canonical files match SHA256SUMS.json`);
process.exit(bad ? 1 : 0);
