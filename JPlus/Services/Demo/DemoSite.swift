import Foundation

/// The built-in demo for App Review: signing in to `demo.apple.com`, or as
/// `reviewer@apple.com`, skips the token check and talks to `DemoServer`, a
/// local stand-in for a Jira Cloud site with sample projects, issues,
/// versions and Daily Priorities. Nothing leaves the device.
nonisolated enum DemoSite {
    static let host = "demo.apple.com"
    static let siteURL = URL(string: "https://demo.apple.com")!
    static let email = "reviewer@apple.com"

    /// Whether what was typed into the sign-in form means the demo.
    static func isDemo(site: String, email: String) -> Bool {
        if email.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(Self.email) == .orderedSame {
            return true
        }
        var text = site.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !text.contains("://") { text = "https://" + text }
        return URLComponents(string: text)?.host == host
    }

    /// Whether a link points into the demo site, which has no web pages.
    static func isDemo(_ url: URL) -> Bool {
        url.host()?.lowercased() == host
    }

    /// A session whose every request is answered by `DemoServer`.
    static let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DemoURLProtocol.self]
        return URLSession(configuration: configuration)
    }()
}

extension JiraCredentials {
    var isDemo: Bool { DemoSite.isDemo(site: siteURL.absoluteString, email: email) }

    /// Credentials for the demo whatever else was typed: the token isn't
    /// checked, so a blank one is fine.
    static func demo(email: String, apiToken: String) -> JiraCredentials {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return JiraCredentials(siteURL: DemoSite.siteURL, email: trimmed.isEmpty ? DemoSite.email : trimmed,
                               apiToken: token.isEmpty ? "demo" : token)
    }
}

/// Hands each request to `DemoServer.shared` instead of the network.
/// URLSession calls it from one thread at a time.
nonisolated final class DemoURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = DemoServer.shared.respond(to: request, body: Self.body(of: request))
        // A little latency, so loading states look as they do on a real site.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.12) { [self] in
            let http = HTTPURLResponse(url: request.url ?? DemoSite.siteURL, statusCode: response.status,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": response.contentType])!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    /// URLSession moves a request's body into a stream before it gets here.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
