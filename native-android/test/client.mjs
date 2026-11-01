import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { performance } from 'node:perf_hooks';
export class Client {
  constructor(root,serial) {
    this.started=performance.now();this.next=1;this.pending=new Map();this.stderr='';this.notifications=[];this.stopped=false;
    this.process=spawn(`${root}/bin/opencu`,['android',...(serial?['--serial',serial]:[])],{cwd:root,stdio:['pipe','pipe','pipe']});
    this.lines=createInterface({input:this.process.stdout});
    this.process.stderr.on('data',b=>{this.stderr+=b.toString();});
    this.lines.on('line',line=>{try{const r=JSON.parse(line);if(r.method){this.notifications.push(r);if(r.params?.data?.error?.code==='USER_STOPPED'){this.stopped=true;this.onStop?.();}return;}const p=this.pending.get(r.id);if(!p)throw new Error(`Unexpected response: ${line}`);this.pending.delete(r.id);clearTimeout(p.timer);if(r.error)p.reject(new Error(JSON.stringify(r.error)));else p.resolve(r.result);}catch(e){this.fail(e);}});
    this.closed=new Promise(resolve=>this.process.on('close',(code,signal)=>{this.fail(new Error(`Engine exited ${code??signal}: ${this.stderr}`));resolve({code,signal});}));
    this.process.on('error',e=>this.fail(e));
  }
  fail(e){for(const p of this.pending.values()){clearTimeout(p.timer);p.reject(e);}this.pending.clear();}
  request(method,params={}) {const id=this.next++;return new Promise((resolve,reject)=>{const timer=setTimeout(()=>{this.pending.delete(id);reject(new Error(`Timeout: ${method}; ${this.stderr}`));},35000);this.pending.set(id,{resolve,reject,timer});this.process.stdin.write(`${JSON.stringify({jsonrpc:'2.0',id,method,params})}\n`);});}
  notify(method,params={}){this.process.stdin.write(`${JSON.stringify({jsonrpc:'2.0',method,params})}\n`);}
  async initialize(){this.init=await this.request('initialize',{protocolVersion:'2024-11-05',capabilities:{},clientInfo:{name:'opencu-android-fixture-verifier',version:'1'}});this.notify('notifications/initialized');return this.init;}
  async tools(){let cursor,result=[];do{const page=await this.request('tools/list',cursor?{cursor}:{});result.push(...page.tools);cursor=page.nextCursor;}while(cursor);return result;}
  call(name,args={}){return this.request('tools/call',{name,arguments:args});}
  async close(){const start=performance.now();this.process.stdin.end();const value=await Promise.race([this.closed,new Promise((_,reject)=>{const timer=setTimeout(()=>reject(new Error('EOF did not close engine within 2 seconds')),2000);timer.unref();})]);return {elapsedMs:performance.now()-start,...value};}
}
export const text=result=>result.content.filter(c=>c.type==='text').map(c=>c.text).join('\n');
export function index(result,match){const line=text(result).split('\n').find(l=>/^\[\d+\]/.test(l)&&(typeof match==='string'?l.includes(match):match.test(l)));if(!line)throw new Error(`Missing element ${match}\n${text(result)}`);return Number(line.match(/^\[(\d+)\]/)[1]);}
export function ok(result){if(result.isError)throw new Error(text(result));return result;}
