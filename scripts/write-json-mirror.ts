// pnpm config:json — regenerates config/furnace.config.canonical.json from furnace.config.ts.
import { writeFileSync } from 'node:fs';
import furnaceConfig from '../furnace.config';
import { CONFIG_PATH, canonicalize } from './canonical';

writeFileSync(CONFIG_PATH, JSON.stringify(JSON.parse(canonicalize(furnaceConfig)), null, 2) + '\n');
console.log(`wrote ${CONFIG_PATH}`);
