import {spawnSync} from 'node:child_process';
import {existsSync,mkdirSync,cpSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {dirname,join} from 'node:path';
const root=dirname(dirname(fileURLToPath(import.meta.url)));
const local=join(root,'node_modules/typescript/bin/tsc');
const args=['-p',join(root,'tsconfig.json'),...(process.argv.includes('--noEmit')?['--noEmit']:[])];
const result=existsSync(local)?spawnSync(process.execPath,[local,...args],{stdio:'inherit'}):spawnSync('tsc',args,{stdio:'inherit'});
if(result.error){console.error('TypeScript compiler unavailable. Install the pinned development dependency.');process.exit(1);}
if(result.status!==0)process.exit(result.status??1);
if(!process.argv.includes('--noEmit')){mkdirSync(join(root,'dist/vendor'),{recursive:true});cpSync(join(root,'vendor/js-sha3'),join(root,'dist/vendor/js-sha3'),{recursive:true});}
