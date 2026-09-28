import Foundation
import Network

/// Fetch the pages which issue signed get_image URLs through the same IPv4
/// address family used to redeem them. Never log the raw request or response:
/// either may contain a short-lived credential.
public enum XFetishIPv4Pages {
    private static let maxResponseBytes = 8_000_000

    static func requestData(for url: URL, headers: [String: String]) throws -> Data {
        guard url.scheme == "https", url.host?.lowercased() == "x-fetish.tube",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw XFetishIPv4Error.invalidResponse
        }
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        let target = path + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
        var lines = ["GET \(target) HTTP/1.1", "Host: x-fetish.tube"]
        for field in ["User-Agent", "Referer", "Origin", "Accept", "X-Requested-With"] {
            if let value = headers.first(where: { $0.key.caseInsensitiveCompare(field) == .orderedSame })?.value {
                guard !value.contains("\r"), !value.contains("\n") else { throw XFetishIPv4Error.invalidResponse }
                lines.append("\(field): \(value)")
            }
        }
        lines += ["Accept-Encoding: identity", "Connection: close", "", ""]
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    static func parseResponse(_ data: Data, from url: URL) throws -> (Data, HTTPURLResponse) {
        guard data.count <= maxResponseBytes,
              let separator = data.range(of: Data("\r\n\r\n".utf8)),
              let headerText = String(data: data[..<separator.lowerBound], encoding: .utf8)
                ?? String(data: data[..<separator.lowerBound], encoding: .isoLatin1) else {
            throw XFetishIPv4Error.invalidResponse
        }
        let lines = headerText.components(separatedBy: "\r\n")
        let status = (lines.first ?? "").split(separator: " ")
        guard status.count >= 2, ["HTTP/1.0", "HTTP/1.1"].contains(String(status[0])),
              let code = Int(status[1]), (100...599).contains(code) else {
            throw XFetishIPv4Error.invalidResponse
        }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw XFetishIPv4Error.invalidResponse }
            fields[String(parts[0]).trimmingCharacters(in: .whitespaces).lowercased()] =
                String(parts[1]).trimmingCharacters(in: .whitespaces)
        }
        guard (fields["content-encoding"]?.lowercased() ?? "identity") == "identity",
              let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: String(status[0]), headerFields: fields) else {
            throw XFetishIPv4Error.invalidResponse
        }
        let body = data.subdata(in: separator.upperBound..<data.count)
        if fields["transfer-encoding"]?.lowercased().contains("chunked") == true {
            return (try decodeChunks(body), response)
        }
        if let length = fields["content-length"] {
            guard let expected = Int(length), expected >= 0, expected == body.count else {
                throw XFetishIPv4Error.invalidResponse
            }
        }
        return (body, response)
    }

    private static func decodeChunks(_ body: Data) throws -> Data {
        let bytes = [UInt8](body)
        var cursor = 0
        var result = Data()
        func lineEnd(from start: Int) -> Int? {
            guard start + 1 < bytes.count else { return nil }
            for index in start..<(bytes.count - 1) where bytes[index] == 13 && bytes[index + 1] == 10 {
                return index
            }
            return nil
        }
        while let end = lineEnd(from: cursor) {
            let sizeField = bytes[cursor..<end].prefix(while: { $0 != 59 })
            guard !sizeField.isEmpty, sizeField.count <= 8,
                  let size = Int(String(decoding: sizeField, as: UTF8.self), radix: 16),
                  size <= maxResponseBytes - result.count else {
                throw XFetishIPv4Error.invalidResponse
            }
            cursor = end + 2
            if size == 0 { return result }
            guard size <= bytes.count - cursor, bytes.count - cursor - size >= 2,
                  bytes[cursor + size] == 13, bytes[cursor + size + 1] == 10 else {
                throw XFetishIPv4Error.invalidResponse
            }
            result.append(contentsOf: bytes[cursor..<(cursor + size)])
            cursor += size + 2
        }
        throw XFetishIPv4Error.invalidResponse
    }

    public static func data(for url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        guard let host = url.host, host.lowercased() == "x-fetish.tube" else {
            throw XFetishIPv4Error.invalidResponse
        }
        let request = try requestData(for: url, headers: headers)
        let ipv4 = try XFetishIPv4.resolveIPv4(host)
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
        let params = NWParameters(tls: tls)
        params.preferNoProxies = true
        let connection = NWConnection(host: NWEndpoint.Host(ipv4), port: NWEndpoint.Port(443), using: params)
        let queue = DispatchQueue(label: "XFetishIPv4Pages")
        return try await withCheckedThrowingContinuation { continuation in
            var finished = false
            var buffer = Data()
            func finish(_ result: Result<(Data, HTTPURLResponse), Error>) {
                guard !finished else { return }
                finished = true
                connection.cancel()
                continuation.resume(with: result)
            }
            func receive() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { chunk, _, complete, error in
                    if let error { finish(.failure(error)); return }
                    if let chunk { buffer.append(chunk) }
                    if buffer.count > maxResponseBytes {
                        finish(.failure(XFetishIPv4Error.invalidResponse)); return
                    }
                    if complete {
                        do { finish(.success(try parseResponse(buffer, from: url))) }
                        catch { finish(.failure(error)) }
                    } else {
                        receive()
                    }
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: request, completion: .contentProcessed { error in
                        if let error { finish(.failure(error)) }
                        else { receive() }
                    })
                case .failed(let error): finish(.failure(error))
                case .cancelled: finish(.failure(XFetishIPv4Error.connectionFailed))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 30) {
                finish(.failure(XFetishIPv4Error.connectionFailed))
            }
        }
    }
}
