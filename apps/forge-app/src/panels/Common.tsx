import type { ReactNode } from 'react';
import { explorerTx } from '../chain';
import { DEFAULT_SLIPPAGE_BPS, MAX_SLIPPAGE_BPS, type Assessment } from '../policy';

/** Slippage in bps: the default, two steps up, and the cap. Above the default asks; above the cap is not offered. */
export function Slippage({ bps, set }: { bps: number; set: (b: number) => void }) {
  const options = [DEFAULT_SLIPPAGE_BPS, 100, MAX_SLIPPAGE_BPS];
  return (
    <div className="field">
      <span className="label">
        <span>Slippage</span>
        <output>{(bps / 100).toFixed(2)}%</output>
      </span>
      <div className="seg" role="group" aria-label="Slippage">
        {options.map((o) => (
          <button key={o} type="button" aria-pressed={bps === o} onClick={() => set(o)}>
            {(o / 100).toFixed(o < 100 ? 1 : 0)}%{o === DEFAULT_SLIPPAGE_BPS ? ' · default' : ''}
          </button>
        ))}
      </div>
    </div>
  );
}

export function Nudges({ a }: { a: Assessment }) {
  if (a.notes.length === 0) return null;
  const tone = a.level === 'blocked' ? 'bad' : a.level === 'ok' ? '' : 'warn';
  return (
    <div className="nudges">
      {a.notes.map((n) => (
        <div key={n} className={`nudge ${tone}`} role={a.level === 'blocked' ? 'alert' : undefined}>
          <span className="ico" aria-hidden="true">{a.level === 'blocked' ? '!' : 'i'}</span>
          <span>{n}</span>
        </div>
      ))}
    </div>
  );
}

export type TxState =
  | { kind: 'idle' }
  | { kind: 'pending'; label: string }
  | { kind: 'done'; label: string; hashes: string[] }
  | { kind: 'failed'; label: string; message: string };

export function TxStatus({ s }: { s: TxState }) {
  if (s.kind === 'idle') return null;
  if (s.kind === 'pending') return <p className="tx pending" aria-live="polite">{s.label}: confirm in your wallet…</p>;
  if (s.kind === 'failed') return <p className="tx failed" role="alert">{s.label} failed: {s.message}</p>;
  return (
    <p className="tx done" aria-live="polite">
      {s.label} confirmed.{' '}
      {s.hashes.map((h, i) => (
        <a key={h} href={explorerTx(h)} target="_blank" rel="noreferrer">{i === s.hashes.length - 1 ? 'View' : 'Approval'}</a>
      ))}
    </p>
  );
}

export function Field({ label, aside, children }: { label: string; aside?: ReactNode; children: ReactNode }) {
  return (
    <div className="field">
      <span className="label"><span>{label}</span>{aside}</span>
      {children}
    </div>
  );
}

export const errorText = (e: unknown) =>
  (e as { shortMessage?: string }).shortMessage ?? (e as Error).message ?? String(e);

/** The contracts' revert names, said plainly. */
export const REASONS: Record<string, string> = {
  ZeroAmount: 'Enter an amount.',
  TooSmall: 'Too small to pay its fees.',
  ZeroOutput: 'Too small to buy anything.',
  ZeroLiquidity: 'Too small to mint any LP.',
  NoLiquidity: 'This pool has no liquidity yet.',
  ZapTooLarge: 'Far larger than the pool: swap and add separately.',
  MoreThanSupply: 'More LP than exists.',
};
