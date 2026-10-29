// CI gate self-test: a deliberately failing forge test must make `tools/forge.mjs`
// exit non-zero, and the same test must pass when not asked to fail.
import { spawnSync } from 'node:child_process';

const run = (env) => spawnSync('node', ['tools/forge.mjs', 'test', '--match-path', 'contracts/test/meta/ExitCode.t.sol'], {
  env: { ...process.env, ...env }, encoding: 'utf8',
}).status;

const red = run({ FURNACE_EXPECT_FAIL: '1' });
const green = run({ FURNACE_EXPECT_FAIL: '0' });
if (red === 0 || green !== 0) {
  console.error(`✗ forge exit status not propagated (failing test → ${red}, passing test → ${green})`);
  process.exit(1);
}
console.log(`✓ forge gate: failing test exits ${red}, passing test exits 0`);
