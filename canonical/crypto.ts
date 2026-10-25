/** Offline identity calculations. These do not verify deployed code or key control. */
import sha3 from './vendor/js-sha3/sha3.cjs';

export function bytes(hex: string): Uint8Array {
  const s = hex.startsWith('0x') ? hex.slice(2) : hex;
  if (s.length % 2 || !/^[0-9a-f]*$/i.test(s)) throw new Error('Invalid hexadecimal bytes');
  return Uint8Array.from(s.match(/../g)?.map(x => parseInt(x, 16)) ?? []);
}
export function hex(data: Uint8Array): string {
  return [...data].map(x => x.toString(16).padStart(2, '0')).join('');
}
export function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0; for (const p of parts) { out.set(p, at); at += p.length; } return out;
}
export function keccak(data: string | Uint8Array): string { return '0x' + sha3.keccak_256(data); }
export function isEvmAddress(v: unknown): v is string { return typeof v === 'string' && /^0x[0-9a-fA-F]{40}$/.test(v); }
export function isNonzeroEvm(v: unknown): v is string { return isEvmAddress(v) && !/^0x0{40}$/i.test(v); }
export function checksum(address: string): string {
  if (!isEvmAddress(address)) throw new Error('Expected a 20-byte EVM address');
  const low = address.slice(2).toLowerCase(), hash = sha3.keccak_256(low);
  return '0x' + [...low].map((x, i) => parseInt(hash[i], 16) >= 8 ? x.toUpperCase() : x).join('');
}
export function isChecksummed(v: unknown): v is string { return isEvmAddress(v) && checksum(v) === v; }
export function isSolanaAddress(v: unknown): v is string {
  if (typeof v !== 'string' || v.length < 32 || v.length > 44) return false;
  const alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
  let n = 0n, zeros = 0;
  for (const ch of v) { const i = alphabet.indexOf(ch); if (i < 0) return false; n = n * 58n + BigInt(i); }
  for (const ch of v) { if (ch !== '1') break; zeros++; }
  let count = 0; while (n > 0n) { count++; n >>= 8n; }
  return zeros + count === 32;
}
export function predictCreate3(factory: string, sender: string, salt: string): string {
  if (!isNonzeroEvm(factory) || !isEvmAddress(sender) || !/^0x[0-9a-f]{64}$/i.test(salt)) throw new Error('Invalid CREATE3 inputs');
  if (salt.slice(2, 42).toLowerCase() !== sender.slice(2).toLowerCase() || salt.slice(42, 44) !== '00') throw new Error('Expected sender-guarded chain-independent salt');
  const proxyInitHash = bytes('21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f');
  const guarded = bytes(keccak(concat(new Uint8Array(12), bytes(sender), bytes(salt))));
  const proxy = bytes(keccak(concat(bytes('ff'), bytes(factory), guarded, proxyInitHash))).slice(12);
  return '0x' + hex(bytes(keccak(concat(bytes('d694'), proxy, bytes('01')))).slice(12));
}
export function canonical(value: unknown): string {
  function sort(v: unknown): unknown {
    if (Array.isArray(v)) return v.map(sort);
    if (v !== null && typeof v === 'object') return Object.fromEntries(Object.entries(v).filter(([, a]) => a !== undefined).sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0).map(([k, x]) => [k, sort(x)]));
    if (typeof v === 'number' && !Number.isFinite(v)) throw new Error('Cannot hash a non-finite number');
    return v;
  }
  return JSON.stringify(sort(value));
}
