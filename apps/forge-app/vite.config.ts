import { defineConfig } from 'vitest/config';
import react from '@vitejs/plugin-react';
import { fileURLToPath } from 'node:url';

const repo = fileURLToPath(new URL('../..', import.meta.url));

// The dApp quotes with the repo's exact reference models (scripts/pair-model.ts and
// scripts/flow-model.ts), shares the simulator's motion, tokens and Forge engine, and
// reads the testnet manifest and the exported ABIs at build time. canonical/crypto.ts
// imports a vendored CommonJS js-sha3, so that file is included in the CommonJS transform.
export default defineConfig({
  base: './',
  plugins: [react()],
  resolve: {
    alias: {
      '@model': `${repo}scripts`,
      '@canonical': `${repo}canonical`,
      '@sim': `${repo}apps/forge-sim/src`,
      '@repo': repo.replace(/\/$/, ''),
    },
  },
  server: { fs: { allow: [repo] } },
  build: {
    target: 'es2022',
    commonjsOptions: { include: [/canonical[\\/]vendor/, /node_modules/], transformMixedEsModules: true },
    rollupOptions: { output: { manualChunks: { viem: ['viem'], react: ['react', 'react-dom'], gsap: ['gsap'] } } },
  },
  test: { environment: 'node', include: ['test/**/*.test.ts'] },
});
