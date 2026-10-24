import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import path from 'node:path';

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
