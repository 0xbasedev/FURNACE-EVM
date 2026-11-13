import { useMemo, useState } from 'react';
import { Num } from '@sim/motion/motion';
import type { Deployment } from '../deployment';
import type { Market } from '../useMarket';
import { quoteZap, tierName } from '../quote';
import { assess, DEFAULT_SLIPPAGE_BPS, IMPACT_BLOCK_PPM, IMPACT_WARN_PPM, withSlippage } from '../policy';
import { amount, parseAmount, pct } from '../format';
import { clients, deadlineIn, zapAndStake, type Eip1193 } from '../wallet';
import { Field, Nudges, REASONS, Slippage, TxStatus, errorText, type TxState } from './Common';

const PAIRS = [
  { name: 'Blast Furnace', quote: 'tUSDC', quoteDecimals: 6, receipt: 'tBLAST-LP' },
  { name: 'Smelter', quote: 'tWETH', quoteDecimals: 18, receipt: 'tSMELT-LP' },
] as const;

/** Zap & Stake: one token in, LP staked into its Forge pool, with no deposit fee (spec v5.5 §4). */
export function ZapPanel({ d, market, provider, account, canSend, position, setPosition, onDone }: {
  d: Deployment | null; market: Market; provider: Eip1193 | null; account: `0x${string}` | null;
  canSend: string | null; position: bigint; setPosition: (p: bigint) => void; onDone: () => void;
}) {
  const [pair, setPair] = useState(0);
  const [fromQuote, setFromQuote] = useState(true);
  const [text, setText] = useState('100');
  const [bps, setBps] = useState(DEFAULT_SLIPPAGE_BPS);
  const [tx, setTx] = useState<TxState>({ kind: 'idle' });
  const p = PAIRS[pair];
  const decimals = fromQuote ? p.quoteDecimals : 18;
  const amountIn = parseAmount(text, decimals);
  const q = useMemo(() => quoteZap(market.pairs[pair], fromQuote, amountIn, market.share), [market, pair, fromQuote, amountIn]);
  const a = assess({ impactPpm: q.ok ? q.impactPpm : 0n, slippageBps: bps });
  const minLiquidity = q.ok ? withSlippage(q.liquidity, bps) : 0n;
  const lp = (v: bigint) => Number(v) / 1e18;
  const blocked = a.level === 'blocked' || !q.ok || amountIn === 0n;

  const submit = async () => {
    if (!d || !account || !q.ok) return;
    setTx({ kind: 'pending', label: 'Zap & stake' });
    try {
      const r = await zapAndStake(clients(provider, account), d, {
        pair, fromQuote, amountIn, minLiquidity, position, deadline: deadlineIn(20 * 60),
      });
      setTx({ kind: 'done', label: `Staked ${amount(r.liquidity, 18)} ${p.receipt} in position #${r.position}`, hashes: r.hashes });
      setPosition(r.position);
      onDone();
    } catch (e) {
      setTx({ kind: 'failed', label: 'Zap & stake', message: errorText(e) });
    }
  };

  return (
    <section className="panel wide hero" aria-labelledby="zap-h">
      <header>
        <span className="eyebrow">Recommended route</span>
        <h2 id="zap-h">Zap &amp; stake</h2>
        <p className="lede">One token in. Flow swaps the exact share, adds liquidity, and stakes every receipt in the Forge, with no deposit fee. Your Heat starts now.</p>
      </header>
      <div className="row">
        <div className="seg" role="group" aria-label="Pool">
          {PAIRS.map((x, i) => (
            <button key={x.name} type="button" aria-pressed={pair === i} onClick={() => setPair(i)}>{x.name} · EMBER/{x.quote}</button>
          ))}
        </div>
        <div className="seg" role="group" aria-label="Pay with">
          <button type="button" aria-pressed={fromQuote} onClick={() => setFromQuote(true)}>Pay {p.quote}</button>
          <button type="button" aria-pressed={!fromQuote} onClick={() => setFromQuote(false)}>Pay EMBER</button>
        </div>
      </div>
      <Field label={`Amount (${fromQuote ? p.quote : 'EMBER'})`} aside={<span className="unit">{tierName(market.share)}</span>}>
        <input className="input big" inputMode="decimal" value={text} onChange={(e) => setText(e.target.value)} aria-label="Amount" />
      </Field>

      <div className="routes">
        <article className="route recommended" aria-label="Through Flow">
          <span className="pill good">Flow · fee-free stake</span>
          <div className="route-v"><Num value={q.ok ? lp(q.liquidity) : 0} format={(n) => n.toFixed(4)} /> <span className="unit">{p.receipt} staked</span></div>
          <p className="s">Every receipt the zap mints goes into your position.</p>
        </article>
        <article className="route" aria-label="Deposit directly">
          <span className="pill">Deposit · 1% fee</span>
          <div className="route-v muted"><Num value={q.ok ? lp(q.depositNet) : 0} format={(n) => n.toFixed(4)} /> <span className="unit">{p.receipt} staked</span></div>
          <p className="s">The same LP deposited by hand loses 1% to the deposit fee.</p>
        </article>
      </div>
      {q.ok ? (
        <div className="figures">
          <div className="figure"><span className="k">You keep</span><span className="v"><Num value={lp(q.saved)} format={(n) => `+${n.toFixed(4)}`} /></span><span className="s">{p.receipt} vs depositing</span></div>
          <div className="figure"><span className="k">Swapped first</span><span className="v">{amount(q.swapped, decimals)}</span><span className="s">{fromQuote ? p.quote : 'EMBER'}, the exact split</span></div>
          <div className="figure"><span className="k">Price impact</span><span className={`v ${q.impactPpm > IMPACT_BLOCK_PPM ? 'bad-text' : q.impactPpm > IMPACT_WARN_PPM ? 'warn-text' : ''}`}>{pct(q.impactPpm)}</span><span className="s">of the swap leg</span></div>
          <div className="figure"><span className="k">Dust returned</span><span className="v">{amount(q.refundQuote, p.quoteDecimals, 6)}</span><span className="s">{p.quote} · {amount(q.refundEmber, 18, 6)} EMBER</span></div>
        </div>
      ) : (
        <div className="nudge warn"><span className="ico" aria-hidden="true">i</span><span>{REASONS[q.reason] ?? q.reason}</span></div>
      )}
      <div className="row split">
        <Slippage bps={bps} set={setBps} />
        <Field label="Stake into">
          <div className="seg" role="group" aria-label="Stake into">
            <button type="button" aria-pressed={position === 0n} onClick={() => setPosition(0n)}>New position</button>
            {position !== 0n && <button type="button" aria-pressed="true">Position #{position.toString()}</button>}
          </div>
          {position === 0n && <span className="unit">To add to one, pick it under Positions.</span>}
        </Field>
      </div>
      <Nudges a={a} />
      <div className="row">
        <button type="button" className="btn primary big" disabled={blocked || canSend !== null} onClick={submit}
          title={canSend ?? undefined}>
          {canSend ?? `Zap & stake ${text || 0} ${fromQuote ? p.quote : 'EMBER'}`}
        </button>
        {q.ok && <span className="unit">Minimum {amount(minLiquidity, 18)} {p.receipt} or it reverts.</span>}
      </div>
      <TxStatus s={tx} />
    </section>
  );
}
