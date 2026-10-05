// Independent CreateX CREATE3 re-derivation for every MINED registry entry
// (msg.sender-guarded salt, 0x00 cross-chain flag). Unmined (null) entries are
// listed, not failed: v5.5 keeps them null on purpose until real salts are mined.
import { keccak_256 } from '@noble/hashes/sha3.js';
import { bytesToHex, concatBytes, hexToBytes } from '@noble/hashes/utils.js';
import furnaceConfig from '../canonical/furnace.config';

// keccak256 of CreateX's CREATE3 proxy init code.
const PROXY_INIT_CODE_HASH = hexToBytes('21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f');
const hex = (x: string) => hexToBytes(x.replace(/^0x/, ''));

export function create3Address(salt: string, deployer: string, factory: string): string {
  const s = hex(salt);
  const d = hex(deployer);
  if (s.length !== 32 || d.length !== 20) throw new Error('bad salt/deployer length');
  if (bytesToHex(s.slice(0, 20)) !== bytesToHex(d)) throw new Error('salt not bound to deployer');
  if (s[20] !== 0x00) throw new Error('salt cross-chain flag must be 0x00');
  const guarded = keccak_256(concatBytes(new Uint8Array(12), d, s));
  const proxy = keccak_256(concatBytes(new Uint8Array([0xff]), hex(factory), guarded, PROXY_INIT_CODE_HASH)).slice(12);
  return '0x' + bytesToHex(keccak_256(concatBytes(new Uint8Array([0xd6, 0x94]), proxy, new Uint8Array([0x01]))).slice(12));
}

const evm = furnaceConfig.deployment.evm;
let bad = 0;
const unmined: string[] = [];
for (const [name, c] of Object.entries<any>(evm.contracts)) {
  if (c.salt == null && c.address == null) { unmined.push(name); continue; }
  try {
    const derived = create3Address(c.salt, evm.deployer, evm.factory);
    const ok = derived === String(c.address).toLowerCase() && derived.slice(2, 6).toUpperCase() === c.prefix;
    if (!ok) bad++;
    console.log(`${ok ? '✓' : '✗'} ${name.padEnd(16)} ${derived}  ${c.prefix}`);
  } catch (e) {
    bad++;
    console.log(`✗ ${name.padEnd(16)} ${(e as Error).message}`);
  }
}
if (unmined.length) console.log(`· unmined (null, by design until pnpm mine:salts): ${unmined.join(', ')}`);
console.log(`deployer ${evm.deployer}${/^0x(11){20}$/i.test(evm.deployer) ? '  (PLACEHOLDER — addresses provisional)' : ''}`);
process.exit(bad ? 1 : 0);
