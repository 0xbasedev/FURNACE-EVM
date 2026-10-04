// Recomputes every deployment.evm.contracts address from its salt via CreateX
// CREATE3 (msg.sender-guarded salt, 0x00 cross-chain flag) and checks the
// vanity prefix. Exits non-zero on any mismatch. Read-only: never writes config.
import { keccak_256 } from '@noble/hashes/sha3.js';
import { bytesToHex, concatBytes, hexToBytes } from '@noble/hashes/utils.js';
import { loadConfig } from './canonical';

// keccak256 of CreateX's CREATE3 proxy init code.
const PROXY_INIT_CODE_HASH = hexToBytes('21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f');
const hex = (x: string) => hexToBytes(x.replace(/^0x/, ''));

export function create3Address(salt: string, deployer: string, factory: string): string {
  const s = hex(salt);
  const d = hex(deployer);
  if (s.length !== 32 || d.length !== 20) throw new Error('bad salt/deployer length');
  if (bytesToHex(s.slice(0, 20)) !== bytesToHex(d)) throw new Error('salt not bound to deployer');
  if (s[20] !== 0x00) throw new Error('salt cross-chain flag must be 0x00');
  // CreateX _guard: keccak256(abi.encode(msg.sender, salt))
  const guarded = keccak_256(concatBytes(new Uint8Array(12), d, s));
  const proxy = keccak_256(concatBytes(new Uint8Array([0xff]), hex(factory), guarded, PROXY_INIT_CODE_HASH)).slice(12);
  return '0x' + bytesToHex(keccak_256(concatBytes(new Uint8Array([0xd6, 0x94]), proxy, new Uint8Array([0x01]))).slice(12));
}

const evm = loadConfig().deployment.evm;
let bad = 0;
for (const [name, c] of Object.entries<any>(evm.contracts)) {
  let derived = '';
  try {
    derived = create3Address(c.salt, evm.deployer, evm.factory);
  } catch (e) {
    console.log(`✗ ${name.padEnd(11)} ${(e as Error).message}`);
    bad++;
    continue;
  }
  const ok = derived === String(c.address).toLowerCase() && derived.slice(2, 6).toUpperCase() === c.prefix;
  if (!ok) bad++;
  console.log(`${ok ? '✓' : '✗'} ${name.padEnd(11)} ${derived}  ${c.prefix}`);
}
console.log(`\ndeployer ${evm.deployer}${/^0x(11){20}$/i.test(evm.deployer) ? '  (PLACEHOLDER — addresses provisional)' : ''}`);
process.exit(bad ? 1 : 0);
