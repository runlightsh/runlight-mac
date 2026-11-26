import CryptoKit
import Foundation

/// Gets a token from an install the way a desktop app should (RFC 8252): the person signs in and
/// allows the app on the install's own page, in their browser, and the answer comes back to a
/// one-off address on this Mac's loopback interface. PKCE ties the answer to this app, and a
/// random state ties it to this request.
///
/// Runlight's OAuth server registers clients itself (no secret), accepts loopback addresses, and
/// with the "manage" scope issues a token that changes one site.
enum OAuthLoopback {
    struct Endpoints: Decodable, Sendable {
        let authorization_endpoint: URL
        let token_endpoint: URL
        let registration_endpoint: URL
    }

    struct Grant: Decodable, Sendable {
        let access_token: String
        let scope: String?
        let site: String?
    }

    enum Failure: Error, Equatable, Sendable {
        case unsupported
        case denied
        case timedOut
        case cancelled
        case failed(String)

        var message: String {
            switch self {
            case .unsupported: "This install can't hand out tokens by signing in. Update it, or paste a token instead."
            case .denied: "Editing wasn't allowed. Try again and choose Allow on the page that opens."
            case .timedOut: "Nothing came back from the browser. Try again, or paste a token instead."
            case .cancelled: "Cancelled."
            case .failed(let message): message
            }
        }
    }

    /// Runs the whole exchange and returns the token. `open` shows the install's page, normally in
    /// the default browser.
    static func token(base: URL, scope: String, site: String, appName: String = "Runlight for Mac", session: URLSession, timeout: TimeInterval = 300, open: @escaping @MainActor (URL) -> Void) async throws(Failure) -> Grant {
        // Runlight lists its endpoints at the well-known address; where a host blocks dot paths below
        // the site (Drupal does), they're at Runlight's usual addresses all the same.
        let endpoints: Endpoints
        if let (data, response) = try? await session.data(from: base.appending(path: ".well-known/oauth-authorization-server")),
           (response as? HTTPURLResponse)?.statusCode == 200, let listed = try? JSONDecoder().decode(Endpoints.self, from: data) {
            endpoints = listed
        } else {
            endpoints = Endpoints(
                authorization_endpoint: base.appending(path: "oauth/authorize"),
                token_endpoint: base.appending(path: "oauth/token"),
                registration_endpoint: base.appending(path: "oauth/register")
            )
        }

        let listener: Listener
        do {
            listener = try await Listener.start()
        } catch {
            throw .failed("Couldn't open a local address for the answer (\(error.localizedDescription)).")
        }
        defer { listener.stop() }
        let redirect = "http://127.0.0.1:\(listener.port)/callback"

        // Register for this one address; Runlight keeps nothing until the app is allowed.
        let clientID: String
        do {
            var request = URLRequest(url: endpoints.registration_endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["client_name": appName, "redirect_uris": [redirect]])
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 201,
                  let id = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["client_id"] as? String else {
                throw Failure.unsupported
            }
            clientID = id
        } catch {
            throw error as? Failure ?? .failed(error.localizedDescription)
        }

        let verifier = randomString(64)
        let state = randomString(24)
        var authorize = URLComponents(url: endpoints.authorization_endpoint, resolvingAgainstBaseURL: false)!
        authorize.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "code_challenge", value: challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "site", value: site),
        ]
        await open(authorize.url!)

        let answer: [String: String]
        do {
            answer = try await listener.callback(timeout: timeout)
        } catch {
            throw error as? Failure ?? .timedOut
        }
        guard answer["state"] == state else { throw .failed("The answer from the browser didn't match this request. Try again.") }
        if answer["error"] == "access_denied" { throw .denied }
        if let error = answer["error"] { throw .failed(answer["error_description"] ?? error) }
        guard let code = answer["code"] else { throw .failed("The browser sent back no code. Try again.") }

        do {
            var request = URLRequest(url: endpoints.token_endpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var form = URLComponents()
            form.queryItems = [
                URLQueryItem(name: "grant_type", value: "authorization_code"),
                URLQueryItem(name: "code", value: code),
                URLQueryItem(name: "redirect_uri", value: redirect),
                URLQueryItem(name: "client_id", value: clientID),
                URLQueryItem(name: "code_verifier", value: verifier),
            ]
            request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error_description"] as? String
                throw Failure.failed(reason ?? "The install didn't hand over the token.")
            }
            return try JSONDecoder().decode(Grant.self, from: data)
        } catch {
            throw error as? Failure ?? .failed(error.localizedDescription)
        }
    }

    static func challenge(for verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func randomString(_ length: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return String((0..<length).map { _ in alphabet.randomElement()! })
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    // MARK: The loopback listener

    /// Listens on 127.0.0.1 for the browser's one request back, answers it with a page saying to
    /// return to the app, and hands over the query. Plain sockets, bound to loopback only, so
    /// nothing off this Mac can reach it.
    final class Listener: @unchecked Sendable {
        private let socket: Int32
        private let source: DispatchSourceRead
        private let queue = DispatchQueue(label: "sh.runlight.mac.oauth")
        private let lock = NSLock()
        private var waiting: CheckedContinuation<[String: String], Error>?
        private var received: [String: String]?
        let port: UInt16

        private init(socket: Int32, port: UInt16) {
            self.socket = socket
            self.port = port
            source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: queue)
            source.setEventHandler { [weak self] in self?.accept() }
            source.setCancelHandler { [socket] in close(socket) }
            source.resume()
        }

        static func start() async throws -> Listener {
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard bound == 0, listen(fd, 4) == 0 else {
                let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                close(fd)
                throw error
            }
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }
            return Listener(socket: fd, port: UInt16(bigEndian: address.sin_port))
        }

        func callback(timeout: TimeInterval) async throws -> [String: String] {
            try await withThrowingTaskGroup(of: [String: String].self) { group in
                group.addTask {
                    try await withTaskCancellationHandler {
                        try await withCheckedThrowingContinuation { continuation in
                            self.lock.lock()
                            if let received = self.received {
                                self.lock.unlock()
                                continuation.resume(returning: received)
                            } else {
                                self.waiting = continuation
                                self.lock.unlock()
                            }
                        }
                    } onCancel: {
                        self.finish(throwing: Failure.cancelled)
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw Failure.timedOut
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        }

        func stop() {
            source.cancel()
            finish(throwing: Failure.cancelled)
        }

        private func finish(throwing error: Error) {
            lock.lock()
            let continuation = waiting
            waiting = nil
            lock.unlock()
            continuation?.resume(throwing: error)
        }

        /// One connection: read its request line, answer, and close.
        private func accept() {
            let client = Darwin.accept(socket, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var head = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while head.count < 16 * 1024, !head.contains(Data("\r\n\r\n".utf8)) {
                let count = recv(client, &buffer, buffer.count, 0)
                if count <= 0 { break }
                head.append(buffer, count: count)
            }
            let line = String(decoding: head, as: UTF8.self).split(separator: "\r\n").first.map(String.init) ?? ""
            let parts = line.split(separator: " ")
            let target = parts.count > 1 ? String(parts[1]) : ""
            let isCallback = parts.first == "GET" && target.hasPrefix("/callback")
            let query = URLComponents(string: "http://127.0.0.1\(target)")?.queryItems ?? []
            let answer = Dictionary(query.compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { first, _ in first })
            let page = isCallback ? Self.page(denied: answer["error"] != nil) : "Not found"
            let response = "HTTP/1.1 \(isCallback ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n\(page)"
            _ = Array(response.utf8).withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
            guard isCallback else { return }
            lock.lock()
            let continuation = waiting
            waiting = nil
            if continuation == nil, received == nil { received = answer }
            lock.unlock()
            continuation?.resume(returning: answer)
        }

        private static func page(denied: Bool) -> String {
            let title = denied ? "Editing wasn't allowed" : "Runlight can edit this site now"
            let detail = denied ? "Nothing changed. You can close this tab." : "You can close this tab and go back to Runlight."
            return """
            <!doctype html><meta charset="utf-8"><title>\(title)</title><meta name="color-scheme" content="light dark">
            <body style="font:15px -apple-system,system-ui,sans-serif;display:grid;place-items:center;min-height:90vh;margin:0">
            <div style="text-align:center"><div style="width:14px;height:14px;border-radius:50%;margin:0 auto 18px;background:\(denied ? "#a1a1aa" : "#22c55e");box-shadow:0 0 18px \(denied ? "transparent" : "#4ade80")"></div>
            <h1 style="font-size:20px;margin:0 0 8px">\(title)</h1><p style="margin:0;opacity:.7">\(detail)</p></div></body>
            """
        }
    }

}
