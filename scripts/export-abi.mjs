#!/usr/bin/env node
// pnpm abi — writes the ABIs a frontend or indexer needs to abi/<Contract>.json, plus
// abi/index.json, from forge's build output (run `pnpm build:sol` first).
// pnpm abi:check — fails if the committed files differ from the build (CI runs it after the tests).
// ForgePool's ABI already carries the annex's functions: the pool keeps a stub for each (ADR 0012).
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';

const CONTRACTS = [
  ['EmberToken', 'EmberToken.sol'],
  ['Mantle', 'Mantle.sol'],
  ['ForgePool', 'ForgePool.sol'],
  ['ForgeEmissions', 'ForgeEmissions.sol'],
  ['Boost', 'Boost.sol'],
  ['ForgeLens', 'ForgeLens.sol'],
  ['EmberPair', 'EmberPair.sol'],
  ['Flow', 'Flow.sol'],
  ['Vent', 'Vent.sol'],
  ['Kindling', 'Kindling.sol'],
  ['GenesisFeeEscrow', 'GenesisFeeEscrow.sol'],
  ['PermanentLiquidity', 'PermanentLiquidity.sol'],
  // Testnet-only stand-ins (contracts/script/testnet): never part of a canonical deployment.
  ['TestnetToken', 'TestnetStandIns.sol'],
  ['TestnetValuation', 'TestnetStandIns.sol'],
  ['TestnetPyreLedger', 'TestnetStandIns.sol'],
  ['TestnetFeeRebate', 'TestnetStandIns.sol'],
  ['TestnetFounders', 'TestnetStandIns.sol'],
];
const TESTNET_ONLY = new Set(['TestnetToken', 'TestnetValuation', 'TestnetPyreLedger', 'TestnetFeeRebate', 'TestnetFounders']);
const check = process.argv.includes('--check');

const files = new Map();
const index = {};
for (const [name, source] of CONTRACTS) {
  const artifact = `out/${source}/${name}.json`;
  if (!existsSync(artifact)) {
    console.error(`abi: ${artifact} missing; run pnpm build:sol first`);
    process.exit(1);
  }
  const { abi } = JSON.parse(readFileSync(artifact, 'utf8'));
  files.set(`abi/${name}.json`, JSON.stringify(abi, null, 2) + '\n');
  index[name] = { file: `${name}.json`, testnetOnly: TESTNET_ONLY.has(name) };
}
files.set('abi/index.json', JSON.stringify(index, null, 2) + '\n');

let stale = 0;
if (!check) mkdirSync('abi', { recursive: true });
for (const [path, body] of files) {
  if (check) {
    const current = existsSync(path) ? readFileSync(path, 'utf8') : '';
    if (current !== body) {
      console.error(`abi: ${path} is stale; run pnpm build:sol && pnpm abi`);
      stale++;
    }
  } else {
    writeFileSync(path, body);
  }
}
if (stale) process.exit(1);
console.log(check ? `✓ ${files.size} ABI files match the build` : `wrote ${files.size} ABI files to abi/`);
