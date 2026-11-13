import { useState } from 'react';
import { useEntrance } from '@sim/motion/motion';
import { loadDeployment } from './deployment';
import { LITEFORGE } from './chain';
import { short } from './format';
import { useWallet } from './useWallet';
import { useMarket } from './useMarket';
import { ZapPanel } from './panels/ZapPanel';
import { SwapPanel } from './panels/SwapPanel';
import { PositionsPanel } from './panels/PositionsPanel';
import { FaucetPanel } from './panels/FaucetPanel';

const { deployment, error: manifestError } = loadDeployment();
type Tab = 'zap' | 'swap' | 'positions' | 'faucet';
const TABS: { id: Tab; label: string }[] = [
  { id: 'zap', label: 'Zap & stake' },
  { id: 'swap', label: 'Swap' },
  { id: 'positions', label: 'Positions' },
  { id: 'faucet', label: 'Test tokens' },
];

export function App() {
  const w = useWallet();
  const market = useMarket(deployment, w.provider, w.account, w.onLiteForge);
  const [tab, setTab] = useState<Tab>('zap');
  const [position, setPosition] = useState(0n);
  const [tick, setTick] = useState(0);
  const done = () => { market.refresh(); setTick((t) => t + 1); };
  useEntrance('.panel');

  // Why a transaction cannot be sent right now, or null when it can.
  const canSend = !deployment ? 'Not deployed yet'
    : !deployment.pairsLive ? 'The pairs are not deployed yet'
    : !w.account ? 'Connect a wallet'
    : !w.onLiteForge ? `Switch to ${LITEFORGE.name}`
    : null;

  return (
    <div className="page app">
      <header className="masthead">
        <div className="topbar">
          <div className="brand">
            <h1>Furnace <span>on LiteForge</span></h1>
          </div>
          <div className="wallet">
            {w.account && !w.onLiteForge && <button type="button" className="btn warn" onClick={w.switchChain} disabled={w.busy}>Switch to {LITEFORGE.name}</button>}
            {w.account ? <span className="pill good" title={w.account}>{short(w.account)}</span>
              : <button type="button" className="btn primary" onClick={w.connect} disabled={w.busy}>Connect wallet</button>}
          </div>
        </div>
        <div className="notice" role="note">
          <span aria-hidden="true">⚠</span>
          <span><strong>Testnet only.</strong> LitVM LiteForge (chain {LITEFORGE.id}). The contracts are unaudited, the tokens have no value, and nothing here is an offer or a promise of yield.</span>
        </div>
        {!deployment && (
          <div className="notice demo" role="status">
            <svg className="notice-ico" viewBox="0 0 16 16" width="16" height="16" aria-hidden="true"><circle cx="8" cy="8" r="6.5" fill="none" stroke="currentColor" strokeWidth="1.5" /><path d="M8 1.5a6.5 6.5 0 0 1 0 13z" fill="currentColor" /></svg>
            <span><strong>{manifestError ? 'The deployment manifest is unreadable.' : 'Not deployed yet.'}</strong> {manifestError ?? 'Run pnpm testnet:deploy, then rebuild. Until then every quote below runs on simulated reserves, with the same math the contracts use.'}</span>
          </div>
        )}
        {w.error && <div className="nudge bad" role="alert"><span className="ico" aria-hidden="true">!</span><span>{w.error}</span></div>}
        {market.error && <div className="nudge warn"><span className="ico" aria-hidden="true">i</span><span>Could not read the pools: {market.error}</span></div>}
      </header>

      <nav className="tabs" aria-label="Sections">
        <div className="seg" role="tablist">
          {TABS.map((t) => (
            <button key={t.id} type="button" role="tab" aria-selected={tab === t.id} aria-pressed={tab === t.id} onClick={() => setTab(t.id)}>{t.label}</button>
          ))}
        </div>
        <span className="unit">{market.live ? 'Live reserves' : 'Simulated reserves'}</span>
      </nav>

      <main className="surface single">
        {tab === 'zap' && <ZapPanel d={deployment} market={market} provider={w.provider} account={w.account} canSend={canSend}
          position={position} setPosition={setPosition} onDone={done} />}
        {tab === 'swap' && <SwapPanel d={deployment} market={market} provider={w.provider} account={w.account} canSend={canSend} onDone={done} />}
        {tab === 'positions' && <PositionsPanel d={deployment} provider={w.provider} account={w.account} onLiteForge={w.onLiteForge} tick={tick}
          onAdd={(_pool, id) => { setPosition(id); setTab('zap'); }} />}
        {tab === 'faucet' && <FaucetPanel d={deployment} provider={w.provider} account={w.account} onLiteForge={w.onLiteForge}
          canSend={canSend} onDone={done} tick={tick} />}
      </main>

      <footer className="foot">
        <p>Every quote is computed with the repository's exact BigInt models of the pairs and Flow, which the Solidity contracts match to the wei in differential tests. Slippage defaults and warnings are interface policy; the chain enforces only the minimum each call carries.</p>
      </footer>
    </div>
  );
}
