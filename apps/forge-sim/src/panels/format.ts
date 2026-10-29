const nf = new Map<number, Intl.NumberFormat>();
const numberFormat = (digits: number) => {
  let f = nf.get(digits);
  if (!f) {
    f = new Intl.NumberFormat('en-US', { minimumFractionDigits: digits, maximumFractionDigits: digits });
    nf.set(digits, f);
  }
  return f;
};

/** A display float with fixed decimals and thousands separators. */
export const num = (n: number, digits = 2): string => numberFormat(digits).format(Number.isFinite(n) ? n : 0);

/** Compact amounts for axis ticks (0, 950, 1.2K, 3.4M). */
export function compact(n: number): string {
  const a = Math.abs(n);
  if (a >= 1e6) return `${num(n / 1e6, a >= 1e7 ? 0 : 1)}M`;
  if (a >= 1e3) return `${num(n / 1e3, a >= 1e4 ? 0 : 1)}K`;
  return num(n, a >= 100 ? 0 : a >= 10 ? 1 : 2);
}

export const hours = (h: number): string => (h >= 24 && h % 24 === 0 ? `${h / 24}d` : `${h}h`);

/** Interpolated forge colour for a 0..1 heat fraction, read from the theme tokens. */
export function heatColor(frac: number): string {
  const stops = [0, 1, 2, 3, 4, 5].map((i) => `var(--heat-${i})`);
  const x = Math.min(0.9999, Math.max(0, frac)) * (stops.length - 1);
  const i = Math.floor(x);
  const t = Math.round((x - i) * 100);
  return `color-mix(in oklab, ${stops[i]} ${100 - t}%, ${stops[i + 1]})`;
}
