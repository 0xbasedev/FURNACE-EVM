import type { Abi } from 'viem';
import FlowAbi from '@repo/abi/Flow.json';
import EmberPairAbi from '@repo/abi/EmberPair.json';
import ForgeLensAbi from '@repo/abi/ForgeLens.json';
import ForgePoolAbi from '@repo/abi/ForgePool.json';
import TestnetTokenAbi from '@repo/abi/TestnetToken.json';

// Exported from the build by `pnpm abi` (and checked fresh by `pnpm abi:check`).
export const FLOW = FlowAbi as Abi;
export const PAIR = EmberPairAbi as Abi;
export const LENS = ForgeLensAbi as Abi;
export const POOL = ForgePoolAbi as Abi;
export const TOKEN = TestnetTokenAbi as Abi;
