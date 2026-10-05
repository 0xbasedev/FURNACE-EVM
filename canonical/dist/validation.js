import { IDENTITY_RULES } from './identity-rules.js';
import { isEvmAddress, isNonzeroEvm, isChecksummed, isSolanaAddress, predictCreate3 } from './crypto.js';
const ZERO = /^0x0{40}$/i;
const PLACEHOLDER = /^0x([01])\1{39}$/i;
const HASH = /^0x[0-9a-f]{64}$/i;
const object = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
/**
 * Template/economics checks allow explicitly unfinished operational identities.
 * Deployment checks do not. Neither stage is an onchain verification or audit.
 */
export function validateResolvedConfig(c, stage) {
    const out = [];
    const issue = (code, path, message) => out.push({ code, path, message });
    if (!['economics', 'deployment'].includes(stage))
        throw new Error('Unknown validation stage');
    if (!object(c))
        return [{ code: 'SCHEMA', path: '$', message: 'Expected a configuration object' }];
    const required = ['token', 'shareToken', 'forge', 'emissions', 'fees', 'cooldowns', 'ignition', 'kindling', 'security', 'treasury', 'deployment', 'execution', 'assets'];
    for (const key of required)
        if (!object(c[key]))
            issue('SCHEMA', key, 'Required object is missing');
    if (!Array.isArray(c.chains))
        issue('SCHEMA', 'chains', 'Required chain list is missing');
    if (out.length)
        return out;
    function scan(v, path) {
        if (typeof v === 'number' && (!Number.isFinite(v) || v < 0))
            issue('NUMBER_DOMAIN', path, 'Expected a finite nonnegative number');
        if (Array.isArray(v))
            v.forEach((a, i) => scan(a, `${path}[${i}]`));
        else if (object(v))
            Object.entries(v).forEach(([k, a]) => scan(a, path ? `${path}.${k}` : k));
    }
    scan(c, '');
    function compare(actual, expected, path) {
        if (Array.isArray(expected)) {
            if (!Array.isArray(actual) || actual.length !== expected.length) {
                issue('IDENTITY', path, 'Array length or shape differs from canonical economics');
                return;
            }
            expected.forEach((v, i) => compare(actual[i], v, `${path}[${i}]`));
            return;
        }
        if (object(expected)) {
            if (!object(actual)) {
                issue('IDENTITY', path, 'Required economic section is missing');
                return;
            }
            for (const [k, v] of Object.entries(expected))
                compare(actual[k], v, path ? `${path}.${k}` : k);
            return;
        }
        if (actual !== expected)
            issue('IDENTITY', path, `Required value: ${JSON.stringify(expected)}`);
    }
    compare(c, IDENTITY_RULES, '');
    // A malformed object cannot become a clean build by crashing optional checks.
    try {
        const allocationLeaves = [];
        function allocations(v, path) {
            if (object(v))
                Object.entries(v).forEach(([k, a]) => allocations(a, path + '.' + k));
            else if (typeof v === 'string' && /^\d+$/.test(v))
                allocationLeaves.push(BigInt(v));
            else
                issue('ALLOCATION_AMOUNT', path, 'ASH allocation leaves must be integer human-unit strings');
        }
        allocations(c.shareToken.allocations, 'shareToken.allocations');
        if (allocationLeaves.reduce((a, b) => a + b, 0n) !== 70000n)
            issue('ASH_CONSERVATION', 'shareToken.allocations', 'Every allocation leaf together must equal 70000 ASH');
        const chains = c.chains;
        if (new Set(chains.map(ch => ch.key)).size !== chains.length)
            issue('CHAIN_DUPLICATE', 'chains', 'Duplicate chain key');
        const active = chains.filter(ch => ch.enabled);
        if (active.length !== 1 || active[0]?.key !== 'ethereum' || active[0]?.role !== 'home')
            issue('LAUNCH_PROFILE', 'chains', 'Initial activation is Ethereum only, home role');
        if (active.reduce((n, ch) => n + ch.fixedEmissionSharePct, 0) !== 100 || chains.some(ch => !ch.enabled && ch.fixedEmissionSharePct !== 0))
            issue('CHAIN_BUDGET', 'chains', 'All active budget belongs to active chains; disabled chains receive zero');
        if (c.emissions.controllerChain !== c.token.oft.homeChain || c.token.oft.homeChain !== 'ethereum')
            issue('CONTROLLER', 'emissions.controllerChain', 'Controller and token home must be Ethereum');
        if (c.fissures.enabled)
            issue('SATELLITE_ACTIVATION', 'fissures.enabled', 'Satellite launch requires a separately reviewed release');
        if (c.security.pausable.withdrawalsNever !== true || c.security.upgradeable.core !== false)
            issue('CUSTODY_AUTHORITY', 'security', 'Core is immutable; principal exits cannot be administratively paused');
        const operators = (vm, value, path, required, checksumRequired = true) => {
            if (value === null || value === undefined || value === '') {
                if (required)
                    issue('IDENTITY_UNSET', path, 'Operational identity has not been supplied');
                return;
            }
            if (vm === 'evm') {
                if (!isNonzeroEvm(value))
                    issue('EVM_ADDRESS', path, 'Expected a nonzero 20-byte address');
                else if (checksumRequired && !isChecksummed(value))
                    issue('EVM_CHECKSUM', path, 'Expected EIP-55 checksum encoding');
            }
            else if (vm === 'svm') {
                if (!isSolanaAddress(value))
                    issue('SVM_ADDRESS', path, 'Expected base58 encoding of 32 bytes');
                else if (value === '1'.repeat(32) && required)
                    issue('IDENTITY_PLACEHOLDER', path, 'System-program address is not an operator identity');
            }
            else
                issue('CHAIN_VM', path, 'Unknown VM');
        };
        for (const ch of chains) {
            if (!['evm', 'svm'].includes(ch.vm)) {
                issue('CHAIN_VM', 'chains.' + ch.key, 'Unsupported VM');
                continue;
            }
            const required = stage === 'deployment' && ch.enabled;
            // Existing values are still checked even when their chain is disabled.
            operators(ch.vm, c.security.guardian[ch.key], 'security.guardian.' + ch.key, required);
            operators(ch.vm, c.treasury.addresses[ch.key], 'treasury.addresses.' + ch.key, required);
            if (ch.enabled) {
                operators(ch.vm, ch.externalDex.router, `chains.${ch.key}.externalDex.router`, true);
                operators(ch.vm, ch.lz.endpoint, `chains.${ch.key}.lz.endpoint`, true);
                for (const a of [ch.quoteAsset, ...ch.listedTokens]) {
                    operators(ch.vm, a.address, `chains.${ch.key}.assets.${a.symbol}`, true, false);
                    if (!Number.isInteger(a.decimals) || a.decimals < 0 || a.decimals > 18)
                        issue('DECIMALS', `chains.${ch.key}.assets.${a.symbol}.decimals`, 'Expected integer decimals 0..18');
                }
                if (c.execution.activation.bridgeEnabled) {
                    const ds = ch.lz.dvns;
                    if (new Set(ds.map(x => ch.vm === 'evm' ? x.toLowerCase() : x)).size !== ds.length || ds.length < Math.max(2, ch.lz.requiredDvnCount))
                        issue('DVNS', `chains.${ch.key}.lz.dvns`, 'At least two unique required DVNs, matching the active pathway');
                    ds.forEach((d, i) => operators(ch.vm, d, `chains.${ch.key}.lz.dvns[${i}]`, true));
                }
            }
        }
        const dep = c.deployment.evm;
        operators('evm', dep.factory, 'deployment.evm.factory', true);
        if (!isEvmAddress(dep.deployer))
            issue('DEPLOYER_FORMAT', 'deployment.evm.deployer', 'Expected 20-byte deployer identity');
        else if (stage === 'deployment' && PLACEHOLDER.test(dep.deployer))
            issue('DEPLOYER_PLACEHOLDER', 'deployment.evm.deployer', 'Set the actual deployer; fixture salts prove no key control');
        const addresses = new Set(), salts = new Set();
        const expectedContracts = ['EmberToken', 'AshToken', 'FeeRouter', 'Forge', 'Ignition', 'Kindling', 'Hearth', 'Relics', 'Deeds', 'Mantle', 'BlastPool', 'SmelterPool', 'Flow', 'GenesisFeeEscrow', 'TreasuryVesting', 'Timelock'];
        for (const name of expectedContracts)
            if (!(name in dep.contracts))
                issue('CONTRACT_MISSING', 'deployment.evm.contracts.' + name, 'Required module absent');
        for (const [name, entry] of Object.entries(dep.contracts)) {
            const path = 'deployment.evm.contracts.' + name;
            if (!/^[0-9a-f]{1,40}$/i.test(entry.prefix))
                issue('PREFIX', path + '.prefix', 'Prefix must be 1..40 hexadecimal digits');
            if (entry.salt == null && entry.address == null) {
                if (stage === 'deployment')
                    issue('UNMINED', path, 'Salt and address are unmined');
                continue;
            }
            if (!entry.salt || !entry.address) {
                issue('REGISTRY_PAIR', path, 'Salt and address must be supplied together');
                continue;
            }
            if (!HASH.test(entry.salt) || !isNonzeroEvm(entry.address)) {
                issue('REGISTRY_FORMAT', path, 'Expected bytes32 salt and nonzero 20-byte address');
                continue;
            }
            if (salts.has(entry.salt.toLowerCase()) || addresses.has(entry.address.toLowerCase()))
                issue('REGISTRY_DUPLICATE', path, 'Duplicate salt or address');
            salts.add(entry.salt.toLowerCase());
            addresses.add(entry.address.toLowerCase());
            if (!entry.address.slice(2).toLowerCase().startsWith(entry.prefix.toLowerCase()))
                issue('PREFIX_MISMATCH', path + '.address', 'Address does not match prefix');
            try {
                if (predictCreate3(dep.factory, dep.deployer, entry.salt).toLowerCase() !== entry.address.toLowerCase())
                    issue('ADDRESS_DERIVATION', path + '.address', 'Address differs from guarded CREATE3 prediction');
            }
            catch {
                issue('SALT_GUARD', path + '.salt', 'Salt is not valid for factory/deployer/sender-guard mode');
            }
        }
        if (dep.initializeInDeployTx !== true || dep.saltGuard !== 'msgSender')
            issue('INITIALIZATION', 'deployment.evm', 'Sender-guarded atomic initialization required');
        for (const [phase, module] of [['ignition', 'Ignition'], ['kindling', 'Kindling']])
            if (c[phase].address !== dep.contracts[module]?.address)
                issue('REGISTRY_REFERENCE', phase + '.address', 'Must resolve from canonical registry');
        // Missing collateral identity is an explicit deployment blocker, never a fake LP.
        const ethAssets = c.assets.ethereum ?? {};
        for (const pool of [...c.forge.pools, ...c.ignition.pools]) {
            const binding = ethAssets[pool.stakeToken], path = 'assets.ethereum.' + pool.stakeToken;
            if (!binding) {
                issue('ASSET_BINDING', path, 'Missing receipt-asset identity');
                continue;
            }
            if (binding.kind === 'protocol') {
                if (!(binding.contract in dep.contracts))
                    issue('ASSET_BINDING', path, 'Unknown protocol contract');
            }
            else if (binding.kind === 'external')
                operators('evm', binding.address, path + '.address', stage === 'deployment', false);
            else
                issue('ASSET_KIND', path, 'Unknown binding kind');
        }
        const extBindings = Object.entries(ethAssets).filter(([, a]) => a.kind === 'external' && a.address);
        const seen = new Map();
        for (const [symbol, b] of extBindings)
            if (b.kind === 'external' && b.address) {
                const key = b.address.toLowerCase();
                if (seen.has(key))
                    issue('DUPLICATE_RECEIPT', 'assets.ethereum.' + symbol, 'Different pool symbols resolve to the same external asset');
                seen.set(key, symbol);
            }
        if (stage === 'deployment') {
            const safe = dep.treasurySafe;
            operators('evm', safe.factory, 'deployment.evm.treasurySafe.factory', true);
            operators('evm', safe.singleton, 'deployment.evm.treasurySafe.singleton', true);
            if (safe.saltNonce === null || !/^(0x[0-9a-f]{1,64}|\d+)$/i.test(safe.saltNonce) || BigInt(safe.saltNonce) >= 2n ** 256n)
                issue('SAFE_NONCE', 'deployment.evm.treasurySafe.saltNonce', 'Set a valid uint256 nonce');
            for (const key of ['initializerHash', 'initCodeHash'])
                if (!safe[key] || !HASH.test(safe[key]))
                    issue('SAFE_CREATION_INPUT', 'deployment.evm.treasurySafe.' + key, 'Pin the complete Safe creation inputs');
            const ctrl = c.treasury.controller;
            if (ctrl.threshold !== 3 || ctrl.signers.length !== 5 || new Set(ctrl.signers.map(s => s.toLowerCase())).size !== 5)
                issue('SAFE_3_OF_5', 'treasury.controller', 'Requires three approvals from five distinct real owners');
            ctrl.signers.forEach((s, i) => operators('evm', s, `treasury.controller.signers[${i}]`, true));
            if (c.ignition.startTimestamp === null || !Number.isSafeInteger(c.ignition.startTimestamp) || c.ignition.startTimestamp <= 0)
                issue('START_TIME', 'ignition.startTimestamp', 'Set the actual launch start timestamp');
        }
    }
    catch (e) {
        issue('SCHEMA', '$', `Malformed nested configuration: ${e instanceof Error ? e.message : 'unknown error'}`);
    }
    return out.sort((a, b) => a.path.localeCompare(b.path) || a.code.localeCompare(b.code));
}
