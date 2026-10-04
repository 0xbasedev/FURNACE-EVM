// pnpm check:config — runs validateConfig() from furnace.config.ts.
// Fails while deploy identities (deployer, Safe, guardians, DVNs, treasuries)
// are unset; that is intended. Use `pnpm check` for the pre-deploy CI gate.
import { validateConfig } from '../furnace.config';

const errors = validateConfig();
errors.forEach((e) => console.log(`✗ ${e}`));
console.log(errors.length ? `\n${errors.length} config error(s)` : '✓ config valid');
process.exit(errors.length ? 1 : 0);
