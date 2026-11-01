#!/usr/bin/env node
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';
import { performance } from 'node:perf_hooks';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { Client,text,index,ok } from '../native-android/test/client.mjs';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const pkg='dev.opencu.android.fixture';
let serial,keep=false,desktop=false,idleMs,idleMode=false;
const args=process.argv.slice(2);
for(let i=0;i<args.length;i++){if(args[i]==='--serial'&&args[i+1])serial=args[++i];else if(args[i]==='--keep')keep=true;else if(args[i]==='--desktop')desktop=true;else if(args[i]==='--idle-ms'&&args[i+1])idleMs=Number(args[++i]);else throw new Error('Usage: verify-android.mjs [--serial S] [--keep] [--desktop] [--idle-ms N]');}
const sdk=process.env.ANDROID_HOME??process.env.ANDROID_SDK_ROOT??path.join(os.homedir(),'Library/Android/sdk');
const adb=process.env.ADB??path.join(sdk,'platform-tools/adb');
function adbRaw(args,timeout=30000){const r=spawnSync(adb,args,{encoding:'utf8',timeout,maxBuffer:4*1024*1024});if(r.error)throw r.error;if(r.status!==0)throw new Error(`adb failed: ${r.stderr||r.stdout}`);return r.stdout.trim();}
if(!serial){const devices=adbRaw(['devices','-l']).split('\n').filter(l=>/\bdevice\b/.test(l)&&/model:PGBM10\b/.test(l));if(devices.length!==1)throw new Error('Expected exactly one connected PGBM10; use --serial. Never pairs or resets adb.');serial=devices[0].split(/\s/)[0];}
const device=(...args)=>adbRaw(['-s',serial,...args]);
const shell=(...args)=>device('shell','-T',...args);
const sha=file=>createHash('sha256').update(readFileSync(file)).digest('hex');
function awake(){const power=shell('dumpsys power'),policy=shell('dumpsys window policy');assert.match(power,/mWakefulness=Awake\b/,'Phone screen is off. No wake/unlock attempted.');assert.match(policy,/\bshowing=false\b/,'Phone is locked or lock status is unknown.');}
function foreground(){return shell('dumpsys activity activities').match(/topResumedActivity=ActivityRecord\{[^\n]*?\s([\w.]+)\//)?.[1];}
function fixtureFront(){assert.equal(personStopped,false,'Physical stop latched; no further operation or reconnection');awake();assert.equal(foreground(),desktop?'com.android.launcher':pkg,'A different app came forward; stop without reading or operating it.');}
function enginePids(){return shell('ps -A -o PID,ARGS').split('\n').filter(l=>/^\s*\d+\s+(?:app_process(?:32|64)?\s|dev\.opencu\.android\.Main)/.test(l)&&l.includes('dev.opencu.android.Main')).map(l=>l.trim().split(/\s+/)[0]);}
const truth=()=>JSON.parse(shell('run-as',pkg,'cat','files/truth.json'));
const evidence={schema:1,date:new Date().toISOString(),milestone:desktop?2:1,desktop,device:{model:device('shell','getprop','ro.product.model'),sdk:Number(device('shell','getprop','ro.build.version.sdk'))},milestone1Baseline:desktop?{textReadMedianMs:272,indexedClickMedianMs:481,screenshotMedianMs:763,batchPlainClickStepMedianMs:232}:null,version:JSON.parse(readFileSync(path.join(root,'package.json'))).version,engineSha256:sha(path.join(root,'.build/android/opencu-android.jar')),fixtureSha256:sha(path.join(root,'.build/android/opencu-fixture.apk')),runs:[],timings:{},manual:{physicalTripleVolumeDown:'not performed; owner follow-up',physicalInterruption:'not performed; owner follow-up',lockRefusal:'logic checked; no lock/wake/unlock performed'},transcript:{},cleanup:{}};
let client,installed=false,personStopped=false;
const originalPids=enginePids();
function connect(){assert.equal(personStopped,false,'Do not reconnect after a person stop');const c=new Client(root,serial,{env:idleMode&&idleMs?{OPENCU_ANDROID_IDLE_MS:String(idleMs)}:{}});c.onStop=()=>{personStopped=true;};return c;}
function guard(result){if(['PERSON_ACTIVE','USER_STOPPED'].includes(result?._meta?.['opencu/error']))personStopped=true;return result;}
async function call(name,arguments_={}){fixtureFront();return guard(await client.call(name,{app:pkg,...arguments_}));}
async function read(){return ok(await call('get_app_state'));}
async function click(s,id){return ok(await call('click',{element_index:index(s,`id=${id} `)}));}
async function check(name,fn,checks){const start=performance.now();const details=await fn();checks.push({name,pass:true,elapsedMs:Math.round(performance.now()-start),...details});console.log(`PASS ${name}`);}
try{
  awake();assert.ok([pkg,'com.android.launcher'].includes(foreground()),'Start only with fixture or launcher in front');
  const apk=path.join(root,'.build/android/opencu-fixture.apk');
  const lookup=spawnSync(adb,['-s',serial,'shell','-T','pm','path',pkg],{encoding:'utf8',timeout:15000});
  if(lookup.error||(lookup.status!==0&&!(lookup.status===1&&!lookup.stdout.trim()&&!lookup.stderr.trim())))throw new Error(`Cannot query fixture installation: ${lookup.error?.message??lookup.stderr}`);
  const installedPath=lookup.stdout.trim().replace(/^package:/,'');
  let same=false;if(installedPath)same=shell('sha256sum',installedPath).split(/\s/)[0]===sha(apk);
  if(!same){console.log('Installing OpenCU fixture; any OEM confirmation must be completed by the owner.');const r=spawnSync(adb,['-s',serial,'install','--no-incremental','-r',apk],{encoding:'utf8',timeout:120000});if(r.error||r.status!==0||!r.stdout.includes('Success'))throw new Error(`Fixture install did not complete; no automatic retry: ${r.error?.message??r.stderr??r.stdout}`);}
  installed=true;
  const doctorRun=spawnSync(path.join(root,'bin/opencu'),['android','--serial',serial,'doctor'],{encoding:'utf8',timeout:15000});
  assert.equal(doctorRun.status,0,doctorRun.stderr);const doctor=JSON.parse(doctorRun.stdout);
  evidence.doctor=doctor;assert.equal(doctor.uid,2000);assert.equal(doctor.uiAutomationConnected,true);assert.equal(doctor.personMonitor.ready,true);
  shell('am','force-stop',pkg);
  assert.equal(foreground(),'com.android.launcher','Fresh launch check must begin on the launcher');
  for(let run=1;run<=3;run++){
    awake();assert.ok([pkg,'com.android.launcher'].includes(foreground()),'Unexpected app before fixture run');
    client=connect();const init=await client.initialize();const tools=await client.tools();assert.equal(tools.length,desktop?13:13);
    let desktopStart=null;
    if(desktop){
      const mainBefore=foreground();
      desktopStart=ok(await client.call('agent_desktop',{action:'start'}));
      assert.equal(foreground(),mainBefore,'Agent display start changed display 0 focus');
      evidence.desktopFlags=desktopStart;
    }
    // The engine seeds its activity guard from PowerManager's last physical activity.
    // There is deliberately no connection-start sleep here.
    awake();
    let s=ok(guard(await client.call('get_app_state',{app:pkg})));fixtureFront();
    if (desktop) {
      await delay(1500);
      s=ok(guard(await client.call('get_app_state',{app:pkg})));
    }
    const checks=[];evidence.runs.push({run,checks});
    if(run===1){
      checks.push({name:'fresh_connection_open',pass:true,foreground:foreground(),elapsedMs:0});
      evidence.transcript={initialize:{request:{method:'initialize',params:{protocolVersion:'2024-11-05',capabilities:{},clientInfo:{name:'opencu-android-fixture-verifier',version:'1'}}},response:init},toolsList:{request:{method:'tools/list'},toolNames:tools.map(t=>t.name),pages:2},getAppState:{request:'tools/call get_app_state',response:s}};
    }
    await check('form_ascii_unicode_checkbox',async()=>{
      assert.ok(Buffer.byteLength(text(s))<4096,'Fixture form exceeds text budget');
      s=ok(await call('set_value',{element_index:index(s,'id=ascii '),value:`ASCII run ${run}`}));
      s=ok(await call('set_value',{element_index:index(s,'id=chinese '),value:'无线调试 测试'}));
      if(!text(s).split('\n').some(line=>line.includes('id=checkbox ')&&line.includes(' checked')))s=await click(s,'checkbox');
      const t=truth();assert.equal(t.ascii,`ASCII run ${run}`);assert.equal(t.chinese,'无线调试 测试');assert.equal(t.checked,true);return {truth:t,stateBytes:Buffer.byteLength(text(s))};
    },checks);
    await check('batch_fill_load_until_without_extra_read',async()=>{
      const before=client.next;
      s=ok(await call('run_actions',{actions:[{method:'set_value',element_index:index(s,'id=ascii '),value:`batch ${run}`},{method:'set_value',element_index:index(s,'id=chinese '),value:'无线调试 测试'},{method:'click',element_index:index(s,'id=load '),until:{text:'Fixture result ready',gone:'Loading fixture data'}}]}));
      assert.equal(client.next-before,1);assert.match(text(s),/Fixture result ready/);assert.doesNotMatch(text(s),/Loading fixture data/);const t=truth();assert.equal(t.ascii,`batch ${run}`);assert.equal(t.chinese,'无线调试 测试');assert.equal(t.loading,false);return {truth:t,batch:s._meta['opencu/batch'],mcpCalls:1};
    },checks);
    await check('popup_stops_before_next_step',async()=>{
      const before=truth().ascii;
      const r=await call('run_actions',{actions:[{method:'click',element_index:index(s,'id=dialog ')},{method:'set_value',element_index:index(s,'id=ascii '),value:'MUST NOT EXECUTE'}]});
      assert.equal(r._meta['opencu/batch'].reason,'popup');assert.equal(r._meta['opencu/batch'].stoppedStep,1);assert.equal(truth().ascii,before);assert.equal(truth().dialogOpen,true);
      s=ok(await call('click',{element_index:index(r,'id=button2 ')}));assert.equal(truth().dialogChoice,'cancel');return {batch:r._meta['opencu/batch'],truth:truth()};
    },checks);
    await check('stale_element_sends_nothing',async()=>{
      s=await click(s,'move');const stale=index(s,'id=checkbox '),before=truth().checked;await delay(750);
      const r=await call('click',{element_index:stale});assert.equal(r._meta['opencu/error'],'STALE_ELEMENT');assert.equal(truth().checked,before);assert.equal(truth().checkboxHidden,true);s=await read();return {error:r._meta['opencu/error'],truth:truth()};
    },checks);
    await check('scroll_list_to_row_150',async()=>{
      s=await click(s,'list');let scrolls=0;
      while(!text(s).includes('text="Fixture row 150"')){assert.ok(scrolls++<30,'row 150 not reached');s=ok(await call('scroll',{element_index:index(s,'id=rows '),direction:'down',pages:1}));}
      s=ok(await call('click',{element_index:index(s,'text="Fixture row 150"')}));assert.equal(truth().row,150);const t=truth();s=await click(s,'form');return {scrolls,truth:t};
    },checks);
    await check('second_activity_back',async()=>{
      s=await click(s,'second');assert.equal(truth().screen,'second');assert.match(text(s),/SecondActivity/);s=ok(await call('press_key',{key:'back'}));assert.equal(truth().screen,'form');return {truth:truth()};
    },checks);
    await check('until_timeout_deadline',async()=>{
      const timeoutMs=350,start=performance.now();const r=await call('run_actions',{actions:[{method:'wait',ms:1,until:{text:'NEVER appears in fixture',timeoutMs}},{method:'set_value',element_index:index(s,'id=ascii '),value:'MUST NOT EXECUTE'}]});
      const elapsedMs=performance.now()-start;assert.equal(r._meta['opencu/batch'].reason,'timeout');assert.ok(elapsedMs<=timeoutMs+1000,`timeout took ${elapsedMs} ms`);assert.notEqual(truth().ascii,'MUST NOT EXECUTE');s=r;return {elapsedMs,timeoutMs,batch:r._meta['opencu/batch']};
    },checks);
    await check('injected_keys_do_not_latch_stop',async()=>{
      // Fixture directs hardware volume keys to STREAM_MUSIC. Read and restore precisely that stream.
      const volumeOutput=shell('cmd media_session volume --stream 3 --get');
      const initial=Number(volumeOutput.match(/volume is (\d+)/i)?.[1]);assert.ok(Number.isInteger(initial),'Cannot establish original volume; no volume key sent');
      try{fixtureFront();shell('input keyevent 25 25 25');await delay(3200);fixtureFront();s=ok(await call('click',{element_index:index(s,'id=checkbox ')}));assert.notEqual(s._meta?.['opencu/error'],'USER_STOPPED');assert.equal(client.notifications.filter(n=>n.params?.data?.event==='stop').length,0);}
      finally{
        const volume=()=>Number(shell('cmd media_session volume --stream 3 --get').match(/volume is (\d+)/i)?.[1]);
        // ColorOS accepts the media_session set command without applying it. Restore through
        // the same key route, with the fixture's explicit STREAM_MUSIC routing still active.
        let current=volume();assert.ok(current<=initial&&current>=Math.max(0,initial-3),'Unexpected volume change; stop and ask the owner');
        while(current<initial){fixtureFront();shell('input keyevent 24');await delay(150);const next=volume();assert.equal(next,current+1,'Volume-up restoration did not advance exactly one level');current=next;}
        assert.equal(current,initial,'Volume must be restored');
      }
      return {injectedVolumeDown:3,volumeRestored:true,stopNotifications:0};
    },checks);
    await check('stdin_eof_no_engine_leftover',async()=>{
      const own=enginePids().filter(p=>!originalPids.includes(p));assert.equal(own.length,1,'Expected one engine process');
      const end=await client.close();client=null;assert.ok(end.elapsedMs<=2000);const left=enginePids();assert.ok(own.every(pid=>!left.includes(pid)));return {...end,leftoverEngineProcesses:0};
    },checks);
  }
  if (desktop) {
    evidence.desktopLifecycle=[];
    for (let cycle=1; cycle<=3; cycle++) {
      const stopClient=connect();
      await stopClient.initialize();
      const before=foreground();
      await ok(await stopClient.call('agent_desktop',{action:'start'}));
      assert.equal(foreground(),before);
      await ok(await stopClient.call('agent_desktop',{action:'stop'}));
      assert.equal(foreground(),before);
      evidence.desktopLifecycle.push({cycle,stop:true,mainForeground:before});
      await stopClient.close();
      idleMode=true;
      const idleClient=connect();
      await idleClient.initialize();
      await ok(await idleClient.call('agent_desktop',{action:'start'}));
      await delay((idleMs||1000)+250);
      const idleResult=guard(await idleClient.call('list_apps'));
      assert.equal(idleResult._meta?.['opencu/error'],'AGENT_DESKTOP_IDLE_STOPPED');
      assert.equal(foreground(),before);
      evidence.desktopLifecycle[evidence.desktopLifecycle.length-1].idleStopped=true;
      await idleClient.close();
      idleMode=false;
    }
  }
  if (desktop) await delay(1000);
  // Each metric has ten independent samples; startup includes launcher, cache hash, adb, initialize and first tools/list page.
  if (!desktop) {
  const startSamples=[],reads=[],clicks=[],screenshots=[];
  for(let i=0;i<10;i++){
    fixtureFront();client=connect();await client.initialize();await client.request('tools/list');startSamples.push(performance.now()-client.started);
    fixtureFront();let start=performance.now();let s=ok(guard(await client.call('get_app_state',{app:pkg})));reads.push(performance.now()-start);
    fixtureFront();start=performance.now();s=ok(guard(await client.call('click',{app:pkg,element_index:index(s,'id=checkbox ')})));clicks.push(performance.now()-start);
    fixtureFront();start=performance.now();s=ok(guard(await client.call('get_app_state',{app:pkg,includeScreenshot:true})));screenshots.push(performance.now()-start);
    const image=s.content.find(c=>c.type==='image');assert.equal(image.mimeType,'image/jpeg');assert.ok(Math.max(s._meta['opencu/screenshot'].width,s._meta['opencu/screenshot'].height)<=1280);
    await client.close();client=null;
  }
  const median=values=>{const a=[...values].sort((a,b)=>a-b);const m=Math.floor(a.length/2);return a.length%2?a[m]:(a[m-1]+a[m])/2;};
  for(const [name,samples,targetMs]of[['startToFirstToolsList',startSamples,null],['textRead',reads,300],['indexedClickWithState',clicks,800],['screenshotRead',screenshots,800]])evidence.timings[name]={samplesMs:samples,medianMs:median(samples),targetMs,meetsTarget:targetMs===null?null:median(samples)<=targetMs};
  const batchStepSamples=[];
  for(let i=0;i<10;i++){
    fixtureFront();client=connect();await client.initialize();let state=ok(await client.call('get_app_state',{app:pkg}));
    const actions=Array.from({length:10},()=>({method:'click',element_index:index(state,'id=checkbox ')}));
    const started=performance.now();const batch=ok(await client.call('run_actions',{app:pkg,actions}));
    batchStepSamples.push((performance.now()-started)/10);assert.equal(batch._meta['opencu/batch'].completed,10);await client.close();client=null;
  }
  evidence.timings.batchPlainClickStep={samplesMs:batchStepSamples,medianMs:median(batchStepSamples),targetMs:250,meetsTarget:median(batchStepSamples)<=250};
  evidence.settleBudgetMs={waitForIdle:{idleTimeoutMs:30,globalTimeoutMs:180},initialRead:{deadlineMs:700,unchangedWindowMs:150},normalRead:{deadlineMs:300,unchangedWindowMs:50},actionRead:{deadlineMs:450,unchangedWindowMs:50}};
  const formSizes=evidence.runs.flatMap(run=>run.checks.filter(check=>check.name==='form_ascii_unicode_checkbox').map(check=>check.stateBytes));
  evidence.stateSize={fixtureFormBytesAfter:formSizes,fixtureFormBytesBeforeLeanFilter:1213,medianAfter:formSizes.length?median(formSizes):null,deltaBytes:formSizes.length?median(formSizes)-1213:null};
  }
  evidence.pass=true;
}catch(error){evidence.pass=false;evidence.failure=error.message.split("\n")[0];mkdirSync(path.join(root,".cache/android"),{recursive:true});writeFileSync(path.join(root,".cache/android/verify-failure.log"),error.stack+"\n");console.error(error.stack);process.exitCode=1;}
finally{
  if(client){try{if(client.stopped)personStopped=true;await client.close();client=null;}catch(e){evidence.cleanup.eofError=e.message;process.exitCode=1;}}
  if(installed&&!personStopped&&foreground()===pkg){
    let cleanup;
    try{awake();cleanup=connect();await cleanup.initialize();ok(guard(await cleanup.call('get_app_state',{app:pkg})));ok(guard(await cleanup.call('press_key',{app:pkg,key:'home'})));evidence.cleanup.homeSent=true;}
    catch(e){evidence.cleanup.homeError=e.message;process.exitCode=1;}
    finally{if(cleanup)try{await cleanup.close();}catch(e){evidence.cleanup.eofError=e.message;process.exitCode=1;}}
  }
  if(installed&&!keep&&!personStopped){try{device('uninstall',pkg);evidence.cleanup.fixtureUninstalled=true;}catch(e){evidence.cleanup.fixtureUninstalled=false;evidence.cleanup.error=e.message;process.exitCode=1;}}
  else evidence.cleanup.fixtureKept=installed;
  // Remove only jars produced by this source worktree's Android launcher, retaining the current content hash.
  // This run does not enumerate/read app data or operate the launcher or notification shade.
  evidence.cleanup.personStopObserved=personStopped;
  evidence.cleanup.foreground=foreground();
  evidence.cleanup.leftoverEngineProcesses=enginePids().filter(p=>!originalPids.includes(p)).length;
  if(evidence.cleanup.leftoverEngineProcesses)process.exitCode=1;
  if(process.exitCode)evidence.pass=false;
  const date=new Date().toISOString().slice(0,10);mkdirSync(path.join(root,'evidence'),{recursive:true});
  const output=path.join(root,`evidence/opencu-android-${date}.json`);writeFileSync(output,JSON.stringify(evidence,null,2)+'\n');console.log(`Evidence: ${output}`);
}
