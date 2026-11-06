import XCTest

@testable import PasswordVault

final class WebDAVListingTests: XCTestCase {
  private let base = URL(string: "https://example.com/dav/backups/")!
  private func parse(_ xml: String) throws -> [RemoteBackup] {
    try WebDAVListing.parse(Data(xml.utf8), base: base)
  }

  func testMetadataStaysWithEachFileAndSortsByDate() throws {
    let files = try parse(
      """
      <d:multistatus xmlns:d="DAV:">
        <d:response><d:href>/dav/backups/old.json</d:href><d:propstat><d:prop>
          <d:getlastmodified>Tue, 02 Jan 2024 03:04:05 GMT</d:getlastmodified><d:getcontentlength>1024</d:getcontentlength>
        </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        <d:response><d:href>/dav/backups/new%20backup.pvbackup</d:href><d:propstat><d:prop>
          <d:creationdate>2024-02-03T04:05:06.123Z</d:creationdate><d:getcontentlength>2457600</d:getcontentlength>
        </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
      </d:multistatus>
      """)
    XCTAssertEqual(files.map(\.name), ["new backup.pvbackup", "old.json"])
    XCTAssertEqual(files[0].byteCount, 2_457_600)
    XCTAssertNotNil(files[0].createdAt)
    XCTAssertNil(files[0].modifiedAt)
    XCTAssertEqual(files[1].byteCount, 1024)
    XCTAssertEqual(files[1].modifiedAt, ISO8601DateFormatter().date(from: "2024-01-02T03:04:05Z"))
    XCTAssertFalse(files[0].timeLabel(chinese: true).isEmpty)
    XCTAssertNotNil(files[0].sizeLabel)
  }

  func testOnlySuccessfulPropertiesApplyAndLegacyFilenameProvidesFallback() throws {
    let files = try parse(
      """
      <multistatus xmlns="DAV:"><response><href>/dav/backups/backup_enc_1600000000000.json</href>
      <propstat><prop><getcontentlength>0</getcontentlength></prop><status>HTTP/1.1 200 OK</status></propstat>
      <propstat><prop><getcontentlength>999999</getcontentlength><getlastmodified>Tue, 02 Jan 2024 03:04:05 GMT</getlastmodified></prop><status>HTTP/1.1 404 Not Found</status></propstat>
      </response></multistatus>
      """)
    XCTAssertEqual(files.count, 1)
    XCTAssertEqual(files[0].byteCount, 0)
    XCTAssertNil(files[0].modifiedAt)
    XCTAssertEqual(files[0].backupDate, Date(timeIntervalSince1970: 1_600_000_000))
    XCTAssertEqual(
      RemoteBackup.dateFromFilename("PasswordVault-1600000000.pvbackup"), files[0].backupDate)
    XCTAssertNil(RemoteBackup.dateFromFilename("unrelated_1600000000.json"))
  }

  func testMissingAndInvalidMetadataRemainUnknown() throws {
    for length in ["", "-1", "not-a-size", "9999999999999999999999999"] {
      let files = try parse(
        """
        <d:multistatus xmlns:d="DAV:"><d:response><d:href>/dav/backups/manual.json</d:href><d:propstat><d:prop>
        <d:getcontentlength>\(length)</d:getcontentlength><d:getlastmodified>not-a-date</d:getlastmodified>
        </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>
        """)
      XCTAssertEqual(files.count, 1)
      XCTAssertNil(files[0].byteCount)
      XCTAssertNil(files[0].sizeLabel)
      XCTAssertNil(files[0].backupDate)
      XCTAssertEqual(files[0].timeLabel(chinese: true), "时间未知")
    }
  }

  func testExcludesDirectoriesFailedResponsesAndFilesOutsideTheConfiguredFolder() throws {
    let files = try parse(
      """
      <d:multistatus xmlns:d="DAV:">
      <d:response><d:href>/dav/backups/folder.json</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
      <d:response><d:href>/dav/backups/missing.json</d:href><d:status>HTTP/1.1 404 Not Found</d:status></d:response>
      <d:response><d:href>https://outside.example/dav/backups/foreign.json</d:href></d:response>
      <d:response><d:href>/dav/backups-other/foreign.json</d:href></d:response>
      <d:response><d:href>/dav/backups/%2e%2e/foreign.json</d:href></d:response>
      <d:response><d:href>/dav/backups/valid.json</d:href></d:response>
      <d:response><d:href>/dav/backups/valid.json</d:href></d:response>
      </d:multistatus>
      """)
    XCTAssertEqual(files.map(\.name), ["valid.json"])
    XCTAssertThrowsError(try parse("<d:multistatus xmlns:d=\"DAV:\"><d:response>"))
  }
}
