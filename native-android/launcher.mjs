#!/usr/bin/env node
// Adb shell v2, no PTY. Keep stdout exclusively for the remote MCP stream.
import { spawn, spawnSync } from 'node:child_process';
import { readFileSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import os from 'node:os';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const sdk=process.env.ANDROID_HOME??process.env.ANDROID_SDK_ROOT??path.join(os.homedir(),'Library/Android/sdk');
const adb=process.env.ADB??(existsSync(path.join(sdk,'platform-tools/adb'))?path.join(sdk,'platform-tools/adb'):'adb');
let serial=process.env.ANDROID_SERIAL,mode='mcp';
const args=process.argv.slice(2);
for(let i=0;i<args.length;i++){
  if(args[i]==='--serial'&&args[i+1])serial=args[++i];
  else if(args[i]==='doctor'&&mode==='mcp')mode='doctor';
  else {console.error('Usage: opencu android [--serial SERIAL] [doctor]');process.exit(2);}
}
let prefix=serial?['-s',serial]:[];
const firstLine=text=>String(text??'').trim().split('\n')[0].trim();
function run(args,timeout=30000){const r=spawnSync(adb,[...prefix,...args],{encoding:'utf8',maxBuffer:4*1024*1024,timeout});if(r.error)throw r.error;if(r.status!==0)throw new Error(r.stderr.trim()||r.stdout.trim()||`adb exited ${r.status}`);return r.stdout;}
/** What adb says about the phone's transport: "device" when it can be used, else why not. */
function deviceState(){
  const r=spawnSync(adb,[...prefix,'get-state'],{encoding:'utf8',timeout:5000});
  if(r.error)return r.error.code==='ETIMEDOUT'?'no answer from adb within 5 s':r.error.message;
  return r.status===0?r.stdout.trim():firstLine(r.stderr)||firstLine(r.stdout)||`adb exited ${r.status}`;
}
/** The coded line a host relays when the phone or its adb transport is gone. */
function unavailable(why,progress){
  return `DEVICE_UNAVAILABLE: adb cannot reach the phone${serial?` ${serial}`:''} (${why}); ${progress}`;
}
try{
  // Every adb call of this launch, the final exec included, goes to the same device.
  if(!serial){
    let named;
    try{named=run(['get-serialno']).trim();}catch(e){
      if(/more than one/i.test(e.message))throw new Error('adb did not name a single device; pass --serial');
      throw Object.assign(new Error(unavailable(firstLine(e.message),'the engine was not started and nothing was sent')),{coded:true});
    }
    if(!named||/\s/.test(named))throw new Error('adb did not name a single device; pass --serial');
    serial=named;prefix=['-s',serial];
  }
  const jar=path.join(root,'.build/android/opencu-android.jar');
  if(!existsSync(jar))throw new Error('Android engine missing. Run npm run build:android.');
  const digest=createHash('sha256').update(readFileSync(jar)).digest('hex');
  const remote=`/data/local/tmp/opencu-android-${digest.slice(0,16)}.jar`;
  try{
    const found=run(['shell','-T',`if [ -f '${remote}' ]; then sha256sum '${remote}'; fi`]).trim().split(/\s/)[0];
    if(found!==digest){
      // Atomic content-addressed publication; a failed push never becomes the cached artifact.
      const temp=`${remote}.${process.pid}.tmp`;
      try {run(['push',jar,temp],120000);run(['shell','-T',`test "$(sha256sum '${temp}' | cut -d ' ' -f 1)" = '${digest}' && chmod 644 '${temp}' && mv '${temp}' '${remote}'`]);}
      finally{run(['shell','-T',`rm -f '${temp}'`]);}
    }
  }catch(e){
    const state=deviceState();
    if(state!=='device')throw Object.assign(new Error(unavailable(state,'the engine was not started and nothing was sent')),{coded:true});
    throw e;
  }
  const idleEnv = process.env.OPENCU_ANDROID_IDLE_MS
    ? `OPENCU_ANDROID_IDLE_MS='${process.env.OPENCU_ANDROID_IDLE_MS.replace(/'/g, "'\\''")}' `
    : '';
  // Only shell and root can write /data/local/tmp, and the engine already runs as shell, so the
  // cache is trusted as far as shell is. Still refuse anything but a regular file owned by shell
  // with mode 0644 or stricter (no symlink, no group/other write, no special bits).
  const launch=`s=$(stat -c '%u %a %F' '${remote}' 2>/dev/null); case "$s" in "2000 "[46][04][04]" regular file") ${idleEnv}CLASSPATH='${remote}' exec app_process / dev.opencu.android.Main ${mode};; *) echo "UNSAFE_ENGINE_JAR: ${remote} is not a regular file owned by shell with mode 0644 or stricter ($s); remove it and launch again" >&2; exit 126;; esac`;
  const child=spawn(adb,[...prefix,'shell','-T',launch],{stdio:['pipe','inherit','inherit']});
  let stopping=false;
  process.stdin.pipe(child.stdin);
  child.stdin.on('error',e=>{if(e.code!=='EPIPE')console.error(e.message);});
  for(const signal of ['SIGINT','SIGTERM','SIGHUP'])process.on(signal,()=>{stopping=true;child.stdin.end();setTimeout(()=>child.kill(signal),1500).unref();});
  child.on('error',e=>{console.error(e.message);process.exitCode=1;});
  child.on('exit',(code,signal)=>{
    process.stdin.unpipe(child.stdin);process.stdin.pause();
    // An engine that failed prints its own coded line; an adb transport that went away does not.
    if(code!==0&&!stopping){
      const state=deviceState();
      if(state!=='device')console.error(unavailable(state,'the connection ended while the engine was running; a call in progress may or may not have reached the phone, so read state before any further input'));
    }
    process.exit(code??(signal?1:0));
  });
}catch(e){console.error(e.coded?e.message:`OpenCU Android: ${e.message}`);process.exit(1);}
