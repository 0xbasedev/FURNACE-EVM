import { parseUnits } from '@canonical/accounting';
import { WAD } from './config';

/** A decimal string (as typed) to 18-decimal base units; invalid input is 0. */
export function toWei(text: string): bigint {
  const clean = text.replace(/[,_\s]/g, '');
  if (!/^\d*(\.\d*)?$/.test(clean) || clean === '' || clean === '.') return 0n;
  const [int, frac = ''] = clean.split('.');
  return parseUnits(`${int || '0'}.${frac.slice(0, 18) || '0'}`, 18);
}

/** Base units to a float for charts and tweens (display only). */
export const toFloat = (wei: bigint): number => Number(wei / 10n ** 9n) / 1e9;

/** Base units to a grouped decimal string with `digits` places (floored, never rounded up). */
export function fmt(wei: bigint, digits = 2): string {
  const neg = wei < 0n;
  const abs = neg ? -wei : wei;
  const scale = 10n ** BigInt(18 - digits);
  const units = abs / scale;
  const int = units / 10n ** BigInt(digits);
  const frac = digits > 0 ? (units % 10n ** BigInt(digits)).toString().padStart(digits, '0') : '';
  const grouped = int.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  return `${neg ? '−' : ''}${grouped}${digits > 0 ? `.${frac}` : ''}`;
}

export const days = (seconds: bigint | number): number => Number(seconds) / 86400;
export const one = WAD;
