import {furnaceConfig,validateConfigDetailed} from '../dist/furnace.config.js';
const stage=process.argv[2]??'deployment';
if(!['economics','deployment'].includes(stage)){console.error('Use economics or deployment');process.exit(2);}
const diagnostics=validateConfigDetailed(furnaceConfig,stage);
console.log(JSON.stringify({stage,scope:'local configuration only; not code, chain state, or audit approval',releaseApproved:false,diagnostics},null,2));
process.exitCode=diagnostics.length?1:0;
