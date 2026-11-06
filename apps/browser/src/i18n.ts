import {useEffect,useState} from "preact/hooks";
import english from "./translations.en.json";
export type Language="zh"|"en";
export type Theme="light"|"dark"|"system";
const translations=english as Record<string,string>;
const chineseLabels:Record<string,string>={"cardholder": "持卡人", "number": "卡号", "expiryMonth": "到期月", "expiryYear": "到期年", "securityCode": "安全码", "brand": "卡组织", "firstName": "名", "lastName": "姓", "email": "邮箱", "phone": "电话", "address1": "地址", "address2": "地址补充", "city": "城市", "region": "省 / 州", "postalCode": "邮编", "country": "国家", "company": "公司"};
function preference(key:string){try{return localStorage.getItem(key)}catch{return null;}}
function savePreference(key:string,value:string){try{localStorage.setItem(key,value)}catch{/* UI preferences remain in memory. */}}
let language:Language=preference("pv-language")==="en"?"en":"zh";
let theme:Theme=["dark","light"].includes(preference("pv-theme")??"")?preference("pv-theme") as Theme:"system";
const listeners=new Set<()=>void>();
const media=matchMedia("(prefers-color-scheme: dark)");
function apply(){document.documentElement.lang=language==="en"?"en":"zh-CN";document.documentElement.dataset.theme=theme==="system"?(media.matches?"dark":"light"):theme;}
media.addEventListener("change",apply);apply();
export function setLocale(next:Language){language=next;savePreference("pv-language",next);apply();for(const listener of listeners)listener();}
export function setTheme(next:Theme){theme=next;savePreference("pv-theme",next);apply();for(const listener of listeners)listener();}
export function t(text:string):string {return language==="en"?(translations[text]??text):(chineseLabels[text]??text);}
export function useLocale(){const[,refresh]=useState(0);useEffect(()=>{const notify=()=>refresh(n=>n+1);listeners.add(notify);return()=>{listeners.delete(notify);};},[]);return {language,theme,setLocale,setTheme};}
