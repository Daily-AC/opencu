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
const prefix=serial?['-s',serial]:[];
function run(args){const r=spawnSync(adb,[...prefix,...args],{encoding:'utf8',maxBuffer:4*1024*1024});if(r.error)throw r.error;if(r.status!==0)throw new Error(r.stderr.trim()||r.stdout.trim()||`adb exited ${r.status}`);return r.stdout;}
try{
  const jar=path.join(root,'.build/android/opencu-android.jar');
  if(!existsSync(jar))throw new Error('Android engine missing. Run npm run build:android.');
  const digest=createHash('sha256').update(readFileSync(jar)).digest('hex');
  const remote=`/data/local/tmp/opencu-android-${digest.slice(0,16)}.jar`;
  const found=run(['shell','-T',`if [ -f '${remote}' ]; then sha256sum '${remote}'; fi`]).trim().split(/\s/)[0];
  if(found!==digest){
    // Atomic content-addressed publication; a failed push never becomes the cached artifact.
    const temp=`${remote}.${process.pid}.tmp`;
    try {run(['push',jar,temp]);run(['shell','-T',`test "$(sha256sum '${temp}' | cut -d ' ' -f 1)" = '${digest}' && chmod 644 '${temp}' && mv '${temp}' '${remote}'`]);}
    finally{run(['shell','-T',`rm -f '${temp}'`]);}
  }
  const child=spawn(adb,[...prefix,'shell','-T',`CLASSPATH='${remote}' exec app_process / dev.opencu.android.Main ${mode}`],{stdio:['pipe','inherit','inherit']});
  process.stdin.pipe(child.stdin);
  child.stdin.on('error',e=>{if(e.code!=='EPIPE')console.error(e.message);});
  for(const signal of ['SIGINT','SIGTERM','SIGHUP'])process.on(signal,()=>{child.stdin.end();setTimeout(()=>child.kill(signal),1500).unref();});
  child.on('error',e=>{console.error(e.message);process.exitCode=1;});
  child.on('exit',(code,signal)=>{process.stdin.unpipe(child.stdin);process.stdin.pause();process.exit(code??(signal?1:0));});
}catch(e){console.error(`OpenCU Android: ${e.message}`);process.exit(1);}
