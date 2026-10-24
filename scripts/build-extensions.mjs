import {readFile,writeFile,mkdir,copyFile} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const source=path.join(root,'extensions/shared');
const core=(await readFile(path.join(source,'core.js'),'utf8')).replace(/^export /gm,'');
const controller=(await readFile(path.join(source,'controller.js'),'utf8')).replace(/^import .*;\n/gm,'').replace(/^export /gm,'');
for (const platform of ['chrome','safari']) {
  const out=path.join(root,'extensions/build',platform);
  await mkdir(out,{recursive:true});
  const manifest={manifest_version:3,name:'Kids Quota',version:'0.1.0',description:'Shared weekly website and Mac app allowances.',
    permissions:['tabs','storage','nativeMessaging','alarms','declarativeNetRequestWithHostAccess'],
    host_permissions:['http://*/*','https://*/*'],
    background:platform==='chrome'?{service_worker:'background.js'}:{scripts:['background.js'],persistent:false},
    action:{default_title:'Kids Quota',default_popup:'popup.html'},
    content_scripts:[{matches:['http://*/*','https://*/*'],js:['content.js'],run_at:'document_start',all_frames:false}],
    web_accessible_resources:[{resources:['blocked.html','blocked.js','pages.css'],matches:['http://*/*','https://*/*']}]
  };
  if(platform==='chrome') manifest.minimum_chrome_version='109';
  await writeFile(path.join(out,'manifest.json'),JSON.stringify(manifest,null,2)+'\n');
  await writeFile(path.join(out,'background.js'),`(() => {\n'use strict';\n${core}\n${controller}\nconst controller=createController({api:globalThis.browser || globalThis.chrome,platform:${JSON.stringify(platform)}});\ncontroller.start().catch(()=>{});\n})();\n`);
  for(const name of ['content.js','blocked.html','blocked.js','popup.html','popup.js','pages.css']) await copyFile(path.join(source,name),path.join(out,name));
  console.log(`Built extensions/build/${platform}`);
}
