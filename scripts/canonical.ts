// Independent canonical serialization + Keccak-256 (noble), used to cross-check
// the canonical package's own js-sha3 tooling. Spec rules: recursive key sort,
// array order preserved, compact JSON.stringify, Keccak-256 over UTF-8.
import { keccak_256 } from '@noble/hashes/sha3.js';
import { bytesToHex } from '@noble/hashes/utils.js';

const sortKeys = (v: unknown): unknown =>
  Array.isArray(v)
    ? v.map(sortKeys)
    : v !== null && typeof v === 'object'
      ? Object.fromEntries(Object.keys(v).sort().map((k) => [k, sortKeys((v as Record<string, unknown>)[k])]))
      : v;

export const canonicalize = (cfg: unknown): string => JSON.stringify(sortKeys(cfg));

export const keccakHex = (s: string): string => '0x' + bytesToHex(keccak_256(new TextEncoder().encode(s)));
