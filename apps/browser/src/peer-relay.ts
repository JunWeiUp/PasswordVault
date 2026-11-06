import { command } from './client';
type Config={device:string;publicKey:string;group:string;gateway:string;endpoint:string;token:string;pending:any};
const base64=(data:Uint8Array)=>{let s='';for(let i=0;i<data.length;i+=8192)s+=String.fromCharCode(...data.subarray(i,i+8192));return btoa(s);};
const unbase64=(s:string)=>Uint8Array.from(atob(s),c=>c.charCodeAt(0));
export class PeerRelay {
 private socket?:WebSocket;private timer?:ReturnType<typeof setInterval>;private serial:Promise<unknown>=Promise.resolve();private sent=new Map<string,string>();private epoch=0;private running=false;
 private listeners=new Set<(status:string)=>void>();private refresh?:()=>Promise<void>;
 subscribe(listener:(status:string)=>void){this.listeners.add(listener);return()=>{this.listeners.delete(listener);};}
 private status(message:string){for(const listener of this.listeners)listener(message);}
 stop(){this.epoch++;this.running=false;if(this.timer)clearInterval(this.timer);this.timer=undefined;this.socket?.close();this.socket=undefined;this.sent.clear();this.status('同步已停止 / Sync stopped');}
 async start(refresh?:()=>Promise<void>){
  if(this.running){if(refresh)this.refresh=refresh;return;}this.stop();this.running=true;this.refresh=refresh;const epoch=this.epoch;
  try{
   const config:Config=await command({op:'peer-transport-status'});if(!config.gateway||!config.token)throw new Error('Configure the dedicated gateway and device relay credential first');
   const socket=new WebSocket(config.gateway,'passwordvault.gateway.v1');this.socket=socket;
   socket.onopen=()=>{if(epoch!==this.epoch){socket.close();return;}socket.send(JSON.stringify({type:'authenticate',token:config.token}));config.token='';};
   let welcomed=false;const welcomeTimer=setTimeout(()=>{if(epoch===this.epoch&&!welcomed){this.stop();this.status('中继握手超时 / Relay handshake timed out');}},10000);
   socket.onmessage=event=>{this.serial=this.serial.then(async()=>{
    if(epoch!==this.epoch||typeof event.data!=='string')return;
    const frame=JSON.parse(event.data);
    if(!welcomed){if(frame.version!==1||frame.identity?.app!=='passwordvault'||frame.identity?.group!==config.group||frame.identity?.device!==config.device||frame.identity?.public_key!==config.publicKey)throw new Error('Relay identity mismatch');welcomed=true;clearTimeout(welcomeTimer);this.status('已连接；本地保存与远端应用分别确认 / Connected; local save is distinct from remote application');await this.synchronize(config,epoch);this.timer=setInterval(()=>{this.serial=this.serial.then(()=>this.synchronize(config,epoch)).catch(()=>this.stop());},5000);return;}
    if(frame.type==='message')await this.receive(frame,config,epoch);
    else if(frame.type==='peer.up')this.sent.clear();
    else if(frame.type==='error')throw new Error('Relay rejected a frame');
   }).catch(()=>{this.stop();this.status('同步未完成，本地数据已保留 / Sync incomplete; local data retained');});};
   socket.onerror=()=>{if(epoch===this.epoch)this.status('网络中断，等待重连 / Network interrupted; waiting to reconnect');};socket.onclose=()=>{clearTimeout(welcomeTimer);if(epoch===this.epoch){const refresh=this.refresh;this.stop();this.status('网络中断，等待重连 / Network interrupted; waiting to reconnect');this.timer=setTimeout(()=>{void this.start(refresh).catch(()=>this.stop());},5000);}};
  }catch(error){this.stop();throw error;}
 }
 private async synchronize(config:Config,epoch:number){
  if(epoch!==this.epoch||this.socket?.readyState!==WebSocket.OPEN)return;
  const listing=await command({op:'relay-peer-list'});
  for(const descriptor of listing.libraries){if(String(descriptor.id).startsWith('pending-'))continue;const state=await command({op:'relay-peer-status',library:descriptor.id});if(state.frozen||!state.members?.[config.device])continue;
   for(const [peer,member]of Object.entries<any>(state.members)){if(peer===config.device||!member.transportKey)continue;
    const envelope=await command({op:'relay-peer-export',library:descriptor.id,peer});const data=new TextEncoder().encode(JSON.stringify(envelope));
    if(data.length>48*1024*1024)throw new Error('Peer payload exceeds transfer limit');
    const digest=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',data)),b=>b.toString(16).padStart(2,'0')).join('');const route=descriptor.id+':'+peer;const signature=digest+':'+Math.floor(Date.now()/3_600_000);if(this.sent.get(route)===signature)continue;
    const count=Math.ceil(data.length/65536);const chunks=data.length<=128*1024?[data]:Array.from({length:count},(_,index)=>new TextEncoder().encode(JSON.stringify({protocol:'peer-v2-chunk',library:descriptor.id,transfer:digest.slice(0,32),index,count,total:data.length,digest,data:base64(data.subarray(index*65536,(index+1)*65536))})));
    for(const chunk of chunks){const id=crypto.randomUUID().replaceAll('-','');const expires=Math.floor(Date.now()/1000)+7*86400;
      const sealed=await command({op:'peer-transport-seal',peer,publicKey:member.transportKey,id,value:{data:base64(chunk),expires}});
      if(epoch!==this.epoch)return;this.socket!.send(JSON.stringify({type:'message',id,to:peer,body:sealed.body,offline:true,expires}));
      await new Promise(resolve=>setTimeout(resolve,25));
      while(this.socket!.bufferedAmount>512*1024){await new Promise(resolve=>setTimeout(resolve,25));if(epoch!==this.epoch)return;}
    }this.sent.set(route,signature);
   }
  }
 }
 private async receive(frame:any,config:Config,epoch:number){
  const current:Config=await command({op:'peer-transport-status'});const listing=await command({op:'relay-peer-list'});let key='';
  for(const descriptor of listing.libraries){if(String(descriptor.id).startsWith('pending-'))continue;const state=await command({op:'relay-peer-status',library:descriptor.id});if(!state.frozen&&state.members?.[frame.from]?.transportKey)key=state.members[frame.from].transportKey;}
  if(current.pending?.device===frame.from)key=current.pending.transportKey;if(!key)throw new Error('Sender has no library authorization');
  const opened=await command({op:'peer-transport-open',peer:frame.from,publicKey:key,id:frame.id,body:frame.body});if(opened.expires&&opened.expires<=Date.now()/1000){this.socket?.send(JSON.stringify({type:'ack',id:frame.id,from:frame.from}));return;}
  const envelope=JSON.parse(new TextDecoder().decode(unbase64(opened.data)));const library=envelope.packet?.library??envelope.library;
  if(current.pending?.library!==library&&!listing.libraries.some((l:any)=>l.id===library)){this.socket?.send(JSON.stringify({type:'ack',id:frame.id,from:frame.from}));return;}
  if(current.pending?.library===library){const result=await command({op:'relay-peer-join',library:current.pending.localLibrary,expectedLibrary:library,founderKey:current.pending.founderKey,envelope,sender:frame.from});if(!result.partial)await command({op:'peer-transport-pending',value:null});}
  else{const state=await command({op:'relay-peer-status',library});if(state.frozen){this.socket?.send(JSON.stringify({type:'ack',id:frame.id,from:frame.from}));return;}if(state.members?.[frame.from]?.transportKey!==key)throw new Error('Library sender key mismatch');const result=await command({op:'relay-peer-receive',library,envelope,sender:frame.from});if(result.frozen)throw new Error('Permission conflict');}
  // The command resolves only after IndexedDB's encrypted transaction commits.
  if(epoch!==this.epoch)return;this.socket?.send(JSON.stringify({type:'ack',id:frame.id,from:frame.from}));await this.refresh?.();
 }
}
export const peerRelay=new PeerRelay();
