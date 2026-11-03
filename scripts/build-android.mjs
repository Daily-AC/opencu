#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync, readdirSync, existsSync, rmSync } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { buildTools as bt, androidJar as android, lambdaStubs, javacAndroidArgs as javacAndroid } from './android-toolchain.mjs';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const java=process.env.JAVA_HOME??'/opt/homebrew/opt/openjdk@21';
const build=path.join(root,'.build/android');mkdirSync(build,{recursive:true});
function run(exe,args){const r=spawnSync(exe,args,{cwd:root,stdio:'inherit',env:{...process.env,JAVA_HOME:java}});if(r.error)throw r.error;if(r.status!==0)throw new Error(`${exe} exited ${r.status}`);}
function sources(dir){return readdirSync(dir,{recursive:true}).filter(x=>x.endsWith('.java')).map(x=>path.join(dir,x));}
for(const file of [android,lambdaStubs,path.join(bt,'d8'),path.join(bt,'aapt2'),path.join(java,'bin/javac')])if(!existsSync(file))throw new Error(`Missing ${file}; install the documented Android SDK/JDK toolchain`);
for(const dir of ['engine-classes','engine-dex','fixture-classes','fixture-dex','companion-classes','companion-dex','generated']){rmSync(path.join(build,dir),{recursive:true,force:true});mkdirSync(path.join(build,dir),{recursive:true});}
const version=JSON.parse(readFileSync(path.join(root,'package.json'),'utf8')).version;
// The companion app's signing key stays on this machine, outside the checkout, so rebuilding or
// cleaning keeps it; the engine pins its certificate and attaches no app signed otherwise.
const companionKey=path.join(os.homedir(),'.local/share/opencu/android-companion.keystore');
const companionPass='opencu-companion';
if(!existsSync(companionKey)){
  mkdirSync(path.dirname(companionKey),{recursive:true});
  run(path.join(java,'bin/keytool'),['-genkeypair','-keystore',companionKey,'-storepass',companionPass,'-keypass',companionPass,'-alias','companion','-dname','CN=OpenCU Companion','-keyalg','RSA','-keysize','3072','-validity','10000']);
  spawnSync('chmod',['600',companionKey]);
}
const exported=spawnSync(path.join(java,'bin/keytool'),['-exportcert','-keystore',companionKey,'-storepass',companionPass,'-alias','companion']);
if(exported.status!==0)throw new Error(`keytool -exportcert failed: ${exported.stderr}`);
const companionCert=createHash('sha256').update(exported.stdout).digest('hex');
writeFileSync(path.join(build,'generated/BuildInfo.java'),`package dev.opencu.android; public final class BuildInfo { public static final String VERSION = ${JSON.stringify(version)}; public static final String COMPANION_CERT = ${JSON.stringify(companionCert)}; }\n`);
run(path.join(java,'bin/javac'),[...javacAndroid,'-d',path.join(build,'engine-classes'),...sources(path.join(root,'native-android/src')),path.join(build,'generated/BuildInfo.java')]);
run(path.join(java,'bin/jar'),['--create','--file',path.join(build,'engine-classes.jar'),'-C',path.join(build,'engine-classes'),'.']);
run(path.join(bt,'d8'),['--lib',android,'--min-api','34','--output',path.join(build,'engine-dex'),path.join(build,'engine-classes.jar')]);
run(path.join(java,'bin/jar'),['--create','--file',path.join(build,'opencu-android.jar'),'-C',path.join(build,'engine-dex'),'.']);
const fixture=path.join(root,'native-android/fixture');
run(path.join(bt,'aapt2'),['compile','--dir',path.join(fixture,'res'),'-o',path.join(build,'fixture-res.zip')]);
run(path.join(bt,'aapt2'),['link','-o',path.join(build,'fixture-unsigned.apk'),'--manifest',path.join(fixture,'AndroidManifest.xml'),'-I',android,'--java',path.join(build,'generated'),'--min-sdk-version','34','--target-sdk-version','34',path.join(build,'fixture-res.zip')]);
run(path.join(java,'bin/javac'),[...javacAndroid,'-d',path.join(build,'fixture-classes'),...sources(path.join(fixture,'src')),...sources(path.join(build,'generated')).filter(x=>!x.endsWith('BuildInfo.java'))]);
run(path.join(java,'bin/jar'),['--create','--file',path.join(build,'fixture-classes.jar'),'-C',path.join(build,'fixture-classes'),'.']);
run(path.join(bt,'d8'),['--lib',android,'--min-api','34','--output',path.join(build,'fixture-dex'),path.join(build,'fixture-classes.jar')]);
run(path.join(java,'bin/jar'),['--update','--file',path.join(build,'fixture-unsigned.apk'),'-C',path.join(build,'fixture-dex'),'classes.dex']);
run(path.join(bt,'zipalign'),['-f','4',path.join(build,'fixture-unsigned.apk'),path.join(build,'fixture-aligned.apk')]);
const key=path.join(build,'fixture-debug.keystore');
if(!existsSync(key))run(path.join(java,'bin/keytool'),['-genkeypair','-keystore',key,'-storepass','android','-keypass','android','-alias','fixture','-dname','CN=OpenCU Disposable Fixture','-keyalg','RSA','-validity','3650']);
run(path.join(bt,'apksigner'),['sign','--ks',key,'--ks-key-alias','fixture','--ks-pass','pass:android','--key-pass','pass:android','--out',path.join(build,'opencu-fixture.apk'),path.join(build,'fixture-aligned.apk')]);
const companion=path.join(root,'native-android/companion');
run(path.join(bt,'aapt2'),['compile','--dir',path.join(companion,'res'),'-o',path.join(build,'companion-res.zip')]);
run(path.join(bt,'aapt2'),['link','-o',path.join(build,'companion-unsigned.apk'),'--manifest',path.join(companion,'AndroidManifest.xml'),'-I',android,'--min-sdk-version','34','--target-sdk-version','34','--version-name',version,path.join(build,'companion-res.zip')]);
run(path.join(java,'bin/javac'),[...javacAndroid,'-d',path.join(build,'companion-classes'),...sources(path.join(companion,'src'))]);
run(path.join(java,'bin/jar'),['--create','--file',path.join(build,'companion-classes.jar'),'-C',path.join(build,'companion-classes'),'.']);
run(path.join(bt,'d8'),['--lib',android,'--min-api','34','--release','--output',path.join(build,'companion-dex'),path.join(build,'companion-classes.jar')]);
run(path.join(java,'bin/jar'),['--update','--file',path.join(build,'companion-unsigned.apk'),'-C',path.join(build,'companion-dex'),'classes.dex']);
run(path.join(bt,'zipalign'),['-f','4',path.join(build,'companion-unsigned.apk'),path.join(build,'companion-aligned.apk')]);
run(path.join(bt,'apksigner'),['sign','--ks',companionKey,'--ks-key-alias','companion','--ks-pass',`pass:${companionPass}`,'--key-pass',`pass:${companionPass}`,'--out',path.join(build,'opencu-companion.apk'),path.join(build,'companion-aligned.apk')]);
console.log(`Built .build/android/opencu-android.jar, opencu-fixture.apk and opencu-companion.apk (API 34+; companion certificate ${companionCert.slice(0,16)}…)`);
