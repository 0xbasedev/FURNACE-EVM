#!/usr/bin/env node
// pnpm check:layout — ForgePool runs ForgePoolAnnex by DELEGATECALL in its own storage
// (ADR 0012), so the two must have exactly the same storage layout. Both inherit it from
// ForgePoolBase; this fails the build if either ever declares a state variable of its own,
// or if the layout moves away from the slots ForgeView decodes.
import { spawnSync } from 'node:child_process';

function layout(contract) {
  const r = spawnSync('node', ['tools/forge.mjs', 'inspect', contract, 'storageLayout', '--json'], { encoding: 'utf8' });
  if (r.status !== 0) {
    console.error(`check:layout: forge inspect ${contract} failed\n${r.stdout}${r.stderr}`);
    process.exit(1);
  }
  const { storage, types } = JSON.parse(r.stdout);
  // Compare what decides the bytes in storage: name, slot, offset and the type's encoding.
  const rows = storage.map((s) => [s.label, s.slot, s.offset, types[s.type].encoding, types[s.type].numberOfBytes, s.type]);
  return { rows, json: JSON.stringify(rows) };
}

const pool = layout('ForgePool');
const annex = layout('ForgePoolAnnex');
if (pool.json !== annex.json) {
  console.error('check:layout: ForgePool and ForgePoolAnnex storage layouts differ');
  console.error(' pool:', pool.json);
  console.error('annex:', annex.json);
  process.exit(1);
}
// ForgeView hardcodes these slots (ADR 0010).
const expected = { _occupancy: '6', _lapses: '7', _positions: '9', _lots: '10', _history: '11', _pending: '12', _tickets: '13', _slices: '14', _seals: '15', _owners: '16' };
for (const [label, slot] of Object.entries(expected)) {
  const row = pool.rows.find((r) => r[0] === label);
  if (!row || row[1] !== slot) {
    console.error(`check:layout: ${label} is at slot ${row?.[1]}, ForgeView expects ${slot}`);
    process.exit(1);
  }
}
console.log(`✓ ForgePool and ForgePoolAnnex share one storage layout (${pool.rows.length} variables); ForgeView's slots hold`);
