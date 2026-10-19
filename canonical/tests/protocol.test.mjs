import test from 'node:test';
import assert from 'node:assert/strict';
import * as cfg from '../dist/furnace.config.js';
import * as a from '../dist/accounting.js';
import * as crypto from '../dist/crypto.js';
const c=cfg.furnaceConfig;
const clone=()=>structuredClone(c);
const diagnostics=(x,stage='economics')=>cfg.validateConfigDetailed(x,stage);
const near=(x,y,tolerance=1e-10)=>assert.ok(Math.abs(x-y)<tolerance,`${x} != ${y}`);

test('canonical economic template passes; deployment remains blocked',()=>{
 assert.deepEqual(diagnostics(c),[]);
 const d=diagnostics(c,'deployment');assert.ok(d.some(x=>x.code==='DEPLOYER_PLACEHOLDER'));assert.ok(d.some(x=>x.code==='UNMINED'));assert.ok(d.some(x=>x.code==='SAFE_3_OF_5'));
});
test('baseline emission and supply profile retained',()=>{
 assert.equal(c.token.maxSupply,'21000000');assert.equal(c.token.allocations.kindlingPool,'420000');assert.equal(c.emissions.base.startPerDay,'21600');assert.equal(c.emissions.base.halfLifeDays,365);
 assert.equal(c.shareToken.allocations.launch.ignition,'41000');assert.equal(c.shareToken.allocations.launch.kindling,'1000');assert.equal(c.shareToken.allocations.forge,'28000');
});
test('Ethereum is the only initial chain and receives full local budget',()=>{
 assert.deepEqual(c.chains.filter(x=>x.enabled).map(x=>[x.key,x.fixedEmissionSharePct]),[['ethereum',100]]);assert.equal(c.execution.activation.bridgeEnabled,false);
});
const eth=x=>x.chains.find(ch=>ch.key==='ethereum');
const mutations=[
 ['claim fee',x=>x.forge.fees.claimPct=1,'IDENTITY','forge.fees.claimPct'],
 ['emergency fee',x=>x.forge.emergencyExit.feePct=99,'IDENTITY','forge.emergencyExit.feePct'],
 ['deposit fee',x=>x.forge.fees.depositPct=2,'IDENTITY','forge.fees.depositPct'],
 ['withdraw reset',x=>x.forge.heat.withdrawCooling='reset','IDENTITY','forge.heat.withdrawCooling'],
 ['compound loses age',x=>x.forge.heat.compoundInheritsAge=false,'IDENTITY','forge.heat.compoundInheritsAge'],
 ['fresh cancellation',x=>x.forge.cancelReturnsAsFreshLot=true,'IDENTITY','forge.cancelReturnsAsFreshLot'],
 ['contradictory lapse',x=>x.cooldowns.withdraw.onCancelOrLapse='freshLot','IDENTITY','cooldowns.withdraw.onCancelOrLapse'],
 ['altered floor',x=>x.emissions.base.floorPerDay='2000','IDENTITY','emissions.base.floorPerDay'],
 ['altered split',x=>x.emissions.split.flatPct=0,'IDENTITY','emissions.split.flatPct'],
 ['altered bucket',x=>x.emissions.convictionBucketPct=90,'IDENTITY','emissions.convictionBucketPct'],
 ['casting too high',x=>x.forge.casting.lpSharePct=50,'IDENTITY','forge.casting.lpSharePct'],
 ['casting singles',x=>x.forge.casting.incompatibleCollateral='lp','IDENTITY','forge.casting.incompatibleCollateral'],
 ['burn user LP',x=>x.forge.casting.matchedLpOwnership='burned','IDENTITY','forge.casting.matchedLpOwnership'],
 ['all Kindling LP burned',x=>x.kindling.lpSplit={depositorDeedsPct:0,burnPct:100},'IDENTITY','kindling.lpSplit.burnPct'],
 ['non-atomic Kindling',x=>x.kindling.atomicPoolInit=false,'IDENTITY','kindling.atomicPoolInit'],
 ['unescrowed fees',x=>x.kindling.feeEscrowUntilClose=false,'IDENTITY','kindling.feeEscrowUntilClose'],
 ['excessive chunk',x=>x.fees.burnLane.maxChunkPctOfReserve=50,'IDENTITY','fees.burnLane.maxChunkPctOfReserve'],
 ['disabled allowlist',x=>x.fees.burnLane.allowlistedRoutersOnly=false,'IDENTITY','fees.burnLane.allowlistedRoutersOnly'],
 ['unsafe fail open',x=>x.fees.burnLane.deferIfUnsafe=false,'IDENTITY','fees.burnLane.deferIfUnsafe'],
 ['one-second TWAP',x=>x.fees.burnLane.twapSeconds=1,'IDENTITY','fees.burnLane.twapSeconds'],
 ['open keepers',x=>x.forge.autoStoke.defaultOn=true,'IDENTITY','forge.autoStoke.defaultOn'],
 ['automatic selling',x=>x.forge.compound.lpMatch.fallback='zap','IDENTITY','forge.compound.lpMatch.fallback'],
 ['empty router',x=>eth(x).externalDex.router='','IDENTITY_UNSET','chains.ethereum.externalDex.router'],
 ['zero router',x=>eth(x).externalDex.router='0x'+'0'.repeat(40),'EVM_ADDRESS','chains.ethereum.externalDex.router'],
 ['empty endpoint',x=>eth(x).lz.endpoint='','IDENTITY_UNSET','chains.ethereum.lz.endpoint'],
 ['zero endpoint',x=>eth(x).lz.endpoint='0x'+'0'.repeat(40),'EVM_ADDRESS','chains.ethereum.lz.endpoint'],
 ['corrupt router checksum',x=>eth(x).externalDex.router=eth(x).externalDex.router.slice(0,-1)+'d','EVM_CHECKSUM','chains.ethereum.externalDex.router'],
 ['wrong predicted address',x=>{const p=x.deployment.evm.contracts.EmberToken;p.address=p.address.slice(0,-1)+'5';},'ADDRESS_DERIVATION','deployment.evm.contracts.EmberToken.address'],
 ['extra ASH allocation',x=>x.shareToken.allocations.extra='1000','ASH_CONSERVATION','shareToken.allocations'],
 ['NaN casting',x=>x.forge.casting.lpSharePct=NaN,'NUMBER_DOMAIN','forge.casting.lpSharePct'],
 ['infinite reserve chunk',x=>x.fees.burnLane.maxChunkPctOfReserve=Infinity,'NUMBER_DOMAIN','fees.burnLane.maxChunkPctOfReserve'],
 ['missing module',x=>delete x.deployment.evm.contracts.Mantle,'CONTRACT_MISSING','deployment.evm.contracts.Mantle'],
 ['missing collateral binding',x=>delete x.assets.ethereum['EMBER/USDC'],'ASSET_BINDING','assets.ethereum.EMBER/USDC'],
 ['ordinary WETH labelled LP',x=>x.assets.ethereum['WETH/USDC'].address=x.assets.ethereum.WETH.address,'DUPLICATE_RECEIPT','assets.ethereum.WETH/USDC'],
 ['pause exits',x=>x.security.pausable.withdrawalsNever=false,'CUSTODY_AUTHORITY','security'],
 ['activate satellite',x=>x.chains[1].enabled=true,'LAUNCH_PROFILE','chains'],
 ['disable all chains',x=>x.chains.forEach(ch=>ch.enabled=false),'LAUNCH_PROFILE','chains'],
];
for(const [name,mutate,code,path]of mutations)test(`specific rejection: ${name}`,()=>{const x=clone();mutate(x);assert.ok(diagnostics(x).some(d=>d.code===code&&d.path===path),JSON.stringify(diagnostics(x)));});

test('Solana guardians use base58, not an EVM checksum',()=>{
 const x=clone();x.security.guardian.solana='HVQT6MycoarDw9ktbZBv282HH8SttSR4ycvTeSTw9kKe';assert.ok(!diagnostics(x).some(d=>d.path==='security.guardian.solana'));
 x.security.guardian.solana=eth(x).externalDex.router;assert.ok(diagnostics(x).some(d=>d.code==='SVM_ADDRESS'));
});
test('missing active guardian is a deployment blocker with stable path',()=>{const x=clone();delete x.security.guardian.ethereum;assert.ok(diagnostics(x,'deployment').some(d=>d.code==='IDENTITY_UNSET'&&d.path==='security.guardian.ethereum'));});
test('nine preserved fixture CREATE3 addresses independently recompute',()=>{
 for(const e of Object.values(c.deployment.evm.contracts).filter(e=>e.salt)){assert.equal(crypto.predictCreate3(c.deployment.evm.factory,c.deployment.evm.deployer,e.salt),e.address.toLowerCase());}
});
test('guarded salt rejects a different sender',()=>{const e=c.deployment.evm.contracts.EmberToken;assert.throws(()=>crypto.predictCreate3(c.deployment.evm.factory,'0x'+'2'.repeat(40),e.salt));});
test('Keccak matches standard empty and abc vectors',()=>{
 assert.equal(crypto.keccak(''),'0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470');
 assert.equal(crypto.keccak('abc'),'0x4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45');
});
test('canonical data hash is key-order invariant and rejects NaN',()=>{assert.equal(crypto.keccak(crypto.canonical({b:2,a:1})),crypto.keccak(crypto.canonical({a:1,b:2})));assert.throws(()=>crypto.canonical({a:NaN}));});
test('display cooling, Deed carry, Heat and reward outputs retained',()=>{
 assert.equal(cfg.cooledAgeAfterWithdrawal(730,.5),182.5);assert.equal(cfg.heatAgeAfterWithdrawal(730,.5),182.5);assert.equal(cfg.deedHeatAge(730),292);
 near(cfg.heatMultiplier(365),3);near(cfg.maxTotalMultiplier(),4.15);near(cfg.rewardShare(100,1,200,400),.325);near(cfg.rewardShare(100,3,200,400),.675);
});
test('display helper guards reject invalid Conviction and mint domains',()=>{assert.throws(()=>cfg.convictionCap(-1,.5,100,10000));assert.throws(()=>cfg.epochSplit(10000,-1));assert.throws(()=>cfg.epochSplit(10000,1001));assert.throws(()=>cfg.mintForEpoch(-1,0));});
test('pool/category-aware Casting is ordinary-base and LP only',()=>{
 assert.deepEqual(cfg.castForPool('ember-usdc-lp','ordinaryBase',100,100),{uncast:75,cast:25});
 for(const pool of ['ember-single','usdc-single'])assert.deepEqual(cfg.castForPool(pool,'ordinaryBase',100,100),{uncast:100,cast:0});
 for(const type of ['ashfall','conviction','sealedPot','quoteYield','ASH'])assert.deepEqual(cfg.castForPool('ember-usdc-lp',type,100,100),{uncast:100,cast:0});
 assert.throws(()=>cfg.castForPool('unknown','ordinaryBase',100,100));assert.throws(()=>cfg.castForPool('ember-usdc-lp','ordinaryBase',NaN,100));
});
test('dry and partially funded Cast leave uncovered rewards liquid',()=>{
 assert.deepEqual(cfg.castForPool('ember-usdc-lp','ordinaryBase',100,0),{uncast:100,cast:0});assert.deepEqual(cfg.castForPool('ember-usdc-lp','ordinaryBase',100,10),{uncast:90,cast:10});
});
test('integer amount parser never uses floating-point money',()=>{assert.equal(a.parseUnits('1.234567',6),1234567n);for(const x of ['1e3','-1','NaN','1.0000001'])assert.throws(()=>a.parseUnits(x,6));});
test('integer square root is exact at and around large squares',()=>{const x=123456789012345678901234567890n;assert.equal(a.isqrt(x*x),x);assert.equal(a.isqrt(x*x-1n),x-1n);assert.equal(a.isqrt(x*x+x),x);assert.throws(()=>a.isqrt(-1n));});
test('capped-age operations have one integer policy',()=>{assert.equal(a.cooledAge(730n*a.DAY,1n,2n),365n*a.DAY/2n);assert.equal(a.deedAge(730n*a.DAY),292n*a.DAY);assert.throws(()=>a.cooledAge(1n,2n,1n));});
test('exact ASH vesting consumes the allocation once across all checkpoints',()=>{
 const total=a.parseUnits('28000',18),duration=730n*a.DAY;let sum=0n;
 for(let d=0n;d<730n;d++)sum+=a.vested(total,(d+1n)*a.DAY,duration)-a.vested(total,d*a.DAY,duration);
 assert.equal(sum,total);assert.equal(a.vested(total,duration+1000n,duration),total);
});
test('Heat integral is constant after cap',()=>{assert.equal(a.integrateHeat(730n*a.DAY,10n*a.DAY),30n*a.DAY*a.RAY);assert.equal(a.integrateHeat(365n*a.DAY,a.DAY,a.ray('0.65')),a.DAY*a.ray('3.65'));});
test('Heat primitive differences telescope at all milestone boundaries',()=>{
 const points=[0n,7n,30n,90n,180n,365n,730n].map(d=>d*a.DAY);let sum=0n;for(let i=0;i+1<points.length;i++)sum+=a.integrateHeat(points[i],points[i+1]-points[i]);assert.equal(sum,a.integrateHeat(0n,730n*a.DAY));
});
test('integral agrees with an independent fine midpoint calculation',()=>{
 const days=35,n=20000,dx=days/n;let sum=0;for(let i=0;i<n;i++)sum+=cfg.heatMultiplier((i+.5)*dx)*dx;
 const exact=Number(a.integrateHeat(0n,BigInt(days)*a.DAY))/Number(a.RAY)/86400;
 near(exact,sum,0.00001);
});
test('integration is explicitly not a terminal snapshot',()=>{
 const first=a.segmentMeasures(1n,0n,a.DAY);assert.ok(first.heatSeconds>a.RAY*a.DAY);assert.ok(first.heatSeconds<BigInt(Math.floor(cfg.heatMultiplier(1)*1e9))*a.RAY/1000000000n*a.DAY);
});
test('empty epoch retains budget, never fabricates a recipient',()=>{const s=a.settleBaseEpoch(10000n,[]);assert.equal(s.residue,10000n);assert.equal(s.escrowPaid,0n);});
test('empty Conviction returns to Heat: 27/73',()=>{
 const p=[{id:'new',stakeSeconds:100n,heatSeconds:100n*a.RAY,sealSeconds:0n,candidateSeconds:0n},{id:'old',stakeSeconds:100n,heatSeconds:300n*a.RAY,sealSeconds:0n,candidateSeconds:0n}];
 const s=a.settleBaseEpoch(10000n,p);assert.equal(s.payouts[0].ordinary,3175n);assert.equal(s.payouts[1].ordinary,6825n);assert.equal(s.flatBudget,2700n);assert.equal(s.heatBudget,7300n);assert.equal(s.residue,0n);
});
test('additive-correct cap on the 10,000-token counterexample',()=>{
 const p=[{id:'sealed',stakeSeconds:10n,heatSeconds:10n*a.ray('3.65'),sealSeconds:10n*a.ray('0.5'),candidateSeconds:10n*a.ray('3.65')/2n},{id:'rest',stakeSeconds:990n,heatSeconds:990n*a.RAY,sealSeconds:0n,candidateSeconds:0n}];
 const unit=1000000n,s=a.settleBaseEpoch(10000n*unit,p);assert.equal(s.payouts[0].escrow,30686799n);assert.ok(s.payouts[0].escrow<31n*unit);assert.equal(s.payouts.reduce((n,p)=>n+p.ordinary+p.escrow,0n)+s.residue,10000n*unit);
});
test('counterfeit measures and duplicate position IDs are rejected',()=>{assert.throws(()=>a.settleBaseEpoch(100n,[{id:'x',stakeSeconds:1n,heatSeconds:0n,sealSeconds:0n,candidateSeconds:0n}]));const p={id:'x',...a.segmentMeasures(1n,0n,a.DAY)};assert.throws(()=>a.settleBaseEpoch(1n,[p,p]));});
test('1,000 seeded allocations conserve base budget and respect caps',()=>{
 let seed=20261004;const rnd=()=>{seed=(Math.imul(seed,1664525)+1013904223)>>>0;return seed;};
 for(let trial=0;trial<1000;trial++){
  const ps=Array.from({length:1+rnd()%20},(_,i)=>({id:String(i),...a.segmentMeasures(BigInt(1+rnd()%10000),BigInt(rnd()%731)*a.DAY,BigInt(1+rnd()%86400),a.ray(['0','0.15','0.5','0.65'][rnd()%4]),a.ray(['0','0.15','0.25','0.5'][rnd()%4]))}));
  const budget=BigInt(rnd())*1000000n,s=a.settleBaseEpoch(budget,ps),W=a.sumMeasures(ps).heatSeconds,bucket=budget/10n,ordinary=budget-bucket,L=ordinary-ordinary*30n/100n;
  assert.equal(s.payouts.reduce((n,p)=>n+p.ordinary+p.escrow,0n)+s.residue,budget);assert.ok(s.escrowPaid<=bucket);
  s.payouts.forEach((p,i)=>assert.ok(p.escrow<=L*ps[i].sealSeconds/W));
 }
});
test('bounded-page measure accumulation matches a full reference total',()=>{
 const ps=Array.from({length:1501},(_,i)=>a.segmentMeasures(BigInt(i+1),BigInt(i%366)*a.DAY,1000n));
 const pages=[];for(let i=0;i<ps.length;i+=32)pages.push(a.sumMeasures(ps.slice(i,i+32)));assert.deepEqual(a.sumMeasures(pages),a.sumMeasures(ps));
});
test('joint mint subtracts already reserved headroom once',()=>{assert.deepEqual(a.allocateMint(1000n,800n,110n,100n,50n),{base:60n,ashfall:30n,unmintedResidue:0n});assert.throws(()=>a.allocateMint(1000n,0n,0n,-1n,0n));});
test('matching is pro-rata, capped by quote actually reserved',()=>{assert.deepEqual(a.allocateMatching(50n,[{id:'a',quoteDemand:25n},{id:'b',quoteDemand:75n}]),{grants:[{id:'a',quote:12n},{id:'b',quote:37n}],unreserved:1n});});
test('matching credits cannot be consumed twice',()=>{const ledger=new a.MatchReservations([{id:'a',quote:25n}]);ledger.consume('a',25n);assert.throws(()=>ledger.consume('a',1n));assert.equal(ledger.release('a'),0n);assert.throws(()=>ledger.consume('a',0n));});
test('escrow failure refunds net plus held fee, not spendable Treasury funds',()=>{
 const e=new a.KindlingEscrow();assert.deepEqual(e.deposit('a',10000n),{net:9700n,fee:300n});assert.equal(e.treasuryReleased,0n);e.settle(false);assert.equal(e.refund('a'),10000n);assert.throws(()=>e.refund('a'));
});
test('cancel then failure returns only outstanding net and fee',()=>{const e=new a.KindlingEscrow();e.deposit('a',10000n);assert.equal(e.cancel('a',4000n),4000n);e.settle(false);assert.equal(e.refund('a'),6000n);});
test('success releases fees only once and leaves principal to LP settlement',()=>{const e=new a.KindlingEscrow();e.deposit('a',10000n);assert.equal(e.settle(true),300n);assert.equal(e.claimNetForLp('a'),9700n);assert.throws(()=>e.settle(true));assert.throws(()=>e.refund('a'));});

test('Heat-squared integral is constant beyond cap and is not squared average',()=>{
 assert.equal(a.integrateSquaredHeat(365n*a.DAY,a.DAY,a.ray('0.65')),a.DAY*a.ray('3.65')**2n);
 const integral=a.integrateHeat(0n,365n*a.DAY),squared=a.integrateSquaredHeat(0n,365n*a.DAY);
 assert.ok(squared>integral*integral/(365n*a.DAY));
});
test('Heat-squared primitive telescopes across milestones',()=>{
 const points=[0n,7n,30n,90n,180n,365n,400n].map(d=>d*a.DAY);let sum=0n;
 for(let i=0;i+1<points.length;i++)sum+=a.integrateSquaredHeat(points[i],points[i+1]-points[i],a.ray('0.15'));
 assert.equal(sum,a.integrateSquaredHeat(0n,400n*a.DAY,a.ray('0.15')));
});
test('Heat-squared integral matches independent numerical quadrature',()=>{
 for(const [start,days,bonus] of [[0,35,0],[80,120,.5],[350,40,.65]]){
  const n=20000,dx=days/n;let sum=0;for(let i=0;i<n;i++)sum+=(cfg.heatMultiplier(start+(i+.5)*dx)+bonus)**2*dx;
  const exact=Number(a.integrateSquaredHeat(BigInt(start)*a.DAY,BigInt(days)*a.DAY,a.ray(String(bonus))))/Number(a.RAY*a.RAY)/86400;
  near(exact,sum,0.0001);
 }
});

test('late entry cannot obtain a previously empty full-day budget',()=>{
 assert.equal(a.accruedPoolBudget(21600000000n,1n,a.DAY),250000n);
 assert.equal(a.accruedPoolBudget(21600000000n,0n,a.DAY),0n);
 assert.equal(a.accruedPoolBudget(21600000000n,a.DAY,a.DAY),21600000000n);
});
test('occupied-time budget rejects negative, zero-duration and excessive intervals',()=>{
 assert.throws(()=>a.accruedPoolBudget(-1n,0n,a.DAY));assert.throws(()=>a.accruedPoolBudget(1n,1n,0n));assert.throws(()=>a.accruedPoolBudget(1n,a.DAY+1n,a.DAY));
});
