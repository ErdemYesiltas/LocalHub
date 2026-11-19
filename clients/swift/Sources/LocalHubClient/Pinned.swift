import CryptoKit
import Foundation

/// URLSession delegate that trusts exactly one certificate: the paired SHA-256, on the paired host and port.
/// The challenge is answered before any request bytes (or the token) are sent; redirects are refused.
final class PinningDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let fingerprint: String
    let host: String
    let port: Int
    private let lock = NSLock()
    private var mismatched = false

    init(fingerprint: String, address: URL) {
        self.fingerprint = fingerprint
        host = address.host ?? ""
        port = address.port ?? 443
    }

    var sawMismatch: Bool { lock.withLock { mismatched } }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        await urlSession(session, didReceive: challenge)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == host, challenge.protectionSpace.port == port,
              let trust = challenge.protectionSpace.serverTrust,
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            return (.cancelAuthenticationChallenge, nil)
        }
        let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
        guard digest == fingerprint else {
            lock.withLock { mismatched = true }
            return (.cancelAuthenticationChallenge, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}
