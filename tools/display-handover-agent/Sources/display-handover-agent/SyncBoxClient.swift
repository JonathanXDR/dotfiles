import DisplayHandoverAgentCore
import Foundation
import Security

enum SyncBoxError: Error, CustomStringConvertible {
    case noToken
    case rejectedToken
    case http(Int)
    case transport(String)
    case unreadable(String)

    var description: String {
        switch self {
        case .noToken: "no access token in the keychain, run `display-handover-agent register`"
        case .rejectedToken: "the Sync Box rejected the access token (HTTP 401), run `display-handover-agent register`"
        case .http(let code): "HTTP \(code)"
        case .transport(let message): message
        case .unreadable(let message): "unreadable response: \(message)"
        }
    }
}

final class SyncBoxClient: Sendable {
    let uniqueId: String
    private let session: URLSession
    private let address: Address

    init(uniqueId: String, ipAddress: String) {
        self.uniqueId = uniqueId
        address = Address(ipAddress)
        let configuration = URLSessionConfiguration.ephemeral
        // The Sync Box API asks consecutive requests to share one connection
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.timeoutIntervalForRequest = 4
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration, delegate: PinnedTrust(commonName: uniqueId), delegateQueue: nil)
    }

    var keychainAccount: String { "syncbox-\(uniqueId)" }

    func status(token: String) async throws(SyncBoxError) -> SyncBoxStatus {
        var request = URLRequest(url: try url("/api/v1"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data = try await send(request)
        do {
            return try SyncBoxStatus.parse(data)
        } catch {
            throw .unreadable(String(describing: error))
        }
    }

    /// Returns `nil` while the button on the box has not been pressed
    func register(appName: String, instanceName: String) async throws(SyncBoxError) -> (id: String, token: String)? {
        var request = URLRequest(url: try url("/api/v1/registrations"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["appName": appName, "instanceName": instanceName])
        let data: Data
        do throws(SyncBoxError) {
            data = try await send(request)
        } catch .http(400) {
            return nil
        }
        guard let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = reply["accessToken"] as? String,
              let id = reply["registrationId"].map({ "\($0)" })
        else { return nil }
        return (id, token)
    }

    private func url(_ path: String) throws(SyncBoxError) -> URL {
        guard let url = URL(string: "https://\(address.current)\(path)") else {
            throw .transport("invalid Sync Box address \"\(address.current)\"")
        }
        return url
    }

    private func send(_ request: URLRequest) async throws(SyncBoxError) -> Data {
        let data: Data
        let response: URLResponse
        let host = address.current
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // Any failure may mean a new DHCP address, and the certificate pin protects the token on any host
            await address.refresh(host: "\(uniqueId).local")
            let error = error as NSError
            if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled {
                throw .transport("TLS certificate rejected by \(host), it is not the configured Sync Box")
            }
            throw .transport("\(host): \(error.localizedDescription)")
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw .rejectedToken }
        guard code == 200 else { throw .http(code) }
        return data
    }
}

private final class Address: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String
    private var lastLookup = Date.distantPast

    init(_ value: String) { self.value = value }

    var current: String { lock.withLock { value } }

    func refresh(host: String) async {
        let due = lock.withLock {
            guard Date().timeIntervalSince(lastLookup) >= 60 else { return false }
            lastLookup = Date()
            return true
        }
        guard due else { return }
        // getaddrinfo blocks for seconds when mDNS gets no answer, so keep it off the concurrency pool
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                self.lookUp(host: host)
                continuation.resume()
            }
        }
    }

    private func lookUp(host: String) {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return }
        defer { freeaddrinfo(result) }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(first.pointee.ai_addr, first.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0
        else { return }
        let resolved = String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
        lock.withLock {
            if resolved != value { Log.info("Sync Box address changed from \(value) to \(resolved)") }
            value = resolved
        }
    }
}

private final class PinnedTrust: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let commonName: String
    private let anchor: SecCertificate

    init(commonName: String) {
        self.commonName = commonName
        anchor = SecCertificateCreateWithData(nil, Data(base64Encoded: rootHSB)! as CFData)!
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?)
    {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else { return (.performDefaultHandling, nil) }
        // The box's certificate has no subjectAltName, so the check compares its common name instead of the host name
        SecTrustSetPolicies(trust, SecPolicyCreateBasicX509())
        SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        var name: CFString?
        guard SecTrustEvaluateWithError(trust, nil),
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
              SecCertificateCopyCommonName(leaf, &name) == errSecSuccess,
              name as String? == commonName
        else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }
}

/// Signify `root-hsb` CA from aiohuesyncbox `hsb_cacert.py`, SHA-256 fingerprint
/// A8:4F:E4:D6:E4:B7:24:4D:45:D0:A0:03:4F:7E:E1:49:85:2C:EC:B5:2E:BA:7F:C1:2A:3A:CA:76:6E:E6:8C:74
private let rootHSB = """
    MIIBwDCCAWagAwIBAgIBATAKBggqhkjOPQQDAjA2MQswCQYDVQQGEwJOTDEUMBIG\
    A1UECgwLUGhpbGlwcyBIdWUxETAPBgNVBAMMCHJvb3QtaHNiMCAXDTE3MDEwMTAw\
    MDAwMFoYDzk5OTkxMjMxMjM1OTU5WjA2MQswCQYDVQQGEwJOTDEUMBIGA1UECgwL\
    UGhpbGlwcyBIdWUxETAPBgNVBAMMCHJvb3QtaHNiMFkwEwYHKoZIzj0CAQYIKoZI\
    zj0DAQcDQgAEr9FgOxnsonsrnUZr3C4ggST7YCR9wISvDuwlNdZcAz4HiVCNmAAP\
    tAnAFDG0U19Rmc4MfRYBMO8GrOHrOkZ7sKNjMGEwHQYDVR0OBBYEFCK+VIWZqp++\
    DHqmGLWEZHYdH9v7MB8GA1UdIwQYMBaAFCK+VIWZqp++DHqmGLWEZHYdH9v7MA8G\
    A1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgGGMAoGCCqGSM49BAMCA0gAMEUC\
    IAFDI0Q4IOPxV7cY4wSVOJAn4y5AdZwrItJ1XuNpmCltAiEA5c6wcu6qmF596uyA\
    r7xLnr3/F5zJxrE3AyLD4t+5oKs=
    """
