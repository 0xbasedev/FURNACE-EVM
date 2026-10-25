import {furnaceConfig as c,validateConfigDetailed} from '../dist/furnace.config.js';
import {IDENTITY_RULES} from '../dist/identity-rules.js';
import {canonical,keccak} from '../dist/crypto.js';
import {readFileSync,writeFileSync,mkdirSync} from 'node:fs';
import {createHash} from 'node:crypto';
const invalid=validateConfigDetailed(c,'economics');if(invalid.length){console.error(JSON.stringify(invalid,null,2));process.exit(1);}
const code=['furnace.config.ts','accounting.ts','validation.ts','identity-rules.ts','crypto.ts'];
const sources=Object.fromEntries(code.map(p=>[p,createHash('sha256').update(readFileSync(new URL('../'+p,import.meta.url))).digest('hex')]));
const full=canonical(c);
const report={version:c.version,fullConfigHash:keccak(full),policyIdentityHash:keccak(canonical(IDENTITY_RULES)),utf8Bytes:Buffer.byteLength(full),sources,scope:'Configuration and reviewed policy commitments; not deployed bytecode or initialized storage'};
const results=new URL('../results/',import.meta.url);mkdirSync(results,{recursive:true});writeFileSync(new URL('manifest.json',results),JSON.stringify(report,null,2)+'\n');writeFileSync(new URL('config.canonical.json',results),full);
console.log(JSON.stringify(report,null,2));
