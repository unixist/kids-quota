import {readFile,mkdir,rm,utimes,writeFile} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
import {buildBrowser} from './build-extensions.mjs';

const root=fileURLToPath(new URL('../',import.meta.url));
const metadata=JSON.parse(await readFile(path.join(root,'package.json'),'utf8'));
const version=metadata.config.chromeStoreVersion;
if(!/^\d+\.\d+\.\d+(?:\.\d+)?$/.test(version) || version.split('.').some(part=>Number(part)>65535)) throw new Error('Invalid Chrome Web Store version');
const out=path.join(root,'dist/chrome-store');
const archive=path.join(root,`dist/KidsQuota-Chrome-${version}.zip`);
await mkdir(path.dirname(archive),{recursive:true});
// No local manifest key: Google assigns the published extension its own ID.
// The native host installer must explicitly allow that ID before this package
// can communicate with the companion service on an installed Mac.
const files=await buildBrowser({platform:'chrome',out,version});
// Fixed timestamps + explicit sorted allowlist keep archives reproducible and
// exclude stale files, local keys, native executables, and development fixtures.
for(const file of files) await utimes(path.join(out,file),new Date('2000-01-01T00:00:00Z'),new Date('2000-01-01T00:00:00Z'));
await rm(archive,{force:true});
execFileSync('/usr/bin/zip',['-X','-q',archive,...files],{cwd:out,env:{...process.env,TZ:'UTC'}});
const sha=createHash('sha256').update(await readFile(archive)).digest('hex');
await writeFile(archive+'.sha256',`${sha}  ${path.basename(archive)}\n`);
console.log(`Chrome Web Store package: ${archive}`);
console.log(`SHA-256: ${sha}`);
