import {
  createPublicClient, createWalletClient, custom, http, decodeEventLog, encodeFunctionData,
  type Address, type Hash, type PublicClient, type WalletClient, type TransactionReceipt,
} from 'viem';
import { LITEFORGE, CHAIN_ID_HEX, ADD_CHAIN_PARAMS } from './chain';
import { FLOW, PAIR, LENS, POOL, TOKEN } from './abi';
import type { Deployment } from './deployment';

/** The injected wallet (EIP-1193). */
export interface Eip1193 {
  request(args: { method: string; params?: unknown[] }): Promise<unknown>;
  on?(event: string, handler: (...args: unknown[]) => void): void;
  removeListener?(event: string, handler: (...args: unknown[]) => void): void;
}

export interface Clients { read: PublicClient; write: WalletClient; account: Address }

export async function connect(p: Eip1193): Promise<Address> {
  const accounts = (await p.request({ method: 'eth_requestAccounts' })) as Address[];
  if (!accounts?.length) throw new Error('The wallet returned no account.');
  return accounts[0];
}

export async function chainIdOf(p: Eip1193): Promise<number> {
  return Number(await p.request({ method: 'eth_chainId' }));
}

/** Switch the wallet to LiteForge, adding the network first if the wallet does not know it. */
export async function ensureLiteForge(p: Eip1193): Promise<void> {
  if ((await chainIdOf(p)) === LITEFORGE.id) return;
  try {
    await p.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: CHAIN_ID_HEX }] });
  } catch (e) {
    if ((e as { code?: number }).code !== 4902) throw e;
    await p.request({ method: 'wallet_addEthereumChain', params: [ADD_CHAIN_PARAMS] });
  }
}

/** Reads go to the wallet's provider when there is one, else straight to the public RPC. */
export function clients(p: Eip1193 | null, account: Address): Clients {
  const transport = p ? custom(p) : http(LITEFORGE.rpcUrls.default.http[0]);
  return {
    read: createPublicClient({ chain: LITEFORGE, transport }) as PublicClient,
    write: createWalletClient({ chain: LITEFORGE, transport: p ? custom(p) : transport, account }),
    account,
  };
}

// ── reads ─────────────────────────────────────────────────────────────────

export async function pairState(read: PublicClient, pair: Address, quoteDecimals: number) {
  const [reserves, supply] = await Promise.all([
    read.readContract({ address: pair, abi: PAIR, functionName: 'getReserves' }) as Promise<readonly [bigint, bigint, number]>,
    read.readContract({ address: pair, abi: PAIR, functionName: 'totalSupply' }) as Promise<bigint>,
  ]);
  return { rE: reserves[0], rQ: reserves[1], supply, quoteDecimals };
}

export const rebateShareOf = (read: PublicClient, d: Deployment, who: Address) =>
  read.readContract({ address: d.flow, abi: FLOW, functionName: 'rebateShareOf', args: [who] }) as Promise<bigint>;

export const balanceOf = (read: PublicClient, token: Address, who: Address) =>
  read.readContract({ address: token, abi: TOKEN, functionName: 'balanceOf', args: [who] }) as Promise<bigint>;

/** The caller's positions in a pool, from the pool's `Opened(id, owner)` logs. */
export async function positionsOf(read: PublicClient, pool: Address, owner: Address): Promise<bigint[]> {
  const logs = await read.getContractEvents({ address: pool, abi: POOL, eventName: 'Opened', args: { owner }, fromBlock: 0n });
  return logs.map((l) => (l as unknown as { args: { id: bigint } }).args.id);
}

export async function custodyOf(read: PublicClient, d: Deployment, pool: Address, id: bigint): Promise<bigint> {
  return read.readContract({ address: d.lens, abi: LENS, functionName: 'custodyOf', args: [pool, id] }) as Promise<bigint>;
}

// ── writes ────────────────────────────────────────────────────────────────

export interface Sent { hashes: Hash[]; receipt: TransactionReceipt }

async function send(c: Clients, to: Address, data: `0x${string}`): Promise<{ hash: Hash; receipt: TransactionReceipt }> {
  const hash = await c.write.sendTransaction({ account: c.account, chain: LITEFORGE, to, data });
  const receipt = await c.read.waitForTransactionReceipt({ hash });
  if (receipt.status !== 'success') throw new Error(`Transaction ${hash} reverted.`);
  return { hash, receipt };
}

/** Approve `spender` for `amount` of `token` if the allowance is short. Returns the approval hash. */
/** Approves exactly what the call spends, never an unlimited allowance: Flow pulls it all, leaving none behind. */
async function ensureAllowance(c: Clients, token: Address, spender: Address, amount: bigint): Promise<Hash | null> {
  const allowance = (await c.read.readContract({ address: token, abi: TOKEN, functionName: 'allowance', args: [c.account, spender] })) as bigint;
  if (allowance >= amount) return null;
  const data = encodeFunctionData({ abi: TOKEN, functionName: 'approve', args: [spender, amount] });
  return (await send(c, token, data)).hash;
}

export const deadlineIn = (seconds: number, now = Date.now()) => BigInt(Math.floor(now / 1000) + seconds);

export const calls = {
  swap: (pair: number, buy: boolean, amountIn: bigint, minOut: bigint, to: Address, deadline: bigint) =>
    encodeFunctionData({ abi: FLOW, functionName: 'swap', args: [BigInt(pair), buy, amountIn, minOut, to, deadline] }),
  zapIn: (pair: number, fromQuote: boolean, amountIn: bigint, minLiquidity: bigint, deadline: bigint) =>
    encodeFunctionData({ abi: FLOW, functionName: 'zapIn', args: [BigInt(pair), fromQuote, amountIn, minLiquidity, deadline] }),
  zapAndStake: (pair: number, fromQuote: boolean, amountIn: bigint, minLiquidity: bigint, position: bigint, deadline: bigint) =>
    encodeFunctionData({ abi: FLOW, functionName: 'zapAndStake', args: [BigInt(pair), fromQuote, amountIn, minLiquidity, position, deadline] }),
  zapOut: (pair: number, liquidity: bigint, toQuote: boolean, minOut: bigint, deadline: bigint) =>
    encodeFunctionData({ abi: FLOW, functionName: 'zapOut', args: [BigInt(pair), liquidity, toQuote, minOut, deadline] }),
  mint: (to: Address, amount: bigint) => encodeFunctionData({ abi: TOKEN, functionName: 'mint', args: [to, amount] }),
};

const tokenIn = (d: Deployment, pair: number, quoteSide: boolean) => (quoteSide ? d.pairs[pair].quote : d.ember);

export async function swap(c: Clients, d: Deployment, o: { pair: number; buy: boolean; amountIn: bigint; minOut: bigint; deadline: bigint }): Promise<Sent> {
  const hashes: Hash[] = [];
  const approval = await ensureAllowance(c, tokenIn(d, o.pair, o.buy), d.flow, o.amountIn);
  if (approval) hashes.push(approval);
  const { hash, receipt } = await send(c, d.flow, calls.swap(o.pair, o.buy, o.amountIn, o.minOut, c.account, o.deadline));
  return { hashes: [...hashes, hash], receipt };
}

/** Zap and stake fee-free; returns the position id and LP from Flow's `Zapped` event. */
export async function zapAndStake(
  c: Clients, d: Deployment,
  o: { pair: number; fromQuote: boolean; amountIn: bigint; minLiquidity: bigint; position: bigint; deadline: bigint },
): Promise<Sent & { position: bigint; liquidity: bigint }> {
  const hashes: Hash[] = [];
  const approval = await ensureAllowance(c, tokenIn(d, o.pair, o.fromQuote), d.flow, o.amountIn);
  if (approval) hashes.push(approval);
  const data = calls.zapAndStake(o.pair, o.fromQuote, o.amountIn, o.minLiquidity, o.position, o.deadline);
  const { hash, receipt } = await send(c, d.flow, data);
  for (const log of receipt.logs) {
    if (log.address.toLowerCase() !== d.flow.toLowerCase()) continue;
    try {
      const ev = decodeEventLog({ abi: FLOW, data: log.data, topics: log.topics });
      if (ev.eventName === 'Zapped') {
        const a = ev.args as unknown as { liquidity: bigint; position: bigint };
        return { hashes: [...hashes, hash], receipt, position: a.position, liquidity: a.liquidity };
      }
    } catch { /* another event */ }
  }
  throw new Error('The zap succeeded but emitted no Zapped event.');
}

export async function zapOut(c: Clients, d: Deployment, o: { pair: number; liquidity: bigint; toQuote: boolean; minOut: bigint; deadline: bigint }): Promise<Sent> {
  const hashes: Hash[] = [];
  const approval = await ensureAllowance(c, d.pairs[o.pair].address, d.flow, o.liquidity);
  if (approval) hashes.push(approval);
  const { hash, receipt } = await send(c, d.flow, calls.zapOut(o.pair, o.liquidity, o.toQuote, o.minOut, o.deadline));
  return { hashes: [...hashes, hash], receipt };
}

/** The faucet: TestnetToken.mint, which anyone may call up to its cap. */
export async function mint(c: Clients, token: Address, amount: bigint): Promise<Sent> {
  const { hash, receipt } = await send(c, token, calls.mint(c.account, amount));
  return { hashes: [hash], receipt };
}
