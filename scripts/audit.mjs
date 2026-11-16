import fs from 'node:fs';import path from 'node:path';import {fileURLToPath} from 'node:url';import {createHash} from 'node:crypto';
const root=fileURLToPath(new URL('../',import.meta.url)),read=n=>JSON.parse(fs.readFileSync(path.join(root,n))),hash=b=>createHash('sha256').update(b).digest('hex');
const manifest=read('SOURCE-MANIFEST.json'),dependencies=read('DEPENDENCIES.json'),config=read('build-config.json'),deployment=read('DEPLOYMENT.json'),pkg=read('package.json'),lock=read('package-lock.json');
function need(ok,message){if(!ok)throw Error(message);}
function files(dir){return fs.readdirSync(path.join(root,dir),{withFileTypes:true}).flatMap(e=>{const p=path.posix.join(dir,e.name);need(!e.isSymbolicLink(),'UNEXPECTED_SYMLINK '+p);return e.isDirectory()?files(p):[p];});}
const sourceFiles=files('contracts');
need(sourceFiles.length===manifest.files.length,'UNMANIFESTED_SOURCE');
for(const f of manifest.files){const content=fs.readFileSync(path.join(root,f.path),'utf8');need(hash(content)===f.sha256,'SOURCE_HASH '+f.path);need(!/[\u0400-\u04ff]/.test(content),'NON_ENGLISH_SOURCE '+f.path);need(!/\/\/|\/\*/.test(content),'SOURCE_COMMENT '+f.path);need(!f.path.includes('@openzeppelin'),'VENDORED_DEPENDENCY');}
for(const unit of config)for(const name of unit.sources)need(manifest.files.some(f=>f.unit===unit.id&&f.source===name)||dependencies.files.some(f=>f.unit===unit.id&&f.source===name),'UNDECLARED_IMPORT '+name);
for(const [name,version]of Object.entries(pkg.devDependencies)){need(lock.packages[''].devDependencies[name]===version,'LOCK_ROOT '+name);need(lock.packages['node_modules/'+name]?.version===version,'LOCK_VERSION '+name);}
need(deployment.chainId===4663&&deployment.modules.length===21,'DEPLOYMENT_SCOPE');
for(const m of deployment.modules)need(m.runtimeMatches&&m.compiledArtifactMatches&&fs.existsSync(path.join(root,m.source)),'DEPLOYMENT_SOURCE '+m.name);
const scanned=fs.readdirSync(root,{withFileTypes:true}).filter(e=>!['node_modules','build','.git'].includes(e.name)).flatMap(e=>e.isDirectory()?files(e.name):[e.name]);
for(const file of scanned){need(!/\.(?:key|pem|keystore)$|(?:^|\/)\.env(?:\.|$)/i.test(file),'SENSITIVE_FILE '+file);const content=fs.readFileSync(path.join(root,file),'utf8');need(!/-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|\b(?:ghp|github_pat)_[A-Za-z0-9_]{20,}|https?:\/\/[^\s"']*alchemy\.com\/v2\/[A-Za-z0-9_-]{8,}/.test(content),'SECRET_PATTERN '+file);need(!/[A-Z]:[\\/](?:Users|opt)[\\/]/.test(content),'LOCAL_PATH '+file);}
console.log(JSON.stringify({status:'PUBLIC_SOURCE_CHECKS_PASSED',ownSolidityFiles:sourceFiles.length,modules:deployment.modules.length,filesScanned:scanned.length,thirdPartySolidityVendored:0,networkRequests:0}));
