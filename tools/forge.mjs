#!/usr/bin/env node
// Runs the pinned forge binary and PROPAGATES ITS EXIT STATUS.
// @foundry-rs/forge 1.7.1's bin.mjs spawns forge but never forwards the child's exit
// code, so failing tests exit 0 and CI would pass red suites. This wrapper resolves
// the same platform package and exits with forge's status (or 1 on a signal).
import { spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';

const arch = { x64: 'amd64', arm64: 'arm64' }[process.arch];
const os = { linux: 'linux', darwin: 'darwin', win32: 'win32' }[process.platform];
if (!arch || !os) {
  console.error(`forge: unsupported platform ${process.platform}/${process.arch}`);
  process.exit(1);
}
const fromForge = createRequire(createRequire(import.meta.url).resolve('@foundry-rs/forge/package.json'));
const binary = fromForge.resolve(`@foundry-rs/forge-${os}-${arch}/bin/forge${os === 'win32' ? '.exe' : ''}`);

const r = spawnSync(binary, process.argv.slice(2), { stdio: 'inherit' });
if (r.error) {
  console.error(`forge: ${r.error.message}`);
  process.exit(1);
}
process.exit(r.status ?? 1);
