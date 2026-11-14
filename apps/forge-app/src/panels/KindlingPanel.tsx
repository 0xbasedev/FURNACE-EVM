import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import gsap from 'gsap';
import type { Address } from 'viem';
import { HoldButton, Num, reducedMotion } from '@sim/motion/motion';
import type { Deployment } from '../deployment';
import { amount, parseAmount } from '../format';
import { clients, contribute, kindlingCall, kindlingState, type Eip1193 } from '../wallet';
import {
  admit, bountyOf, cancelPreview, canFail, clock, demoState, headroom, openingPrice, phaseOf, progressPpm,
  shareOf, usd, Status, VENUE_REASON, type KindlingState, type Phase,
} from '../kindling';
import { Field, TxStatus, errorText, type TxState } from './Common';

const ZERO = '0x0000000000000000000000000000000000000000' as Address;
const nowS = () => BigInt(Math.floor(Date.now() / 1000));

/** The chain's clock, to the second, for countdowns and phase changes. */
function useNow(): bigint {
  const [now, setNow] = useState(nowS);
  useEffect(() => {
    const t = setInterval(() => setNow(nowS()), 1000);
    return () => clearInterval(t);
  }, []);
  return now;
}

const PHASE_LABEL: Record<Phase, string> = {
  pending: 'Opens soon',
  open: 'Open',
  settleable: 'Ready to settle',
  waiting: 'Waiting on BlastPool',
  short: 'Below the minimum',
  expired: 'Settlement window closed',
  settled: 'Settled',
  failed: 'Refunds open',
};

/**
 * Kindling, the genesis event (spec v5.5 §3; ADR 0021). The screen leads with the one action that
 * moves the event forward in each phase: contribute while it is open, settle (and earn the bounty)
 * once it can, end it when it cannot, then claim the position or the refund. Cancelling is possible
 * until settlement, but it sits behind a disclosure and a press-and-hold, with what stays escrowed.
 */
export function KindlingPanel({ d, provider, account, onLiteForge, onDone, tick }: {
  d: Deployment | null; provider: Eip1193 | null; account: Address | null; onLiteForge: boolean;
  onDone: () => void; tick: number;
}) {
  const now = useNow();
  const live = d?.kindling != null;
  const [demo] = useState(() => demoState(nowS()));
  const [chain, setChain] = useState<KindlingState | null>(null);
  const [readError, setReadError] = useState<string | null>(null);
  const [text, setText] = useState('100');
  const [cancelText, setCancelText] = useState('');
  const [tx, setTx] = useState<TxState>({ kind: 'idle' });

  // Reads: on mount, after each transaction, and every 15 seconds while the event is live.
  useEffect(() => {
    if (!d?.kindling) return;
    let stop = false;
    const load = () => kindlingState(clients(onLiteForge ? provider : null, account ?? ZERO).read, d, account ?? ZERO)
      .then((s) => { if (!stop) { setChain(s); setReadError(null); } })
      .catch((e) => { if (!stop) setReadError(errorText(e)); });
    load();
    const t = setInterval(load, 15_000);
    return () => { stop = true; clearInterval(t); };
  }, [d, provider, account, onLiteForge, tick]);

  const s = live ? chain : demo;
  const canSend = !d ? 'Not deployed yet: this is a simulated event'
    : !live ? 'Kindling is not deployed in this testnet (the operator stands in for it)'
    : !account ? 'Connect a wallet'
    : !onLiteForge ? 'Switch to LiteForge'
    : null;

  if (!s) {
    return (
      <section className="panel wide hero" aria-labelledby="kindling-h">
        <header><span className="eyebrow">The genesis event</span><h2 id="kindling-h">Kindling</h2></header>
        <p className="lede">{readError ? `Could not read Kindling: ${readError}` : 'Reading the event…'}</p>
      </section>
    );
  }

  const phase = phaseOf(s, now);
  const run = async (label: string, f: () => Promise<{ hashes: string[] }>, done: string) => {
    if (!d || !account) return;
    setTx({ kind: 'pending', label });
    try {
      const r = await f();
      setTx({ kind: 'done', label: done, hashes: r.hashes });
      onDone();
    } catch (e) {
      setTx({ kind: 'failed', label, message: errorText(e) });
    }
  };
  const c = () => clients(provider, account!);

  return (
    <section className="panel wide hero kindling" aria-labelledby="kindling-h">
      <header>
        <span className="eyebrow">The genesis event{live ? '' : ' · simulated'}</span>
        <h2 id="kindling-h">Kindling</h2>
        <p className="lede">
          Twenty-four hours, USDC only. At the close, the 420,000-EMBER seed and the net raise open BlastPool at a price
          the raise itself sets; 90% of that LP becomes contributors’ staked positions in Forge pool 0, and 10% is locked for good.
        </p>
      </header>

      <Countdown s={s} phase={phase} now={now} />
      <RaiseBar s={s} />

      <div className="figures">
        <div className="figure"><span className="k">Raised</span><Num className="v" value={Number(s.accepted) / 10 ** s.decimals} format={(n) => `$${Math.round(n).toLocaleString('en-US')}`} /><span className="s">accepted gross</span></div>
        <div className="figure"><span className="k">Into the pool</span><Num className="v" value={Number(s.totalNet) / 10 ** s.decimals} format={(n) => `$${Math.round(n).toLocaleString('en-US')}`} /><span className="s">net, after the 3% fee</span></div>
        <div className="figure"><span className="k">{phase === 'settled' ? 'Opened at' : 'Opening price now'}</span><span className="v">{s.totalNet > 0n ? `$${amount(openingPrice(s.totalNet), s.decimals, 4)}` : '—'}</span><span className="s">per EMBER, set by the raise</span></div>
        {(phase === 'settleable' || phase === 'waiting' || phase === 'open') && (
          <div className="figure"><span className="k">Settler’s bounty</span><span className="v">{usd(bountyOf(s), s.decimals)}</span><span className="s">5 bps, paid from the fees</span></div>
        )}
      </div>

      {phase === 'open' || phase === 'pending'
        ? <ContributeForm s={s} now={now} text={text} setText={setText} canSend={canSend}
            onSubmit={(gross) => run('Contribute', () => contribute(c(), d!, gross), `Contributed ${usd(gross, s.decimals)}`)} />
        : <NextStep s={s} phase={phase} canSend={canSend}
            onSettle={() => run('Settle Kindling', () => kindlingCall(c(), d!, { kind: 'settle' }), `Settled: you earned ${usd(bountyOf(s), s.decimals)}`)}
            onFail={() => run('End the event', () => kindlingCall(c(), d!, { kind: 'fail' }), 'The event ended: refunds are open')}
            onMaterialize={() => run('Claim your position', () => kindlingCall(c(), d!, { kind: 'materialize' }), 'Your position is open in Forge pool 0')}
            onRefund={() => run('Refund', () => kindlingCall(c(), d!, { kind: 'refund' }), `Refunded ${usd(s.refundable, s.decimals)}`)} />}

      {s.me.gross > 0n || s.me.fee > 0n ? <YourPlace s={s} phase={phase} /> : null}

      {s.status === Status.Live && s.me.net > 0n && (
        <CancelBox s={s} text={cancelText} setText={setCancelText} canSend={canSend}
          onCancel={(amt) => run('Cancel', () => kindlingCall(c(), d!, { kind: 'cancel', amount: amt }), `Returned ${usd(amt, s.decimals)}`)} />
      )}

      <TxStatus s={tx} />
      {readError && live && <div className="nudge warn"><span className="ico" aria-hidden="true">i</span><span>Could not refresh Kindling: {readError}</span></div>}
    </section>
  );
}

function Countdown({ s, phase, now }: { s: KindlingState; phase: Phase; now: bigint }) {
  const [label, target] =
    phase === 'pending' ? ['Opens in', s.start]
    : phase === 'open' ? ['Closes in', s.end]
    : phase === 'settleable' || phase === 'waiting' ? ['Settlement window closes in', s.deadline]
    : ['', 0n];
  const tone = phase === 'open' && s.end - now < 3600n ? ' urgent' : '';
  return (
    <div className={`countdown${tone}`} aria-live="off">
      <span className={`phase-pill ${phase}`}>{PHASE_LABEL[phase]}</span>
      {target > 0n
        ? <><span className="k">{label}</span><span className="t">{clock(target - now)}</span></>
        : <span className="k">{phase === 'settled' ? `BlastPool opened ${new Date(Number(s.closedAt) * 1000).toLocaleString()}` : phase === 'failed' ? 'Every contribution can be refunded, fees included.' : 'Anyone can end the event now: refunds open at once.'}</span>}
    </div>
  );
}

/** The raise against its $100,000 minimum and $5,000,000 maximum. The fill tweens; crossing the minimum lights it. */
function RaiseBar({ s }: { s: KindlingState }) {
  const fill = useRef<HTMLDivElement>(null);
  const { ofMin, ofMax } = progressPpm(s);
  // The bar is the minimum at 2/3 of its width: the part that decides whether the pool opens gets the room.
  const pos = ofMin < 1_000_000n ? (Number(ofMin) / 1e6) * 66.6667 : 66.6667 + (Number(ofMax) / 1e6) * 33.3333;
  const lit = ofMin >= 1_000_000n;
  useLayoutEffect(() => {
    if (!fill.current) return;
    if (reducedMotion()) { fill.current.style.width = `${pos}%`; return; }
    const t = gsap.to(fill.current, { width: `${pos}%`, duration: 0.9, ease: 'power3.out' });
    return () => { t.kill(); };
  }, [pos]);
  const wasLit = useRef(lit);
  useEffect(() => {
    if (lit && !wasLit.current && fill.current && !reducedMotion()) {
      gsap.fromTo(fill.current, { boxShadow: '0 0 0 0 var(--glow)' }, { boxShadow: '0 0 24px 6px var(--glow)', duration: 0.5, yoyo: true, repeat: 1 });
    }
    wasLit.current = lit;
  }, [lit]);
  return (
    <div className="raise" role="img" aria-label={`Raised ${usd(s.accepted, s.decimals, 0)} of the ${usd(s.minRaise, s.decimals, 0)} minimum and the ${usd(s.maxRaise, s.decimals, 0)} maximum`}>
      <div className={`raise-track${lit ? ' lit' : ''}`}>
        <div className="raise-fill" ref={fill} />
        <div className="raise-min" style={{ left: '66.6667%' }} />
      </div>
      <div className="raise-marks" aria-hidden="true">
        <span className="min" style={{ left: '66.6667%' }}>{usd(s.minRaise, s.decimals, 0)} minimum</span>
        <span className="max">{usd(s.maxRaise, s.decimals, 0)} cap</span>
      </div>
      <span className={`raise-status${lit ? ' lit' : ''}`}>
        {lit ? 'The minimum is met: BlastPool opens at settlement.' : `${usd(s.minRaise - s.accepted, s.decimals, 0)} to the minimum. Below it at the deadline, every contribution is refunded, fees included.`}
      </span>
    </div>
  );
}

function ContributeForm({ s, now, text, setText, canSend, onSubmit }: {
  s: KindlingState; now: bigint; text: string; setText: (t: string) => void; canSend: string | null; onSubmit: (gross: bigint) => void;
}) {
  const gross = parseAmount(text, s.decimals);
  const a = admit(s, gross, now);
  const room = headroom(s);
  const unit = 10n ** BigInt(s.decimals);
  const after = useMemo(() => shareOf(s.totalNet + a.net, s.me.net + a.net, s.decimals), [s.totalNet, s.me.net, a.net, s.decimals]);
  const chips: [string, bigint][] = [['$100', 100n * unit], ['$1,000', 1_000n * unit], [`Max ${usd(room, s.decimals, 0)}`, room]];
  const reason = gross === 0n ? 'Enter an amount' : !a.ok ? 'Adjust the amount' : canSend;
  return (
    <div className="form">
      <Field label="Contribute (USDC)" aside={<span className="unit muted">wallet room {usd(room, s.decimals, 0)}</span>}>
        <input className="input big" inputMode="decimal" value={text} onChange={(e) => setText(e.target.value)} aria-label="USDC to contribute" />
      </Field>
      <div className="row">
        {chips.map(([l, v]) => (
          <button key={l} type="button" className="btn" disabled={v === 0n} onClick={() => setText(amount(v, s.decimals, 2).replace(/,/g, ''))}>{l}</button>
        ))}
      </div>
      <CapMeter s={s} adding={a.ok ? gross : 0n} />
      {gross > 0n && !a.ok && (
        <div className="nudge warn" role="status"><span className="ico" aria-hidden="true">i</span><span>{a.reason}</span></div>
      )}
      {gross > 0n && (
        <div className="routes">
          <div className="route">
            <span className="k">The 3% fee</span>
            <span className="route-v muted">{usd(a.fee, s.decimals)}</span>
            <p className="s">Held in its own escrow: the Treasury’s only if the pool opens, refunded if the event fails.</p>
          </div>
          <div className={`route${a.ok ? ' recommended' : ''}`}>
            <span className="k">Into the pool</span>
            <span className="route-v">{usd(a.net, s.decimals)}</span>
            <p className="s">
              At today’s raise, your position would be about {amount(after.staked, 18, 4)} LP staked: {usd(after.quoteSide, s.decimals)} of
              USDC and {amount(after.emberSide, 18, 2)} EMBER (about {usd(after.emberAtOpen, s.decimals)} at the opening price).
            </p>
          </div>
        </div>
      )}
      <p className="s muted">
        An estimate, not a promised exit: the opening price moves with the raise until the close, and anyone can trade the pool after it.
        Contributions stop at the deadline; cancelling returns net principal until settlement.
      </p>
      <div className="row">
        <button type="button" className="btn primary big" disabled={reason !== null} title={reason ?? undefined} onClick={() => onSubmit(gross)}>
          {reason ?? `Contribute ${usd(gross, s.decimals)}`}
        </button>
      </div>
    </div>
  );
}

/** How much of the wallet's $25,000 admission cap is used, and what this contribution would add. */
function CapMeter({ s, adding }: { s: KindlingState; adding: bigint }) {
  const used = s.walletCap === 0n ? 0 : Number((s.me.gross * 10_000n) / s.walletCap) / 100;
  const add = s.walletCap === 0n ? 0 : Number((adding * 10_000n) / s.walletCap) / 100;
  return (
    <div className="cap-meter" aria-label={`Wallet cap: ${usd(s.me.gross, s.decimals, 0)} of ${usd(s.walletCap, s.decimals, 0)} used`}>
      <div className="cap-track"><span className="used" style={{ width: `${used}%` }} /><span className="adding" style={{ left: `${used}%`, width: `${Math.min(add, 100 - used)}%` }} /></div>
      <span className="unit muted">{usd(s.me.gross, s.decimals, 0)} of the {usd(s.walletCap, s.decimals, 0)} wallet cap</span>
    </div>
  );
}

/** After the deadline: the one action that moves the event on is the primary button. */
function NextStep({ s, phase, canSend, onSettle, onFail, onMaterialize, onRefund }: {
  s: KindlingState; phase: Phase; canSend: string | null;
  onSettle: () => void; onFail: () => void; onMaterialize: () => void; onRefund: () => void;
}) {
  const now = nowS();
  if (phase === 'settleable') {
    return (
      <div className="form">
        <ol className="steps">
          <li>Mint the 420,000-EMBER seed.</li>
          <li>Open BlastPool with the seed and {usd(s.totalNet, s.decimals, 0)} of net USDC.</li>
          <li>Keep 90% of the LP for contributors; lock 10% for good.</li>
          <li>Release the fees: {usd(bountyOf(s), s.decimals)} to you, the rest to the Treasury.</li>
        </ol>
        <button type="button" className="btn primary big" disabled={canSend !== null} title={canSend ?? undefined} onClick={onSettle}>
          {canSend ?? `Settle Kindling and earn ${usd(bountyOf(s), s.decimals)}`}
        </button>
      </div>
    );
  }
  if (phase === 'waiting') {
    return (
      <div className="nudge warn"><span className="ico" aria-hidden="true">i</span>
        <span>Settlement waits, and is never forced: {VENUE_REASON[s.venue] ?? 'the venue could not be read.'} If it is not ready within 72 hours of the deadline, the event fails and every contribution is refunded.</span>
      </div>
    );
  }
  if (phase === 'short' || phase === 'expired' || (phase !== 'settled' && phase !== 'failed' && canFail(s, now))) {
    return (
      <div className="form">
        <p className="s">{phase === 'short' ? 'The raise is below the $100,000 minimum, so the pool will not open.' : 'Nobody settled within 72 hours of the deadline.'} Anyone may end the event; then every wallet can take back its remaining principal and every fee it paid.</p>
        <button type="button" className="btn primary big" disabled={canSend !== null} title={canSend ?? undefined} onClick={onFail}>
          {canSend ?? 'End the event: refunds open'}
        </button>
      </div>
    );
  }
  if (phase === 'settled') {
    return s.entitlement > 0n ? (
      <div className="form">
        <p className="s">Your share of the contributors’ 90% is {amount(s.entitlement, 18, 4)} LP. Claiming opens it as your own position in Forge pool 0, at the pool’s 1% deposit fee, and its Heat starts then.</p>
        <button type="button" className="btn primary big" disabled={canSend !== null} title={canSend ?? undefined} onClick={onMaterialize}>
          {canSend ?? `Claim your position (${amount(s.entitlement, 18, 4)} LP)`}
        </button>
      </div>
    ) : (
      <p className="s">{s.me.done ? 'Your position is open in Forge pool 0: see Positions.' : 'This wallet has no position from Kindling.'}</p>
    );
  }
  return s.refundable > 0n ? (
    <div className="form">
      <p className="s">The event failed. Your refund is your remaining principal plus every fee you paid, cancelled contributions’ fees included.</p>
      <button type="button" className="btn primary big" disabled={canSend !== null} title={canSend ?? undefined} onClick={onRefund}>
        {canSend ?? `Refund ${usd(s.refundable, s.decimals)}`}
      </button>
    </div>
  ) : (
    <p className="s">{s.me.done ? 'Your refund is paid.' : 'This wallet has nothing to refund.'}</p>
  );
}

function YourPlace({ s, phase }: { s: KindlingState; phase: Phase }) {
  const share = shareOf(s.totalNet, s.me.net, s.decimals);
  return (
    <div className="position">
      <div className="row between"><strong>Your contribution</strong><span className="unit muted">{PHASE_LABEL[phase]}</span></div>
      <div className="figures">
        <div className="figure"><span className="k">Accepted</span><span className="v">{usd(s.me.gross, s.decimals)}</span></div>
        <div className="figure"><span className="k">Net in escrow</span><span className="v">{usd(s.me.net, s.decimals)}</span></div>
        <div className="figure"><span className="k">Fees paid</span><span className="v">{usd(s.me.fee, s.decimals)}</span><span className="s">refunded if it fails</span></div>
        {phase !== 'settled' && phase !== 'failed' && s.me.net > 0n && (
          <div className="figure"><span className="k">Position at today’s raise</span><span className="v">{amount(share.staked, 18, 4)} LP</span><span className="s">≈ {usd(share.quoteSide + share.emberAtOpen, s.decimals)} at the opening price</span></div>
        )}
      </div>
    </div>
  );
}

/** Cancelling is allowed until settlement, so it is offered, behind a disclosure and a press-and-hold. */
function CancelBox({ s, text, setText, canSend, onCancel }: {
  s: KindlingState; text: string; setText: (t: string) => void; canSend: string | null; onCancel: (amount: bigint) => void;
}) {
  const typed = parseAmount(text, s.decimals);
  const amt = text.trim() === '' ? s.me.net : typed;
  const p = cancelPreview(s, amt);
  return (
    <details className="cancel">
      <summary>Need your USDC back before the close?</summary>
      <div className="form">
        <Field label="Net principal to take back" aside={<span className="unit muted">up to {usd(s.me.net, s.decimals)}</span>}>
          <input className="input" inputMode="decimal" placeholder={amount(s.me.net, s.decimals, 2)} value={text} onChange={(e) => setText(e.target.value)} aria-label="USDC to take back" />
        </Field>
        <div className="nudge warn"><span className="ico" aria-hidden="true">i</span>
          <span>Cancelling returns {usd(p.back, s.decimals)} now. The {usd(p.feeKept, s.decimals)} you paid in fees stays in escrow: it comes back only if the event fails, and goes to the Treasury if the pool opens. The rest of your contribution, if any, stays in.</span>
        </div>
        {canSend !== null ? <p className="s muted">{canSend}</p>
          : p.ok ? <HoldButton label={`Hold to cancel ${usd(p.back, s.decimals)}`} onConfirm={() => onCancel(p.back)}>Hold to cancel {usd(p.back, s.decimals)}</HoldButton>
          : <p className="s bad-text">Enter an amount up to your net principal.</p>}
      </div>
    </details>
  );
}
