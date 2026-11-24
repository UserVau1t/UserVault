import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import solc from 'solc';

const manifest = JSON.parse(await readFile(new URL('build.json', import.meta.url)));
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
if (solc.version() !== manifest.compiler) throw Error('Solidity compiler version differs from the release');

async function source(name) {
  if (name.startsWith('@uniswap/')) {
    const [, repository, ...path] = name.split('/');
    const revision = manifest.uniswap[repository];
    const response = await fetch(`https://raw.githubusercontent.com/Uniswap/${repository}/${revision}/${path.join('/')}`);
    if (!response.ok) throw Error(`Cannot download ${name} at ${revision} (HTTP ${response.status})`);
    return response.text();
  }
  const file = name.startsWith('contracts/') ? name : '../node_modules/' + name;
  return readFile(new URL(file, import.meta.url), 'utf8');
}

const sources = new Map();
for (const [name, pin] of Object.entries(manifest.sources)) {
  const text = (await source(name)).replace(/\r?\n/g, pin.lineEndings === 'CRLF' ? '\r\n' : '\n');
  if (hash(text) !== pin.sha256) throw Error('Source hash mismatch for ' + name);
  sources.set(name, text);
}

for (const [name, unit] of Object.entries(manifest.units)) {
  const settings = {
    viaIR: true, evmVersion: 'cancun', optimizer: {enabled: true, runs: unit.runs},
    outputSelection: {[unit.entry]: {[name]: ['evm.bytecode.object', 'evm.deployedBytecode.object']}}
  };
  const input = {language: 'Solidity', sources: {[unit.entry]: {content: sources.get(unit.entry)}}, settings};
  const built = JSON.parse(solc.compile(JSON.stringify(input), {import: file =>
    sources.has(file) ? {contents: sources.get(file)} : {error: 'Unknown import ' + file}}));
  const errors = (built.errors || []).filter(e => e.severity === 'error');
  if (errors.length) throw Error(errors.map(e => e.formattedMessage).join('\n'));
  const {bytecode, deployedBytecode} = built.contracts[unit.entry][name].evm;
  let creation = bytecode.object, runtime = deployedBytecode.object;
  if (unit.releaseMetadata) {
    // The retained funding implementation predates changes to its imported payout library.
    // Accept only this artifact's metadata difference, including in the embedded runtime.
    const bytes = 2 + parseInt(runtime.slice(-4), 16);
    const footer = runtime.slice(-2 * bytes);
    if (unit.releaseMetadata.length !== footer.length || creation.split(footer).length !== 2) {
      throw Error('Unexpected compiler metadata for ' + name);
    }
    creation = creation.replace(footer, unit.releaseMetadata);
    runtime = runtime.slice(0, -footer.length) + unit.releaseMetadata;
  }
  if (hash(Buffer.from(runtime, 'hex')) !== unit.runtimeTemplateSha256 ||
      hash(Buffer.from(creation, 'hex')) !== unit.creationSha256) throw Error('Release artifact mismatch for ' + name);
  console.log(name + (unit.releaseMetadata ? ' matches with the original metadata footer' : ' matches byte for byte'));
}
