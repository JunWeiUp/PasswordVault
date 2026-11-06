import XCTest
@testable import CommonRelay
final class InvitationLinksTests: XCTestCase {
 func testSharedPacketAndTampering() throws {
  let file=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("protocol/invitation-link-vectors.json")
  let v=try dictionary(Data(contentsOf:file)),key=try Data(relayHex:v["key"] as! String),packet=v["packet"] as! String,link=v["link"] as! String
  let inv=try RelayInvitationLinks.open(packet,key:key)
  XCTAssertTrue(NSDictionary(dictionary:inv).isEqual(to:v["invitation"] as! [String:Any]));XCTAssertEqual(try RelayInvitationLinks.readToken(key),v["read_token"] as? String)
  XCTAssertEqual(try RelayInvitationLinks.make(inv,key:key),link);XCTAssertEqual(try RelayInvitationLinks.parse(link).url,inv["url"] as? String)
  let own=try RelayInvitationLinks.seal(inv,key:key,nonce:Data(relayHex:v["nonce"] as! String));XCTAssertTrue(NSDictionary(dictionary:try RelayInvitationLinks.open(own,key:key)).isEqual(to:inv))
  XCTAssertThrowsError(try RelayInvitationLinks.open(packet,key:Data(repeating:0,count:32)));XCTAssertThrowsError(try RelayInvitationLinks.parse(link+"="));XCTAssertThrowsError(try RelayInvitationLinks.parse(link.replacingOccurrences(of:"relay.example.com",with:"user@relay.example.com")))
 }
 func testAccessPasswordInFragment() throws {
  let file=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("protocol/invitation-link-vectors.json")
  let v=try dictionary(Data(contentsOf:file)),key=try Data(relayHex:v["key"] as! String),link=v["link"] as! String,withPassword=v["link_with_password"] as! String,password=v["access_password"] as! String
  let inv=try RelayInvitationLinks.open(v["packet"] as! String,key:key)
  XCTAssertEqual(try RelayInvitationLinks.make(inv,key:key,password:password),withPassword)
  let parsed=try RelayInvitationLinks.parse(withPassword);XCTAssertEqual(parsed.password,password);XCTAssertEqual(parsed.key,key);XCTAssertEqual(parsed.url,inv["url"] as? String)
  XCTAssertNil(try RelayInvitationLinks.parse(link).password)
  for suffix in v["invalid_link_suffixes"] as! [String] { XCTAssertThrowsError(try RelayInvitationLinks.parse(link+suffix),suffix) }
 }
}
