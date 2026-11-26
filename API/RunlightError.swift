import Foundation

/// The error Runlight sends: `{ error, code, params }`. The app matches on `code`, never the English.
struct APIProblem: Codable, Equatable, Sendable {
    let error: String
    let code: String
    var params: [String: String]?
}

/// Everything that can go wrong talking to a Runlight install, sorted into what the app shows.
enum RunlightError: Error, Equatable, Sendable {
    /// Runlight answered with an error.
    case api(status: Int, problem: APIProblem)
    /// An answer that wasn't Runlight's JSON error, such as a proxy's 502 page.
    case http(status: Int)
    /// No network at all; show cached numbers, greyed, and try again when it returns.
    case offline
    /// The address didn't answer: a wrong host, a refused connection, a timeout, a bad certificate.
    case unreachable(String)
    /// Something answered, but not Runlight.
    case notRunlight
    /// Runlight answered with JSON this app couldn't read.
    case decoding(String)

    var status: Int? {
        switch self {
        case .api(let status, _), .http(let status): status
        default: nil
        }
    }

    var code: String? {
        if case .api(_, let problem) = self { problem.code } else { nil }
    }

    /// 401: the token is missing, deleted, or not this install's. Offer to replace it.
    var isTokenRejected: Bool { status == 401 }

    /// 403 `token_read_only`: a read token tried to change something. Offer a manage token.
    var isReadOnly: Bool { code == "token_read_only" }

    /// 403 with another token code: the token can't do this here.
    var isTokenForbidden: Bool { status == 403 && (code?.hasPrefix("token_") ?? false) && !isReadOnly }

    /// 404 `unknown_site`: the site is gone, or this token can't see it.
    var isUnknownSite: Bool { code == "unknown_site" }

    /// 502 or 504: a hub couldn't reach the install that counts this site. Only that site is down.
    var isSiteUnreachable: Bool { status == 502 || status == 504 }

    /// The network is down or the host can't be reached: keep the last numbers on screen.
    var isConnectivity: Bool {
        switch self {
        case .offline, .unreachable: true
        default: false
        }
    }

    /// The form field an error is about, so the message can sit next to it.
    /// Words for the person: the server's own message for API errors, which already names the
    /// field and the fix, and plain sentences for everything else.
    var message: String {
        switch self {
        case .api(_, let problem):
            if problem.code == "unauthorized" { return "Token rejected." }
            return problem.error
        case .http(let status):
            return status == 502 || status == 504 ? "Couldn't reach this site's install." : "The server answered \(status)."
        case .offline:
            return "Offline."
        case .unreachable(let reason):
            return reason
        case .notRunlight:
            return "That address didn't answer like a Runlight install."
        case .decoding:
            return "Runlight answered in a way this app doesn't understand. Check for an update."
        }
    }

    /// Maps a transport failure into the cases above.
    static func from(_ error: URLError) -> RunlightError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return .offline
        case .cannotFindHost, .dnsLookupFailed:
            return .unreachable("Couldn't find that address.")
        case .cannotConnectToHost:
            return .unreachable("Couldn't connect to that address.")
        case .timedOut:
            return .unreachable("The install took too long to answer.")
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            return .unreachable("The install's certificate isn't trusted.")
        case .appTransportSecurityRequiresSecureConnection:
            return .unreachable("Use an https:// address.")
        default:
            return .unreachable(error.localizedDescription)
        }
    }
}

extension RunlightError: LocalizedError {
    var errorDescription: String? { message }
}
