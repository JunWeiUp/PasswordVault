import test from "node:test";
import assert from "node:assert/strict";
import {groupSecurityFindings,SECURITY_GROUP_ORDER} from "../test-build/security-groups.js";
test("security findings are grouped by issue with counts that skip ignored findings",()=>{
 const findings=[
  {key:"a",kind:"passwordHealth",id:"1",weak:true,reused:true},
  {key:"b",kind:"passwordHealth",id:"2",expired:true,ignored:true},
  {key:"c",kind:"twoFactorAvailable",id:"3"},
  {key:"d",kind:"passkeyAvailable",id:"4"},
  {key:"e",kind:"siteIncident",id:"5"},
  {key:"f",kind:"duplicateEntry",id:"6"},
 ];
 const groups=groupSecurityFindings(findings,[{id:"7",title:"Bank"}]);
 assert.deepEqual(groups.map(g=>g.key),["weak","reused","breach","expired","twoFactor","passkey","other"]);
 const by=Object.fromEntries(groups.map(g=>[g.key,g]));
 assert.equal(by.weak.count,1);assert.equal(by.reused.findings[0],findings[0]);
 assert.equal(by.expired.count,0);assert.equal(by.expired.findings.length,1);
 assert.equal(by.breach.findings[0].title,"Bank");assert.equal(by.breach.count,1);
 assert.equal(by.other.count,2);
 assert.deepEqual(groupSecurityFindings([]),[]);
 assert.equal(SECURITY_GROUP_ORDER.length,7);
});
