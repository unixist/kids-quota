import {readFile,writeFile,mkdir,copyFile} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash,createPublicKey} from 'node:crypto';
import {writeExtensionIcons} from './generate-extension-icons.mjs';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const source=path.join(root,'extensions/shared');

export async function buildBrowser({platform,out,version='0.1.3',chromeKey}) {
  if (!['chrome','safari'].includes(platform)) throw new Error('Unknown browser platform');
  const core=(await readFile(path.join(source,'core.js'),'utf8')).replace(/^export /gm,'');
  const controller=(await readFile(path.join(source,'controller.js'),'utf8')).replace(/^import .*;\n/gm,'').replace(/^export /gm,'');
  await mkdir(out,{recursive:true});
  const icons=await writeExtensionIcons(out);
  const manifest={manifest_version:3,name:'Kids Quota',version,description:'Weekly website time allowances and remaining balances. Requires the Kids Quota companion app for macOS.',
    // Chrome's HTTP(S) host permissions already expose matching tab URLs. The
    // broad tabs grant is unnecessary there; retain Safari's existing grant.
    permissions:[...(platform==='safari'?['tabs']:[]),'storage','nativeMessaging','alarms','declarativeNetRequestWithHostAccess'],
    host_permissions:['http://*/*','https://*/*'],
    icons,
    background:platform==='chrome'?{service_worker:'background.js'}:{scripts:['background.js'],persistent:false},
    action:{default_title:'Kids Quota',default_popup:'popup.html',default_icon:icons},
    content_scripts:[{matches:['http://*/*','https://*/*'],js:['content.js'],run_at:'document_start',all_frames:false}],
    web_accessible_resources:[{resources:['blocked.html','blocked.js','pages.css'],matches:['http://*/*','https://*/*']}]
  };
  if(platform==='chrome') { manifest.minimum_chrome_version='109'; if(chromeKey) manifest.key=chromeKey; }
  await writeFile(path.join(out,'manifest.json'),JSON.stringify(manifest,null,2)+'\n');
  await writeFile(path.join(out,'background.js'),`(() => {\n'use strict';\n${core}\n${controller}\nconst controller=createController({api:globalThis.browser || globalThis.chrome,platform:${JSON.stringify(platform)}});\ncontroller.start().catch(()=>{});\n})();\n`);
  const resources=['content.js','blocked.html','blocked.js','popup.html','popup.js','pages.css'];
  for(const name of resources) await copyFile(path.join(source,name),path.join(out,name));
  return ['manifest.json','background.js',...resources,...Object.values(icons)].sort();
}

if (process.argv[1] && path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  const {key:chromeKey}=JSON.parse(await readFile(path.join(root,'extensions/chrome-public-key.json'),'utf8'));
  const keyBytes=Buffer.from(chromeKey,'base64');
  // Validate the public key so a malformed edit cannot silently change host pairing.
  createPublicKey({key:keyBytes,format:'der',type:'spki'});
  const chromeID=[...createHash('sha256').update(keyBytes).digest('hex').slice(0,32)].map(n=>'abcdefghijklmnop'[parseInt(n,16)]).join('');
  for (const platform of ['chrome','safari']) {
    await buildBrowser({platform,out:path.join(root,'extensions/build',platform),chromeKey});
    console.log(`Built extensions/build/${platform}`);
  }
  await writeFile(path.join(root,'extensions/build/chrome-extension-id.txt'),chromeID+'\n');
}
