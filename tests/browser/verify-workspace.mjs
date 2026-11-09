// Fictional-only end-to-end checks using Edge CDP and a test-owned PowerShell host.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { watch } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const [browser, destination] = process.argv.slice(2);
assert(browser && destination, 'Usage: node verify-workspace.mjs <edge.exe> <new-output-directory>');
const output=resolve(destination); await mkdir(output);
const profile=join(output,'browser-profile'); await mkdir(profile);
const result={status:'ERROR',checks:[],screenshots:[]};
const port=44000+Math.floor(Math.random()*5000);
const fixture=spawn('pwsh',['-NoProfile','-File',fileURLToPath(new URL('./Start-WorkspaceFixture.ps1',import.meta.url)),'-FixtureRoot',join(output,'fixture'),'-Port',String(port)],{windowsHide:true});
let hostOutput='', hostError='', sessionUrl, socket, send, child;
fixture.stderr.on('data',chunk=>{hostError=(hostError+chunk).slice(-5000);});
const hostReady=new Promise((ready,reject)=>{
  const timer=setTimeout(()=>reject(new Error('Workspace fixture did not start. '+hostError)),20000);
  fixture.stdout.on('data',chunk=>{
    hostOutput+=chunk;
    for (const line of hostOutput.split(/\r?\n/)) {
      if (line.startsWith('{')) { try { sessionUrl=JSON.parse(line).url; clearTimeout(timer); ready(); } catch { /* Partial line. */ } }
    }
  });
  fixture.once('error',reject); fixture.once('exit',code=>{if(!sessionUrl){clearTimeout(timer);reject(new Error('Fixture exited '+code+': '+hostError));}});
});
function check(condition,name){assert(condition,name);result.checks.push(name);}
async function waitFile(){
  return new Promise((ready,reject)=>{
    const timer=setTimeout(()=>{watcher.close();reject(new Error('No CDP endpoint'));},15000);
    const watcher=watch(profile,()=>void inspect());
    async function inspect(){try{const text=await readFile(join(profile,'DevToolsActivePort'),'utf8');if(/^\d+\r?\n\/devtools\/browser\//.test(text)){clearTimeout(timer);watcher.close();ready(text);}}catch(error){if(!['ENOENT','EBUSY'].includes(error.code))reject(error);}}
    void inspect();
  });
}
try{
  await hostReady;
  const origin=new URL(sessionUrl).origin, token=new URL(sessionUrl).hash.slice(1);
  const post=(action,body={},headers={})=>fetch(`${origin}/api/${action}`,{method:'POST',headers:{'Content-Type':'application/json',Origin:origin,'X-Handoff-Session':token,...headers},body:JSON.stringify(body)});
  check((await post('state',{}, {'X-Handoff-Session':'wrong'})).status===403,'HTTP: invalid session token refused');
  check((await post('state',{}, {Origin:'https://attacker.invalid'})).status===403,'HTTP: cross-origin request refused');
  check((await fetch(`${origin}/../Handoff.Workspace.psm1`)).status===404,'HTTP: non-allowlisted files unavailable');
  check((await post('state',{padding:'x'.repeat(70000)})).status===404,'HTTP: oversized input refused');
  const root=await fetch(origin);
  check(root.headers.get('content-security-policy').includes("frame-ancestors 'none'") && root.headers.get('cache-control')==='no-store','HTTP: restrictive CSP and no-store headers');
  child=spawn(browser,['--headless=new','--no-first-run','--no-default-browser-check','--disable-background-networking','--disable-component-update','--disable-sync','--remote-debugging-address=127.0.0.1','--remote-debugging-port=0',`--user-data-dir=${profile}`,'about:blank'],{stdio:['ignore','ignore','ignore'],windowsHide:true});
  const [debugPort,endpoint]=(await waitFile()).trim().split(/\r?\n/);
  socket=new WebSocket(`ws://127.0.0.1:${debugPort}${endpoint}`);
  await new Promise((ready,reject)=>{socket.addEventListener('open',ready,{once:true});socket.addEventListener('error',reject,{once:true});});
  let next=0; const pending=new Map(), events=[];
  socket.addEventListener('message',event=>{const m=JSON.parse(event.data);if(m.id){const p=pending.get(m.id);if(!p)return;clearTimeout(p.timer);pending.delete(m.id);if(m.error)p.reject(new Error(JSON.stringify(m.error)));else p.resolve(m.result);}else events.push(m);});
  send=(method,params={},sessionId)=>new Promise((resolveCall,reject)=>{const id=++next;const timer=setTimeout(()=>{pending.delete(id);reject(new Error('CDP timeout: '+method));},15000);pending.set(id,{resolve:resolveCall,reject,timer});socket.send(JSON.stringify({id,method,params,...(sessionId?{sessionId}:{})}));});
  const {targetId}=await send('Target.createTarget',{url:'about:blank'});
  const {sessionId}=await send('Target.attachToTarget',{targetId,flatten:true});
  const call=(method,params)=>send(method,params,sessionId);
  const evaluate=async expression=>{const r=await call('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true});assert(!r.exceptionDetails,JSON.stringify(r.exceptionDetails));return r.result.value;};
  const until=async expression=>evaluate(`new Promise((resolve,reject)=>{const test=()=>{if(${expression}){observer.disconnect();clearTimeout(timer);resolve(true);}};const observer=new MutationObserver(test);observer.observe(document,{subtree:true,childList:true,attributes:true});const timer=setTimeout(()=>{observer.disconnect();reject(new Error('UI condition timed out'));},10000);test();})`);
  const click=async selector=>evaluate(`{const e=document.querySelector(${JSON.stringify(selector)});e.focus();e.click();true;}`);
  const fill=async(selector,value)=>evaluate(`{const e=document.querySelector(${JSON.stringify(selector)});e.value=${JSON.stringify(value)};e.dispatchEvent(new Event('input',{bubbles:true}));true;}`);
  const screenshot=async name=>{const r=await call('Page.captureScreenshot',{format:'png'});const file=join(output,name+'.png');await writeFile(file,Buffer.from(r.data,'base64'),{flag:'wx'});result.screenshots.push(file);};
  await call('Page.enable'); await call('Runtime.enable'); await call('Network.enable');
  await call('Emulation.setDeviceMetricsOverride',{width:1440,height:1000,deviceScaleFactor:1,mobile:false});
  await call('Page.navigate',{url:sessionUrl});
  await until(`document.querySelectorAll('.investigation-button').length===2`);
  await until(`document.querySelector('h1').textContent.includes('Hostile')`);
  check(await evaluate(`document.querySelector('h1').textContent.includes('<img')&&!window.__injected&&document.querySelector('#evidence').querySelectorAll('script,img').length===0`),'Hostile tenant names stay literal text');
  await click('[data-id="example"]'); await until(`document.querySelector('h1').textContent==='Support team'`);
  check(await evaluate(`document.body.innerText.includes('Incomplete evidence')&&document.body.innerText.includes('Fictional sample')`),'Fictional source and incomplete coverage are visible');
  check(await evaluate(`document.querySelectorAll('.relationship').length===2&&document.querySelector('.relationship h3').textContent==='Require MFA for support'`),'Friendly policy names lead the evidence panel');
  check(await evaluate(`!document.querySelector('#evidence details').open`),'Raw IDs and configuration start collapsed');
  await screenshot('workspace-desktop');
  for(const width of [1024,390,320]){
    await call('Emulation.setDeviceMetricsOverride',{width,height:844,deviceScaleFactor:1,mobile:width<640});
    check(await evaluate(`document.documentElement.scrollWidth<=innerWidth+1&&document.body.scrollWidth<=innerWidth+1`),`No horizontal overflow at ${width}px`);
    if(width===390)await screenshot('workspace-mobile');
  }
  await call('Emulation.setDeviceMetricsOverride',{width:1440,height:1000,deviceScaleFactor:1,mobile:false});
  await click('#settings-open'); await until(`document.querySelector('#settings').open`);
  check(await evaluate(`document.activeElement.closest('#settings')!==null`),'Settings dialog receives focus');
  await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Escape',code:'Escape',windowsVirtualKeyCode:27});
  await call('Input.dispatchKeyEvent',{type:'keyUp',key:'Escape',code:'Escape',windowsVirtualKeyCode:27});
  await until(`!document.querySelector('#settings').open`);
  check(await evaluate(`document.activeElement.id==='settings-open'`),'Escape closes settings and returns focus');
  await click('#settings-open'); await fill('#api-key','fictional-provider-key-123');
  check(await evaluate(`document.querySelector('#settings').dispatchEvent(new Event('close'));document.querySelector('#api-key').value==='fictional-provider-key-123'`),'A queued close event cannot clear a reopened key form');
  await evaluate(`document.querySelector('#settings-form').requestSubmit();true`);
  await until(`!document.querySelector('#settings').open&&document.querySelector('#key-status').textContent==='OpenAI'`);
  check(await evaluate(`document.querySelector('#api-key').value===''&&localStorage.length===0&&sessionStorage.length===0`),'Key field cleared; no browser storage used');
  await fill('#question','Which policies reference this group?');
  await evaluate(`document.querySelector('#chat-form').requestSubmit();true`);
  await until(`document.querySelector('#sharing').open`);
  await screenshot('workspace-sharing');
  check(await evaluate(`document.querySelectorAll('.message.assistant').length===0&&document.querySelector('#payload').textContent.includes('Which policies reference this group?')`),'Prepared payload is inspectable before any answer or send');
  await click('#share-cancel'); await until(`!document.querySelector('#send').disabled`);
  check(await evaluate(`document.querySelector('#question').value==='Which policies reference this group?'&&document.querySelectorAll('.message').length===0`),'Keep local cancels and retains the draft');
  await evaluate(`document.querySelector('#chat-form').requestSubmit();true`); await until(`document.querySelector('#sharing').open`);
  await click('#share-approve'); await until(`document.querySelectorAll('.message.assistant').length===1&&!document.querySelector('#send').disabled`);
  check(await evaluate(`document.querySelector('.message.assistant').textContent.includes('0 previous messages')&&!window.__injected&&!document.querySelector('#messages img[src=x]')`),'Approved first turn uses fake provider and safely renders model text');
  check(await evaluate(`document.querySelector('.response-table').tabIndex===0&&document.querySelector('.response-table').getAttribute('aria-labelledby')===document.querySelector('.response-table caption').id&&document.querySelectorAll('.response-table thead th[scope="col"]').length===3&&document.querySelectorAll('.response-table tbody th[scope="row"]').length===2`),'Model tables have semantic headers and a named keyboard-scrollable container');
  check(await evaluate(`document.querySelector('.message.assistant em').textContent==='configured'&&document.querySelectorAll('.message.assistant ol li').length===2&&document.querySelector('.response-table code').textContent==='Support team'&&document.querySelector('.message.assistant').textContent.includes('Literal | <img')&&document.querySelector('.message.assistant').textContent.includes('Unclosed formatting: '+String.fromCharCode(96)+'literal and **unclosed')&&!window.__injected`),'Formatting preserves escaped pipes and unmatched markers without executing HTML');
  for(const width of [390,320]){
    await call('Emulation.setDeviceMetricsOverride',{width,height:844,deviceScaleFactor:1,mobile:true});
    check(await evaluate(`document.documentElement.scrollWidth<=innerWidth+1&&document.querySelector('.response-table').scrollWidth>document.querySelector('.response-table').clientWidth`),`Answer table scrolls locally without page overflow at ${width}px`);
  }
  await call('Emulation.setDeviceMetricsOverride',{width:1440,height:1000,deviceScaleFactor:1,mobile:false});
  await fill('#question','What does that mean for this group?');
  await evaluate(`document.querySelector('#chat-form').requestSubmit();true`);
  await until(`document.querySelectorAll('.message.assistant').length===2&&!document.querySelector('#send').disabled`);
  check(await evaluate(`document.querySelector('#messages').textContent.includes('2 previous messages')&&!document.querySelector('#sharing').open`),'Follow-up includes previous question and answer under scoped approval');
  await screenshot('workspace-conversation');
  await evaluate(`document.querySelector('#question').focus();document.querySelector('#question').value='unfinished composition';document.querySelector('#question').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',isComposing:true,bubbles:true}));true`);
  check(await evaluate(`document.querySelectorAll('.message.assistant').length===2&&!document.querySelector('#send').disabled`),'IME composition does not submit');
  await click('[data-id="saved-1"]');await until(`document.querySelector('h1').textContent.includes('Hostile')`);
  check(await evaluate(`document.querySelectorAll('.message').length===0`),'Conversation does not leak into another investigation');
  await click('[data-id="example"]');await until(`document.querySelectorAll('.message.assistant').length===2`);
  await click('#new-chat');await until(`document.querySelectorAll('.message').length===0`);
  await fill('#question','A fresh question');await evaluate(`document.querySelector('#chat-form').requestSubmit();true`);await until(`document.querySelector('#sharing').open`);
  check(true,'New conversation revokes prior sharing approval');
  await click('#share-cancel');await until(`!document.querySelector('#send').disabled`);
  await click('#settings-open');await click('#forget');await until(`!document.querySelector('#settings').open&&document.querySelector('#key-status').textContent==='Not set'`);
  check(true,'Forget key clears configuration and conversation');
  check(!events.some(e=>e.method==='Runtime.exceptionThrown'),'No unhandled browser exceptions');
  const requests=events.filter(e=>e.method==='Network.requestWillBeSent').map(e=>e.params.request.url);
  check(requests.every(url=>url.startsWith(origin+'/')),'All page requests remain on the local host');
  result.status='PASS';
}catch(error){result.failure=error.stack;result.hostError=hostError;process.exitCode=1;}
finally{
  if(send&&socket?.readyState===WebSocket.OPEN){try{await send('Browser.close');}catch{/* Socket can close before response. */}}
  if(socket)socket.close();
  if(child&&!child.killed)child.kill();
  if(sessionUrl){try{const url=new URL(sessionUrl);await fetch(url.origin+'/api/stop',{method:'POST',headers:{Origin:url.origin,'Content-Type':'application/json','X-Handoff-Session':url.hash.slice(1)},body:'{}'});}catch{/* Fixture may already have exited. */}}
  if(!fixture.killed)fixture.kill();
  await writeFile(join(output,'workspace-checks.json'),JSON.stringify(result,null,2),{flag:'wx'});
  console.log(JSON.stringify(result,null,2));
}
