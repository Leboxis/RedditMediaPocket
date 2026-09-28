import Foundation
import Network

/// Échec explicite du forçage IPv4 pour X-Fetish.
public enum XFetishIPv4Error: LocalizedError {
    case noIPv4, connectionFailed, invalidResponse
    case unexpectedStatus(Int), missingLocation(Int), invalidLocation

    public var errorDescription: String? {
        switch self {
        case .noIPv4:
            return L("X-Fetish sans IPv4 joignable : le stockage exige la même adresse IPv4 que la galerie.",
                     "X-Fetish has no reachable IPv4: storage requires the same IPv4 as the gallery.")
        case .connectionFailed:
            return L("Connexion IPv4 X-Fetish impossible.", "X-Fetish IPv4 connection failed.")
        case .invalidResponse:
            return L("Redirection X-Fetish illisible.", "Unreadable X-Fetish redirect.")
        case .unexpectedStatus(let code):
            return L("Requête get_image en IPv4 : HTTP \(code), redirection attendue.",
                     "IPv4 get_image request: HTTP \(code), expected a redirect.")
        case .missingLocation(let code):
            return L("Redirection IPv4 HTTP \(code) sans en-tête Location.",
                     "IPv4 HTTP \(code) redirect has no Location header.")
        case .invalidLocation:
            return L("Destination de redirection IPv4 invalide ou non HTTPS.",
                     "IPv4 redirect destination is invalid or not HTTPS.")
        }
    }
}

/// `x-fetish.tube` a des AAAA Cloudflare mais `storage*.x-fetish.tube` est
/// IPv4-only (pas de AAAA). Sur iPhone IPv6, la galerie sort en IPv6 et le
/// stockage en IPv4 : le `acctoken` lié à l'IP est alors invalide (HTTP 403
/// systématique). Ce client force IPv4 pour `get_image` afin que le jeton
/// corresponde à l'IP du stockage.
public enum XFetishIPv4 {
    /// Decode only the header block. Errors contain no server-supplied text or
    /// URLs: Location and even the HTTP reason phrase may contain credentials.
    static func redirectURL(headerData: Data, from source: URL) throws -> URL {
        guard let text = String(data: headerData, encoding: .utf8)
                ?? String(data: headerData, encoding: .isoLatin1) else {
            throw XFetishIPv4Error.invalidResponse
        }
        let lines = text.components(separatedBy: "\r\n")
        let status = (lines.first ?? "").split(separator: " ")
        guard status.count >= 2, ["HTTP/1.0", "HTTP/1.1"].contains(String(status[0])),
              status[1].count == 3, let code = Int(status[1]), (100...599).contains(code) else {
            throw XFetishIPv4Error.invalidResponse
        }
        guard (300...399).contains(code) else {
            throw XFetishIPv4Error.unexpectedStatus(code)
        }
        let location = lines.dropFirst().compactMap { line -> String? in
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "location" else { return nil }
            return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }.first
        guard let location, !location.isEmpty else {
            throw XFetishIPv4Error.missingLocation(code)
        }
        guard let url = URL(string: location, relativeTo: source)?.absoluteURL,
              url.scheme == "https", url.host != nil else {
            throw XFetishIPv4Error.invalidLocation
        }
        return url
    }

    /// Première adresse IPv4 (A) de l'hôte, sans jamais toucher aux AAAA.
    public static func resolveIPv4(_ host: String) throws -> String {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        let ret = host.withCString { cHost in
            "443".withCString { cPort in
                getaddrinfo(cHost, cPort, &hints, &res)
            }
        }
        guard ret == 0, let list = res else { throw XFetishIPv4Error.noIPv4 }
        defer { freeaddrinfo(res) }
        var ptr: UnsafeMutablePointer<addrinfo>? = list
        while let cur = ptr {
            defer { ptr = cur.pointee.ai_next }
            guard cur.pointee.ai_family == AF_INET, let addr = cur.pointee.ai_addr else { continue }
            var ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &ip, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let str = String(cString: buf)
            if !str.isEmpty { return str }
        }
        throw XFetishIPv4Error.noIPv4
    }

    /// `GET get_image` en IPv4 forcé, sans suivre le corps : retourne le
    /// `Location` (URL `remote_control.php?file=…&acctoken=…` liée à l'IPv4).
    public static func storageURL(for getImage: URL, userAgent: String, referer: String) async throws -> URL {
        guard let host = getImage.host, XFetishAPI.isXFetish(getImage),
              getImage.path.lowercased().contains("/get_image/") else {
            throw XFetishIPv4Error.invalidResponse
        }
        let ipv4 = try resolveIPv4(host)
        let path = getImage.path.isEmpty ? "/" : getImage.path
        let target = path + (getImage.query.map { "?" + $0 } ?? "")
        let requestLines = [
            "GET \(target) HTTP/1.1",
            "Host: \(host)",
            "User-Agent: \(userAgent)",
            "Referer: \(referer)",
            "Origin: https://x-fetish.tube",
            "Accept: image/avif,image/webp,image/apng,image/*,*/*;q=0.8",
            "Connection: close",
            "", "",
        ]
        let requestData = Data(requestLines.joined(separator: "\r\n").utf8)

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
        let params = NWParameters(tls: tls)
        params.preferNoProxies = true
        let conn = NWConnection(host: NWEndpoint.Host(ipv4), port: NWEndpoint.Port(443), using: params)

        return try await withCheckedThrowingContinuation { cont in
            var resumed = false
            var buffer = Data()
            func resume(_ result: Result<URL, Error>) {
                guard !resumed else { return }
                resumed = true
                conn.cancel()
                cont.resume(with: result)
            }
            func receiveHeaders() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    if let error { resume(.failure(error)); return }
                    if let data { buffer.append(data) }
                    if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                        let headerData = buffer[..<range.lowerBound]
                        do {
                            resume(.success(try redirectURL(headerData: Data(headerData), from: getImage)))
                        } catch {
                            resume(.failure(error))
                        }
                        return
                    }
                    if isComplete {
                        resume(.failure(XFetishIPv4Error.invalidResponse)); return
                    }
                    if buffer.count > 256_000 {
                        resume(.failure(XFetishIPv4Error.invalidResponse)); return
                    }
                    receiveHeaders()
                }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: requestData, completion: .contentProcessed { error in
                        if let error { resume(.failure(error)); return }
                        receiveHeaders()
                    })
                case .failed(let error):
                    resume(.failure(error))
                case .cancelled:
                    resume(.failure(XFetishIPv4Error.connectionFailed))
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                resume(.failure(XFetishIPv4Error.connectionFailed))
            }
        }
    }
}
