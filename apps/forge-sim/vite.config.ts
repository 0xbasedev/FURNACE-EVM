import { defineConfig } from 'vitest/config';
import react from '@vitejs/plugin-react';
import { fileURLToPath } from 'node:url';

const repo = fileURLToPath(new URL('../..', import.meta.url));

// The simulator runs the repo's exact reference models (scripts/*-model.ts) and the
// canonical package unchanged. canonical/crypto.ts imports a vendored CommonJS
// js-sha3, so that file is included in the CommonJS transform.
export default defineConfig({
  base: './',
  plugins: [react()],
  resolve: {
    alias: {
      '@model': `${repo}scripts`,
      '@canonical': `${repo}canonical`,
    },
  },
  server: { fs: { allow: [repo] } },
  optimizeDeps: { include: [] },
  build: {
    target: 'es2022',
    commonjsOptions: { include: [/canonical[\\/]vendor/, /node_modules/], transformMixedEsModules: true },
  },
  worker: { format: 'es' },
  test: { environment: 'node', include: ['test/**/*.test.ts'] },
});
