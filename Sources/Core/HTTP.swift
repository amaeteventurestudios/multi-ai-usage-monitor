// Portions of this file derive from AI Usage Monitor
// (https://github.com/stavrop/ai-usage-monitor), Copyright 2026 Georgios
// Stavropoulos, licensed under the Apache License 2.0. Modified for
// Multi AI Usage Monitor, Copyright 2026 Amaete Umanah. See NOTICE.

import Foundation

/// A non-2xx response. Carries the status and, for 429/503, the server's
/// `Retry-After` hint so the caller waits exactly as long as asked instead of
/// guessing.
struct HTTPError: Error, LocalizedError {
    let status: Int
    let retryAfter: TimeInterval?
    var errorDescription: String? { "HTTP \(status)" }
}

/// Anything that went wrong before we had a response.
enum TransportError: Error, LocalizedError {
    case noResponse
    case emptyBody
    case badJSON
    case emptyUsage

    var errorDescription: String? {
        switch self {
        case .noResponse: return "No response from the server"
        case .emptyBody:  return "Empty response"
        case .badJSON:    return "Response was not valid JSON"
        case .emptyUsage: return "Response contained no usage windows"
        }
    }
}

/// One place where requests are built and responses are classified, so every
/// provider gets the same timeouts, the same status handling and the same
/// guarantee that a credential never reaches an error message.
enum HTTP {
    static let timeout: TimeInterval = 20

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout * 2
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        return URLSession(configuration: cfg)
    }()

    /// Parse an HTTP `Retry-After`: either a delay in seconds ("120") or an
    /// absolute HTTP-date. Returns seconds to wait, or nil if absent.
    static func parseRetryAfter(_ value: String?) -> TimeInterval? {
        guard let v = value?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
        if let secs = Double(v) { return max(0, secs) }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "GMT")
        fmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        if let date = fmt.date(from: v) { return max(0, date.timeIntervalSince(Date())) }
        return nil
    }

    /// GET a JSON object. `headers` may contain an Authorization value; it is
    /// used and then forgotten — never logged, never echoed into an error.
    static func getJSON(url: String,
                        headers: [String: String],
                        completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard let u = URL(string: url) else {
            completion(.failure(TransportError.noResponse)); return
        }
        var req = URLRequest(url: u)
        req.httpMethod = "GET"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        perform(req, completion: completion)
    }

    static func postJSON(url: String,
                         body: [String: Any],
                         completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard let u = URL(string: url) else {
            completion(.failure(TransportError.noResponse)); return
        }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        perform(req, completion: completion)
    }

    private static func perform(_ req: URLRequest,
                                completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let host = req.url?.host ?? "?"
        session.dataTask(with: req) { data, resp, err in
            if let err = err {
                Diagnostics.shared.warning("\(host): transport error \((err as NSError).code)")
                completion(.failure(err)); return
            }
            guard let http = resp as? HTTPURLResponse else {
                completion(.failure(TransportError.noResponse)); return
            }
            guard (200...299).contains(http.statusCode) else {
                let ra = parseRetryAfter(http.value(forHTTPHeaderField: "Retry-After"))
                Diagnostics.shared.warning("\(host): HTTP \(http.statusCode)")
                completion(.failure(HTTPError(status: http.statusCode, retryAfter: ra))); return
            }
            guard let data = data, !data.isEmpty else {
                completion(.failure(TransportError.emptyBody)); return
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure(TransportError.badJSON)); return
            }
            Diagnostics.shared.debug("\(host): HTTP \(http.statusCode), \(data.count) bytes parsed")
            completion(.success(obj))
        }.resume()
    }

    /// Classify any error into something the UI can act on, with wording that
    /// is safe to show and never contains credential material.
    static func classify(_ error: Error, provider: ProviderKind) -> AccountError {
        if let http = error as? HTTPError {
            switch http.status {
            case 401, 403:
                return AccountError(kind: .authenticationFailed,
                                    message: "Authentication failed (HTTP \(http.status)).",
                                    recovery: provider == .claude
                                        ? "Open Claude Code and sign in again, then Refresh."
                                        : "Open ChatGPT or run `codex` to sign in again, then Refresh.")
            case 429:
                return AccountError(kind: .rateLimited, message: "Rate-limited by the provider.",
                                    retryAfter: http.retryAfter)
            case 500...599:
                return AccountError(kind: .providerUnavailable,
                                    message: "Provider unavailable (HTTP \(http.status)).",
                                    retryAfter: http.retryAfter)
            default:
                return AccountError(kind: .network, message: "Request failed (HTTP \(http.status)).")
            }
        }
        if error is TransportError {
            let t = error as! TransportError
            switch t {
            case .badJSON, .emptyBody, .emptyUsage:
                return AccountError(kind: .parsing, message: t.errorDescription ?? "Unexpected response.")
            case .noResponse:
                return AccountError(kind: .network, message: "No response from the provider.")
            }
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            return AccountError(kind: .network, message: "Network unavailable.")
        }
        return AccountError(kind: .network, message: "Refresh failed.")
    }
}
