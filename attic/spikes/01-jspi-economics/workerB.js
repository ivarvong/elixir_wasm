import mod from "spikeB.wasm";
const parked = new Map(), mailbox = new Map();
let killed = [], raised = [];
function recvImpl(pid){ const q=mailbox.get(pid); if(q&&q.length) return q.shift(); return new Promise((res,rej)=>parked.set(pid,{res,rej})); }
function deliver(pid,msg){ const p=parked.get(pid); if(p){parked.delete(pid); p.res(msg);} else {let q=mailbox.get(pid); if(!q){q=[];mailbox.set(pid,q);} q.push(msg);} }
function kill(pid,reason){ const p=parked.get(pid); if(p){parked.delete(pid); p.rej(reason);} }
const recv=new WebAssembly.Suspending(recvImpl);
const { exports } = new WebAssembly.Instance(mod,{ env:{ recv, note_kill:p=>killed.push(p), note_raise:p=>raised.push(p) }});
const spawn=WebAssembly.promising(exports.process_main);
export default { async fetch(req){
  const mode=new URL(req.url).searchParams.get("mode")||"kill";
  killed=[]; raised=[];
  let ret, detail;
  if(mode==="kill"){ const d=spawn(1,0); const wasParked=parked.has(1); kill(1,new Error("x")); ret=await d; detail={wasParked, cleanupRan:killed.includes(1)}; }
  else if(mode==="raise"){ const d=spawn(2,1); deliver(2,9); ret=await d; detail={raiseHandled:raised.includes(2), notKill:!killed.includes(2)}; }
  else { const d=spawn(3,0); deliver(3,1); deliver(3,2); deliver(3,-1); ret=await d; detail={}; }
  const ok = (mode==="kill"&&ret===-1&&detail.cleanupRan) || (mode==="raise"&&ret===-2&&detail.raiseHandled&&detail.notKill) || (mode==="normal"&&ret===2);
  return new Response(JSON.stringify({mode, ret, ...detail, ok}), {headers:{"content-type":"application/json"}});
}};
