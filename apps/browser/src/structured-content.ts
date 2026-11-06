(() => {
  const context=window as typeof window & {__pvStructured?:boolean};
  if(context.__pvStructured || window!==top || location.protocol!=="https:")return;
  context.__pvStructured=true;
  type Input=HTMLInputElement|HTMLSelectElement;
  const accepted=new Set(["cc-name","cc-number","cc-exp-month","cc-exp-year","cc-csc","given-name","family-name","email","tel","address-line1","address-line2","address-level2","address-level1","postal-code","country","country-name","organization"]);
  const kind=(input:Input)=>input.autocomplete.toLowerCase().split(/\s+/).find(value=>accepted.has(value));
  const visible=(input:Input)=>{
    if(!input.isConnected||input.disabled||input.closest('[inert]')||(input instanceof HTMLInputElement&&input.readOnly)||!input.getClientRects().length)return false;
    for(let node:Element|null=input;node;node=node.parentElement){const style=getComputedStyle(node);if(style.visibility!=="visible"||style.display==="none"||Number(style.opacity)===0)return false;}
    return true;
  };
  let pending:{token:string;href:string;expires:number;fields:{input:Input;kind:string;form:HTMLFormElement|null;identity:string}[]}|undefined;
  const identity=(input:Input)=>[input.id,input.name,input.autocomplete,input.type].join("\0");
  chrome.runtime.onMessage.addListener((request,sender,respond)=>{
    if(sender.id!==chrome.runtime.id||request.origin!==location.origin)return;
    if(request.action==="structured-prepare"){
      let fields=Array.from(document.querySelectorAll<Input>('input,select')).filter(input=>kind(input)&&visible(input));
      const active=document.activeElement;
      const selectedForm=(active instanceof HTMLInputElement||active instanceof HTMLSelectElement)?active.form:null;
      if(selectedForm)fields=fields.filter(input=>input.form===selectedForm);
      if(new Set(fields.map(input=>input.form)).size>1 || new Set(fields.map(kind)).size!==fields.length || !fields.length){respond({ok:false});return;}
      const token=crypto.randomUUID();pending={token,href:location.href,expires:Date.now()+30000,fields:fields.map(input=>({input,kind:kind(input)!,form:input.form,identity:identity(input)}))};
      respond({ok:true,token});return;
    }
    if(request.action!=="structured-deliver")return;
    const target=pending;pending=undefined;
    const current=()=>target&&target.href===location.href&&target.expires>Date.now()&&!document.hidden&&target.fields.every(f=>visible(f.input)&&f.form===f.input.form&&f.identity===identity(f.input));
    if(!target||target.token!==request.token||!current()){respond({ok:false});return;}
    let filled=0;
    for(const field of target.fields){
      if(!current()){respond({ok:false});return;}
      const value=request.fields?.[field.kind];if(typeof value!=="string"||!value)continue;
      if(field.input instanceof HTMLSelectElement && !Array.from(field.input.options).some(o=>o.value===value))continue;
      const prototype=field.input instanceof HTMLSelectElement?HTMLSelectElement.prototype:HTMLInputElement.prototype;
      Object.getOwnPropertyDescriptor(prototype,"value")!.set!.call(field.input,value);
      field.input.dispatchEvent(new Event("input",{bubbles:true}));field.input.dispatchEvent(new Event("change",{bubbles:true}));filled++;
    }
    respond({ok:filled>0});
  });
  window.addEventListener("pagehide",()=>{pending=undefined;});
})();
