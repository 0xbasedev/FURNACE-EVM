import { formatUnits, parseUnits } from 'viem';

/** A token amount for display: grouped, trimmed to `digits` decimals. */
export function amount(v: bigint, decimals: number, digits = 4): string {
  const s = formatUnits(v, decimals);
  const [i, f = ''] = s.split('.');
  const grouped = BigInt(i).toLocaleString('en-US');
  const frac = f.slice(0, digits).replace(/0+$/, '');
  return frac ? `${grouped}.${frac}` : grouped;
}

/** Parse what someone typed; anything unreadable is zero, never a throw. */
export function parseAmount(text: string, decimals: number): bigint {
  const t = text.replace(/,/g, '').trim();
  if (!/^\d*\.?\d*$/.test(t) || t === '' || t === '.') return 0n;
  try {
    return parseUnits(t, decimals);
  } catch {
    return 0n;
  }
}

export const pct = (ppm: bigint, digits = 2) => `${(Number(ppm) / 1e4).toFixed(digits)}%`;
export const short = (a: string) => `${a.slice(0, 6)}…${a.slice(-4)}`;
