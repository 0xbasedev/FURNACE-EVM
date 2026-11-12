// pnpm mainnet:gate — the LitVM mainnet readiness gate (docs/mainnet/litvm-readiness.md).
// Reads deployments/litvm-mainnet.gate.json and lists, in order, every blocker between this
// repository and a LitVM mainnet deployment. It deploys nothing, holds no key and signs nothing.
//
//   pnpm mainnet:gate                 every check, live ones against the record's RPC; exits 1 while blocked
//   pnpm mainnet:gate:check           offline: the record is well-formed and the gate is still blocked (CI)
//   tsx scripts/mainnet-gate.ts --record <path> [--live]   another record (a rehearsal against a testnet)
//
// There is deliberately no mainnet broadcast script: the testnet kit refuses every chain outside its
// testnet list, and a mainnet deployment needs the canonical deployment gate (canonical/DEPLOYMENT.md).
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { keccak_256 } from '@noble/hashes/sha3.js';
import { bytesToHex, hexToBytes } from '@noble/hashes/utils.js';
import cfg, { CREATEX_FACTORY, DEPLOYER as PLACEHOLDER_DEPLOYER } from '../canonical/furnace.config';

/** keccak256 of CreateX's runtime code, the same on Ethereum and LiteForge (see DeployTestnet.s.sol). */
export const CREATEX_CODEHASH = '0xbd8a7ea8cfca7b4e5f5041d7d4b17bc317c5ce42cfbc42066a00cf26b43eb53f';
/** The testnet kit's chains, which can never be the mainnet. */
const TESTNET_CHAIN_IDS = new Set([4441, 31337]);
const MODULE_SLOTS = ['Treasury', 'Guardian', 'Kindling', 'FeeRouter', 'Flow', 'Compounder', 'Deeds', 'MatchReserve', 'SealedPot', 'Valuation', 'PyreLedger', 'FeeRebate'] as const;
/** What each slot is on the testnet, for the blocker's wording. */
const TESTNET_NOTE: Record<(typeof MODULE_SLOTS)[number], string> = {
  Treasury: "on the testnet it is the operator's wallet",
  Guardian: "on the testnet it is the operator's wallet",
  Kindling: "on the testnet it is the operator's wallet",
  FeeRouter: "the Vent; on the testnet it is the operator's wallet",
  Flow: 'built (ADR 0016); the testnet kit deploys it, the mainnet needs its mined address',
  Compounder: "Flow's waiver caller, the Stoke-into-LP consumer; on the testnet it is the operator's wallet",
  Deeds: "on the testnet it is the operator's wallet",
  MatchReserve: "on the testnet it is the operator's wallet",
  SealedPot: "on the testnet it is the operator's wallet",
  Valuation: 'on the testnet it is a stand-in the operator sets',
  PyreLedger: "Relics' Pyre ledger; on the testnet it is a stand-in the operator sets",
  FeeRebate: "Relics' fee-rebate perk, read by Flow; on the testnet it is a stand-in the operator sets",
};
const RECORD_KEYS = ['network', 'status', 'chainId', 'rpcUrl', 'explorerUrl', 'sources', 'pairsTrustWindow', 'usdc', 'smelterQuote', 'deployer', 'modules', 'audits'];
const ADDRESS = /^0x[0-9a-fA-F]{40}$/;

export interface Audit { firm: string; reportUrl: string; date: string; commit: string }
export interface GateRecord {
  network: string; status: string;
  chainId: number | null; rpcUrl: string | null; explorerUrl: string | null; sources: string[];
  pairsTrustWindow: 'same-broadcast' | 'create2' | null;
  usdc: string | null; smelterQuote: string | null; deployer: string | null;
  modules: Record<(typeof MODULE_SLOTS)[number], string | null>;
  audits: Audit[];
}

/** Shape errors make the gate unusable, not merely blocked: they are reported separately. */
export function shapeErrors(r: any): string[] {
  const e: string[] = [];
  if (typeof r !== 'object' || r === null) return ['the record is not an object'];
  for (const k of Object.keys(r)) if (!RECORD_KEYS.includes(k)) e.push(`unknown field "${k}"`);
  for (const k of RECORD_KEYS) if (!(k in r)) e.push(`missing field "${k}"`);
  const nullable = (k: string, ok: (v: any) => boolean) => { if (r[k] !== null && !ok(r[k])) e.push(`"${k}" has the wrong type`); };
  nullable('chainId', (v) => Number.isInteger(v) && v > 0);
  nullable('rpcUrl', (v) => typeof v === 'string' && v.startsWith('https://'));
  nullable('explorerUrl', (v) => typeof v === 'string' && v.startsWith('https://'));
  nullable('pairsTrustWindow', (v) => v === 'same-broadcast' || v === 'create2');
  for (const k of ['usdc', 'smelterQuote', 'deployer']) nullable(k, (v) => typeof v === 'string' && ADDRESS.test(v));
  if (!Array.isArray(r.sources) || r.sources.some((s: any) => typeof s !== 'string')) e.push('"sources" must be a list of URLs');
  if (typeof r.modules !== 'object' || r.modules === null) e.push('"modules" must be an object');
  else {
    for (const k of Object.keys(r.modules)) if (!(MODULE_SLOTS as readonly string[]).includes(k)) e.push(`unknown module slot "${k}"`);
    for (const k of MODULE_SLOTS) {
      if (!(k in r.modules)) e.push(`missing module slot "${k}"`);
      else if (r.modules[k] !== null && !(typeof r.modules[k] === 'string' && ADDRESS.test(r.modules[k]))) e.push(`module "${k}" is not an address`);
    }
  }
  if (!Array.isArray(r.audits)) e.push('"audits" must be a list');
  else r.audits.forEach((a: any, i: number) => {
    if (typeof a?.firm !== 'string' || !a.firm) e.push(`audit ${i}: firm`);
    if (typeof a?.reportUrl !== 'string' || !a.reportUrl.startsWith('https://')) e.push(`audit ${i}: reportUrl`);
    if (typeof a?.date !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(a.date)) e.push(`audit ${i}: date (YYYY-MM-DD)`);
    if (typeof a?.commit !== 'string' || !/^[0-9a-f]{40}$/.test(a.commit)) e.push(`audit ${i}: commit (a full 40-hex commit)`);
  });
  return e;
}

export interface Rpc { chainId(): string; code(addr: string): string; call(data: string, to?: string): string }

function curlRpc(url: string): Rpc {
  let id = 0;
  const req = (method: string, params: unknown[]) => {
    const body = JSON.stringify({ jsonrpc: '2.0', id: ++id, method, params });
    const out = execFileSync('curl', ['-sS', '--max-time', '20', '-H', 'content-type: application/json', '--data', body, url], { encoding: 'utf8' });
    const res = JSON.parse(out);
    if (res.error) throw new Error(`${method}: ${res.error.message ?? JSON.stringify(res.error)}`);
    return res.result as string;
  };
  return {
    chainId: () => req('eth_chainId', []),
    code: (addr) => req('eth_getCode', [addr, 'latest']),
    call: (data, to) => req('eth_call', [to ? { to, data } : { data }, 'latest']),
  };
}

// Opcode probes, run as eth_call creation code: each must return 42.
const PROBES: [string, string][] = [
  ['PUSH0', '0x602a5f5260205ff3'],
  ['TSTORE/TLOAD', '0x602a5f5d5f5c5f5260205ff3'],
  ['MCOPY', '0x602a5f5260205f60205e60206020f3'],
];

const keccakHex = (hex: string) => '0x' + bytesToHex(keccak_256(hexToBytes(hex.replace(/^0x/, ''))));
const hasCode = (rpc: Rpc, addr: string) => rpc.code(addr).replace(/^0x/, '').length > 0;

/**
 * The blockers, in the order they must be cleared. `rpc` is used only when given (live mode);
 * without it every on-chain fact counts as unverified.
 */
export function blockers(r: GateRecord, opts: { rpc?: Rpc; head?: string } = {}): string[] {
  const b: string[] = [];
  const { rpc } = opts;
  // 1. The chain itself: published, verified, and not a testnet.
  if (r.chainId === null || r.rpcUrl === null) b.push('chain: LitVM mainnet has no published chain id and RPC in the record');
  else if (TESTNET_CHAIN_IDS.has(r.chainId)) b.push(`chain: ${r.chainId} is a testnet chain id`);
  if (r.sources.length === 0) b.push('chain: no source is recorded for the chain facts (the official network-configuration page)');
  let live = false;
  if (r.chainId !== null && r.rpcUrl !== null) {
    if (!rpc) b.push('chain: the chain id is not verified on the RPC (run pnpm mainnet:gate, which queries it)');
    else {
      try {
        const got = parseInt(rpc.chainId(), 16);
        if (got !== r.chainId) b.push(`chain: the RPC reports chain id ${got}, the record says ${r.chainId}`);
        else live = true;
      } catch (e) { b.push(`chain: the RPC did not answer eth_chainId (${(e as Error).message})`); }
    }
  }
  // 2. The canonical decision: the canonical config must list the chain (a config and hash change).
  const listed = r.chainId !== null && cfg.chains.some((c: any) => c.vm === 'evm' && c.enabled && c.chainId === r.chainId);
  if (!listed) b.push('canonical: the canonical config does not list LitVM mainnet as an enabled chain (the v5.5 launch gate is Ethereum-only; adding it changes the config hash)');
  // 3. The factory and the opcodes the contracts need.
  if (live && rpc) {
    try {
      const code = rpc.code(CREATEX_FACTORY);
      const h = code.replace(/^0x/, '').length ? keccakHex(code) : 'no code';
      if (h !== CREATEX_CODEHASH) b.push(`factory: CreateX at ${CREATEX_FACTORY} has runtime hash ${h}, expected ${CREATEX_CODEHASH}`);
    } catch (e) { b.push(`factory: could not read CreateX's code (${(e as Error).message})`); }
    for (const [name, data] of PROBES) {
      try {
        if (BigInt(rpc.call(data)) !== 42n) b.push(`opcodes: the ${name} probe did not return 42`);
      } catch (e) { b.push(`opcodes: the ${name} probe reverted (${(e as Error).message})`); }
    }
  } else b.push('factory: CreateX\'s runtime hash and the Cancun opcodes (PUSH0, TSTORE/TLOAD, MCOPY) are not verified on the chain');
  // 4. The modules the testnet gives to an operator wallet must be real contracts.
  for (const slot of MODULE_SLOTS) {
    const a = r.modules[slot];
    if (a === null) b.push(`modules: ${slot} has no address (${TESTNET_NOTE[slot]})`);
    else if (live && rpc && !hasCode(rpc, a)) b.push(`modules: ${slot} at ${a} has no code on the chain`);
  }
  // 5. The pairs (ADR 0015).
  if (r.pairsTrustWindow === null) b.push('pairs: no decision on the trust window (deploy the pairs in the same broadcast, or move them to CREATE2, a change to §23)');
  for (const [k, what] of [['usdc', 'USDC (BlastPool\'s quote and pool 3\'s stake)'], ['smelterQuote', 'SmelterPool\'s quote (bridged WETH or wrapped zkLTC)']] as const) {
    const a = r[k];
    if (a === null) b.push(`pairs: no address for ${what}`);
    else if (live && rpc && !hasCode(rpc, a)) b.push(`pairs: ${what} at ${a} has no code on the chain`);
  }
  // 6. The deployer: a real key holder, not the canonical placeholder.
  if (r.deployer === null) b.push('deployer: no deployer is recorded');
  else {
    if (r.deployer.toLowerCase() === PLACEHOLDER_DEPLOYER.toLowerCase()) b.push('deployer: the record names the canonical placeholder deployer');
    if (live && rpc && hasCode(rpc, r.deployer)) b.push('deployer: the deployer has code; CreateX salts bind an EOA sender here');
  }
  // 7. Audits: two independent firms, of the commit being deployed.
  const firms = new Set(r.audits.map((a) => a.firm.trim().toLowerCase()));
  if (firms.size < 2) b.push(`audits: ${firms.size} independent audit(s) recorded; the spec requires at least two before activation`);
  if (opts.head && r.audits.some((a) => a.commit !== opts.head)) b.push(`audits: an audit covers another commit than the one checked out (${opts.head.slice(0, 12)})`);
  return b;
}

function main() {
  const args = process.argv.slice(2);
  const at = args.indexOf('--record');
  const path = at >= 0 ? args[at + 1] : 'deployments/litvm-mainnet.gate.json';
  const expectBlocked = args.includes('--expect-blocked');
  const offline = expectBlocked || args.includes('--offline');
  const record = JSON.parse(readFileSync(path, 'utf8'));
  const shape = shapeErrors(record);
  if (shape.length) {
    console.error(`✗ ${path} is malformed:\n  - ${shape.join('\n  - ')}`);
    process.exit(2);
  }
  const r = record as GateRecord;
  let head: string | undefined;
  try { head = execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(); } catch { /* not a checkout */ }
  const rpc = !offline && r.rpcUrl ? curlRpc(r.rpcUrl) : undefined;
  const list = blockers(r, { rpc, head });
  if (expectBlocked) {
    if (list.length === 0) {
      console.error('✗ the LitVM mainnet gate reports no blockers offline; remove --expect-blocked only after a live run and the canonical deployment gate');
      process.exit(1);
    }
    console.log(`✓ LitVM mainnet gate: blocked, as it must be today (${list.length} blockers; pnpm mainnet:gate lists them)`);
    return;
  }
  if (list.length) {
    console.log(`LitVM mainnet gate: BLOCKED (${list.length})`);
    list.forEach((x, i) => console.log(`  ${String(i + 1).padStart(2)}. ${x}`));
    process.exit(1);
  }
  console.log('LitVM mainnet gate: no blockers in this record. This is not an audit or deployment approval; the canonical deployment gate still applies.');
}

if (process.argv[1] && /mainnet-gate\.ts$/.test(process.argv[1])) main();
