import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
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
    const backgroundFile=browser==='chrome'?manifest.background.service_worker:manifest.background.scripts[0];
    const background=await readFile(path.join(folder,backgroundFile),'utf8');
    assert.equal(/^import |^export /m.test(background),false);
    execFileSync(process.execPath,['--check',path.join(folder,backgroundFile)]);
    for(const filename of [manifest.action.default_popup,...manifest.content_scripts[0].js,...manifest.web_accessible_resources[0].resources]) {
      assert.ok((await readFile(path.join(folder,filename))).length>0,filename);
    }
    assert.equal(Object.hasOwn(manifest,'externally_connectable'),false,'ordinary pages cannot submit extension messages');
  }
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
