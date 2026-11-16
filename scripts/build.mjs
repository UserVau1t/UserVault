import fs from 'node:fs';import path from 'node:path';import {fileURLToPath} from 'node:url';import {createHash} from 'node:crypto';import solc from 'solc';
const root=fileURLToPath(new URL('../',import.meta.url)),read=name=>JSON.parse(fs.readFileSync(path.join(root,name))),sha=b=>createHash('sha256').update(b).digest('hex');
if(!solc.version().startsWith('0.8.30+commit.73712a01'))throw Error('COMPILER_VERSION');
const dependencies=read('DEPENDENCIES.json').files,manifest=read('SOURCE-MANIFEST.json').files,configs=read('build-config.json');
export function source(unit,name){
 const d=dependencies.find(x=>x.unit===unit&&x.source===name),own=manifest.find(x=>x.unit===unit&&x.source===name);
 if(!d&&!own)throw Error('UNDECLARED_SOURCE '+unit+'/'+name);
 if(name.split('/').some(x=>x==='..'||x==='')||name.startsWith('/'))throw Error('SOURCE_PATH');
 const location=d?path.join(root,'node_modules',name):path.join(root,own.path),content=fs.readFileSync(location,'utf8');
 if(sha(content)!==(d??own).sha256)throw Error('SOURCE_HASH '+unit+'/'+name);
 return {content};
}
export function compile(unit){
 const sources=Object.fromEntries(unit.sources.map(name=>[name,source(unit.id,name)]));
 const targets=[...unit.targets];
 const fields=['abi','storageLayout','evm.bytecode.object','evm.bytecode.linkReferences','evm.deployedBytecode.object','evm.deployedBytecode.immutableReferences','evm.deployedBytecode.linkReferences'];
 const outputSelection={};for(const t of targets)(outputSelection[t.source]??={})[t.name]=fields;
 const output=JSON.parse(solc.compile(JSON.stringify({language:'Solidity',sources,settings:{...unit.settings,outputSelection}})));
 const errors=(output.errors??[]).filter(e=>e.severity==='error');if(errors.length)throw Error(errors.map(e=>e.formattedMessage).join('\n'));
 return Object.fromEntries(targets.map(t=>{const c=output.contracts[t.source][t.name];return [t.name,{contractName:t.name,sourceName:t.source,abi:c.abi,storageLayout:c.storageLayout,bytecode:'0x'+c.evm.bytecode.object,linkReferences:c.evm.bytecode.linkReferences,deployedBytecode:'0x'+c.evm.deployedBytecode.object,immutableReferences:c.evm.deployedBytecode.immutableReferences,runtimeLinkReferences:c.evm.deployedBytecode.linkReferences}];}));
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)){
 fs.mkdirSync(path.join(root,'build'),{recursive:true});
 for(const unit of configs){
  if(process.argv.includes('--unit')&&unit.id!==process.argv[process.argv.indexOf('--unit')+1])continue;
  const results=compile(unit);fs.writeFileSync(path.join(root,'build',unit.id+'.json'),JSON.stringify(results));
  console.log(JSON.stringify({unit:unit.id,contracts:Object.keys(results),compiler:solc.version()}));
 }
}
