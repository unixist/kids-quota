import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile,writeFile,rm} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {fileURLToPath,pathToFileURL} from 'node:url';
import path from 'node:path';
import {createHash,createPublicKey} from 'node:crypto';

test('both browser packages contain compatible manifests and self-contained background scripts',async()=>{
  const root=fileURLToPath(new URL('../../',import.meta.url));
  execFileSync(process.execPath,['scripts/build-extensions.mjs'],{cwd:root});
  for(const browser of ['chrome','safari']) {
    const folder=path.join(root,'extensions/build',browser);
    const manifest=JSON.parse(await readFile(path.join(folder,'manifest.json'),'utf8'));
    assert.equal(manifest.manifest_version,3);
    assert.ok(manifest.permissions.includes('nativeMessaging'));
    assert.ok(manifest.permissions.includes('declarativeNetRequestWithHostAccess'));
    assert.ok(manifest.host_permissions.includes('https://*/*'));
    assert.equal(manifest.permissions.includes('tabs'),browser==='safari','Chrome HTTP(S) host access already permits reading matching tab URLs');
    const backgroundFile=browser==='chrome'?manifest.background.service_worker:manifest.background.scripts[0];
    const background=await readFile(path.join(folder,backgroundFile),'utf8');
    assert.equal(/^import |^export /m.test(background),false);
    execFileSync(process.execPath,['--check',path.join(folder,backgroundFile)]);
    for(const filename of [manifest.action.default_popup,...manifest.content_scripts[0].js,...manifest.web_accessible_resources[0].resources]) {
      assert.ok((await readFile(path.join(folder,filename))).length>0,filename);
    }
    const blockedHTML=await readFile(path.join(folder,'blocked.html'),'utf8');
    assert.match(blockedHTML,/<script\s+type="module"\s+src="blocked\.js"><\/script>/,
      'the packaged blocked page must load its exported JavaScript as a module');
    const blocked=await import(pathToFileURL(path.join(folder,'blocked.js')).href);
    const paused=blocked.blockedPresentation({connected:true,resetTimeZone:'America/Chicago',rule:{
      name:'Chess.com',remainingSeconds:21600,blocked:true,resetAt:'2026-11-16T06:00:00Z'
    }});
    assert.equal(paused.balance,'6 h remaining');
    assert.equal(paused.title,'Chess.com is paused');
    assert.equal(Object.hasOwn(manifest,'externally_connectable'),false,'ordinary pages cannot submit extension messages');
    for(const size of [16,32,48,128]) {
      const png=await readFile(path.join(folder,manifest.icons[size]));
      assert.deepEqual([...png.subarray(0,8)],[137,80,78,71,13,10,26,10]);
      assert.equal(png.readUInt32BE(16),size); assert.equal(png.readUInt32BE(20),size);
      assert.equal(manifest.action.default_icon[size],manifest.icons[size]);
    }
  }
});

test('store ZIP contains only its complete root-level extension and preserves local host pairing',async()=>{
  const root=fileURLToPath(new URL('../../',import.meta.url));
  const metadata=JSON.parse(await readFile(path.join(root,'package.json'),'utf8'));
  const archive=path.join(root,`dist/KidsQuota-Chrome-${metadata.config.chromeStoreVersion}.zip`);
  const localManifestPath=path.join(root,'extensions/build/chrome/manifest.json');
  const localIdPath=path.join(root,'extensions/build/chrome-extension-id.txt');
  execFileSync(process.execPath,['scripts/build-extensions.mjs'],{cwd:root});
  const localManifest=await readFile(localManifestPath), localId=await readFile(localIdPath);
  execFileSync(process.execPath,['scripts/package-chrome-store.mjs'],{cwd:root});
  const before=await readFile(archive);
  const stray=path.join(root,'dist/chrome-store/not-for-upload.txt');
  try {
    await writeFile(stray,'A stale build file must never be uploaded.');
    execFileSync(process.execPath,['scripts/package-chrome-store.mjs'],{cwd:root});
  } finally {await rm(stray,{force:true});}
  assert.deepEqual(await readFile(archive),before,'archive is reproducible and excludes stale output');
  assert.deepEqual(await readFile(localManifestPath),localManifest);
  assert.deepEqual(await readFile(localIdPath),localId);
  const entries=execFileSync('/usr/bin/unzip',['-Z1',archive],{encoding:'utf8'}).trim().split('\n');
  assert.deepEqual(entries,[
    'background.js','blocked.html','blocked.js','content.js','icons/icon128.png',
    'icons/icon16.png','icons/icon32.png','icons/icon48.png','manifest.json',
    'pages.css','popup.html','popup.js'
  ]);
  execFileSync('/usr/bin/unzip',['-t',archive]);
  const manifest=JSON.parse(execFileSync('/usr/bin/unzip',['-p',archive,'manifest.json'],{encoding:'utf8'}));
  assert.equal(manifest.version,metadata.config.chromeStoreVersion);
  assert.equal(Object.hasOwn(manifest,'key'),false);
  assert.equal(Object.hasOwn(manifest,'update_url'),false);
  assert.equal(manifest.background.service_worker,'background.js');
  assert.deepEqual(manifest.permissions,['storage','nativeMessaging','alarms','declarativeNetRequestWithHostAccess']);
  assert.ok(manifest.description.length<=132);
  const checksum=await readFile(archive+'.sha256','utf8');
  assert.equal(checksum,`${createHash('sha256').update(before).digest('hex')}  ${path.basename(archive)}\n`);
});

test('local Chrome key gives a stable native-host ID independent of installation path',async()=>{
  const root=fileURLToPath(new URL('../../',import.meta.url));
  execFileSync(process.execPath,['scripts/build-extensions.mjs'],{cwd:root});
  const source=JSON.parse(await readFile(path.join(root,'extensions/chrome-public-key.json'),'utf8'));
  const manifest=JSON.parse(await readFile(path.join(root,'extensions/build/chrome/manifest.json'),'utf8'));
  const safari=JSON.parse(await readFile(path.join(root,'extensions/build/safari/manifest.json'),'utf8'));
  const bytes=Buffer.from(manifest.key,'base64');
  assert.equal(createPublicKey({key:bytes,format:'der',type:'spki'}).type,'public');
  assert.equal(manifest.key,source.key);
  const id=[...createHash('sha256').update(bytes).digest('hex').slice(0,32)].map(n=>'abcdefghijklmnop'[parseInt(n,16)]).join('');
  assert.match(id,/^[a-p]{32}$/);
  assert.equal((await readFile(path.join(root,'extensions/build/chrome-extension-id.txt'),'utf8')).trim(),id);
  assert.equal(Object.hasOwn(safari,'key'),false);
  assert.equal(Object.hasOwn(source,'privateKey'),false);
});
