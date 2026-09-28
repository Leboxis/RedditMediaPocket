import XCTest
@testable import MediaCore

final class XFetishIPv4PagesTests: XCTestCase {
    private let url = URL(string: "https://x-fetish.tube/albums/3948/example/")!

    func testContentLengthHTMLIsReturnedUnchanged() throws {
        let response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: 6\r\n\r\n<html>".utf8)
        let (body, http) = try XFetishIPv4Pages.parseResponse(response, from: url)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "<html>")
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.mimeType, "text/html")
    }

    func testChunkedGalleryAndEmptyContinuation() throws {
        let chunked = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Type: text/html\r\n\r\n5\r\nhello\r\n6;extension=yes\r\n world\r\n0\r\n\r\n".utf8)
        let (body, _) = try XFetishIPv4Pages.parseResponse(chunked, from: url)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "hello world")

        let empty = Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".utf8)
        XCTAssertTrue(try XFetishIPv4Pages.parseResponse(empty, from: url).0.isEmpty)
    }

    func testServerRefusalIsAvailableToNetworkPolicy() throws {
        let response = Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".utf8)
        XCTAssertEqual(try XFetishIPv4Pages.parseResponse(response, from: url).1.statusCode, 404)
    }

    func testTruncatedOrCompressedPageCannotBeParsedAsGallery() {
        let truncated = Data("HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\nshort".utf8)
        let compressed = Data("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\n\r\nnot-html".utf8)
        let malformedChunk = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nab\r\n0\r\n\r\n".utf8)
        for response in [truncated, compressed, malformedChunk] {
            XCTAssertThrowsError(try XFetishIPv4Pages.parseResponse(response, from: url))
        }
    }

    func testIPv4PageRequestKeepsEncodedQueryAndAlbumReferer() throws {
        let source = URL(string: "https://x-fetish.tube/albums/3948/example/?mode=async&token=a%2Bb")!
        let request = String(decoding: try XFetishIPv4Pages.requestData(for: source,
            headers: ["User-Agent": "Safari", "Referer": url.absoluteString]), as: UTF8.self)
        XCTAssertTrue(request.hasPrefix("GET /albums/3948/example/?mode=async&token=a%2Bb HTTP/1.1\r\n"))
        XCTAssertTrue(request.contains("\r\nHost: x-fetish.tube\r\n"))
        XCTAssertTrue(request.contains("\r\nReferer: \(url.absoluteString)\r\n"))
        XCTAssertTrue(request.contains("\r\nAccept-Encoding: identity\r\n"))
    }
}
