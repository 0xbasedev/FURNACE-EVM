import type { FurnaceConfig } from './furnace.config.js';
export type CheckStage = 'economics' | 'deployment';
export interface Diagnostic {
    code: string;
    path: string;
    message: string;
}
/**
 * Template/economics checks allow explicitly unfinished operational identities.
 * Deployment checks do not. Neither stage is an onchain verification or audit.
 */
export declare function validateResolvedConfig(c: FurnaceConfig, stage: CheckStage): Diagnostic[];
