// Render the real popup with clearly identified example data for store artwork.
// This preview is never included in the extension upload.
import {readFile, writeFile, mkdir, copyFile} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const out = path.join(root, 'work/chrome-store-preview');
await mkdir(out, {recursive:true});
for (const name of ['popup.js', 'pages.css']) {
  await copyFile(path.join(root, 'extensions/shared', name), path.join(out, name));
}
const popup = await readFile(path.join(root, 'extensions/shared/popup.html'), 'utf8');
await writeFile(path.join(out, 'popup.html'), popup.replace('src="popup.js"', 'src="example-data.js"'));
const snapshot = {
  configured:true, connected:true, coverage:'complete',
  rules:[
    {serviceId:'chesscom', name:'Chess.com', domains:[{hostname:'chess.com', includeSubdomains:true}], remainingSeconds:15600, resetAt:'2026-11-09T06:00:00Z', blocked:false, reason:'available'},
    {serviceId:'chatgpt', name:'ChatGPT', domains:[{hostname:'chatgpt.com', includeSubdomains:true}], remainingSeconds:7800, resetAt:'2026-11-09T06:00:00Z', blocked:false, reason:'available'}
  ]
};
await writeFile(path.join(out, 'example-data.js'), `// Store artwork only; example balances, no live service connection.\nwindow.browser = {runtime:{sendMessage:async () => (${JSON.stringify(snapshot)})}};\nawait import('./popup.js');\n`);
await writeFile(path.join(out, 'index.html'), `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Kids Quota — Chrome Web Store screenshot</title>
<style>
*{box-sizing:border-box}body{margin:0;background:#eef3fa;color:#18243b;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
.canvas{width:1280px;height:800px;display:flex;align-items:center;gap:80px;padding:68px 80px;background:radial-gradient(ellipse at 82% 30%,#d3e6ff 0%,#eef3fa 65%)}
.copy{flex:1;max-width:600px}.brand{font-size:22px;font-weight:650;letter-spacing:-.3px;color:#1263c5;margin:0 0 36px}
h1{font-size:58px;line-height:1.08;letter-spacing:-2px;margin:0 0 24px;font-weight:700}.intro{font-size:23px;line-height:1.5;color:#4c5971;max-width:480px;margin:0 0 30px}
ul{padding:0;margin:0;list-style:none;font-size:19px;line-height:1.6}li{margin:12px 0}li:before{content:'✓';color:#146745;font-weight:700;margin-right:12px}
.requirement{font-size:15px;line-height:1.5;color:#5b6679;margin:38px 0 0;max-width:450px}.example{font-size:13px;color:#687488;letter-spacing:.2px;margin:14px 0 0;text-align:center}
.preview{width:382px;flex:none}iframe{display:block;width:382px;height:680px;border:1px solid #d4dae4;border-radius:15px;background:#f6f6f8;box-shadow:0 24px 64px #162f5224}
</style></head><body><main class="canvas"><section class="copy"><p class="brand">Kids Quota</p><h1>See how much<br>time is left.</h1><p class="intro">Weekly website allowances, shared with linked Mac apps.</p><ul><li>A separate balance for each service</li><li>Custom websites and weekly limits</li><li>Settings managed by a parent</li></ul><p class="requirement">Requires the Kids Quota companion for macOS 14 or later.<br>Install and configure the Mac app before using this extension.</p></section><section class="preview"><iframe title="Kids Quota popup with example balances" src="popup.html"></iframe><p class="example">Chrome popup · Example balances</p></section></main></body></html>`);
console.log(`Preview written to ${out}. Serve this directory and capture index.html at 1280 × 800.`);
