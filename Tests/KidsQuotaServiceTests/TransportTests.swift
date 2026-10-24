import XCTest
@testable import KidsQuotaService

final class TransportTests:XCTestCase {
    func testPartialBodyWaitsAndCompleteParses() throws {
        let head="POST /v1/services HTTP/1.1\r\nHost: localhost:48123\r\nContent-Length: 2\r\n\r\n"
        XCTAssertNil(try HTTPParser.parse(Data((head+"{").utf8)))
        XCTAssertEqual(try HTTPParser.parse(Data((head+"{}").utf8))?.body,Data("{}".utf8))
    }
    func testRejectAmbiguousOrSmuggledRequests() {
        for headers in ["Content-Length: 0\r\nContent-Length: 0", "Transfer-Encoding: chunked", " Content-Length: 0", "Content-Length: -1", "Content-Length: 99999999999999999999999", "Content-Length: 0\r\nHost: evil"] {
            XCTAssertThrowsError(try HTTPParser.parse(Data("POST /v1/services HTTP/1.1\r\nHost: localhost:48123\r\n\(headers)\r\n\r\n".utf8)))
        }
        XCTAssertThrowsError(try HTTPParser.parse(Data("GET /v1/services HTTP/1.1\r\nHost: localhost:48123\r\n\r\nx".utf8)))
    }
    func testHeadersAndBodyBounded() {
        XCTAssertThrowsError(try HTTPParser.parse(Data(repeating:65,count:16385)))
        XCTAssertThrowsError(try HTTPParser.parse(Data(repeating:65,count:100_000)))
    }
    func testNativeFrameLittleEndianAndBounded() throws {
        let bytes=try NativeFrame.encode(Data("abc".utf8))
        XCTAssertEqual(Array(bytes.prefix(4)),[3,0,0,0])
        XCTAssertThrowsError(try NativeFrame.encode(Data(repeating:0,count:65537)))
    }
}
