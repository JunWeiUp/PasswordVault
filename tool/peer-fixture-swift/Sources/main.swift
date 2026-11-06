import Foundation
import CommonRelay
// A fixed, public synthetic fixture key. Never opens a user vault or Keychain.
while let line=readLine() {
 do {
  let request=try JSONSerialization.jsonObject(with:Data(line.utf8)) as! [String:Any]
  let identity=try RelayIdentity(app:"passwordvault",group:"fixture-group",device:"native",secretKey:Data(repeating:1,count:32),trustedPeers:[request["peer"] as! String:Data(relayHex:request["publicKey"] as! String)])
  let result:[String:Any]
  if request["op"] as? String == "seal" {
   result=["body":try identity.seal(to:request["peer"] as! String,kind:"message",id:request["id"] as! String,value:request["value"] as! [String:Any])]
  } else {
   result=try identity.open(from:request["peer"] as! String,kind:"message",id:request["id"] as! String,body:request["body"] as! String)
  }
  print(String(decoding:try JSONSerialization.data(withJSONObject:["ok":result],options:[.sortedKeys]),as:UTF8.self))
 }catch{print("{\"error\":\"fixture cryptographic validation failed\"}")}
 fflush(stdout)
}
