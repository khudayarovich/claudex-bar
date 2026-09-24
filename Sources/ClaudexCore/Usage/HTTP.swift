import Foundation

public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    /// Header names lowercased.
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

public enum HTTPFailure: Error, Sendable, Equatable {
    case transport(String)
}

public protocol HTTPClient: Sendable {
    func get(_ url: URL, headers: [String: String], timeout: TimeInterval) async -> Result<HTTPResponse, HTTPFailure>
}

/// Ephemeral session: no cookies, no cache, and redirects are refused so an Authorization
/// header can never be forwarded to another host.
public final class URLSessionHTTPClient: NSObject, HTTPClient, URLSessionTaskDelegate, @unchecked Sendable {
    private let session: URLSession

    public override init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        let delegate = RedirectRefuser()
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        super.init()
    }

    public func get(_ url: URL, headers: [String: String], timeout: TimeInterval) async -> Result<HTTPResponse, HTTPFailure> {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(.transport("not HTTP")) }
            var lowered: [String: String] = [:]
            for (k, v) in http.allHeaderFields {
                if let k = k as? String, let v = v as? String { lowered[k.lowercased()] = v }
            }
            return .success(HTTPResponse(status: http.statusCode, headers: lowered, body: data))
        } catch {
            return .failure(.transport((error as NSError).localizedDescription))
        }
    }
}

private final class RedirectRefuser: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public enum RetryAfter {
    /// Parses delta-seconds or an IMF-fixdate (`Wed, 21 Oct 2026 07:28:00 GMT`).
    public static func parse(_ value: String?, now: Date) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Double(value), seconds >= 0 { return seconds }
        let parts = value.replacingOccurrences(of: ",", with: "").split(separator: " ")
        guard parts.count >= 5 else { return nil }
        let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
                      "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]
        guard let day = Int(parts[1]), let month = months[parts[2].prefix(3).lowercased()], let year = Int(parts[3]) else { return nil }
        let hms = parts[4].split(separator: ":").compactMap { Int($0) }
        guard hms.count == 3 else { return nil }
        let days = TimeParsing.daysFromCivil(year, month, day)
        let date = Date(timeIntervalSince1970: Double(days * 86_400 + hms[0] * 3600 + hms[1] * 60 + hms[2]))
        return max(0, date.timeIntervalSince(now))
    }
}

/// Exponential backoff with caps and jitter for polling third-party endpoints.
public struct BackoffPolicy: Sendable, Equatable {
    public private(set) var consecutiveFailures = 0

    public init() {}

    public mutating func succeeded() { consecutiveFailures = 0 }

    /// Delay after a 429: honour `Retry-After` (at least 60 s), else 5 min doubling to 1 h.
    public mutating func rateLimited(retryAfter: TimeInterval?, jitter: Double) -> TimeInterval {
        consecutiveFailures += 1
        let base = retryAfter.map { max($0, 60) } ?? min(300 * pow(2, Double(consecutiveFailures - 1)), 3600)
        return base * (1 + 0.2 * jitter)
    }

    /// Delay after a 5xx / network error: 30 s doubling to 30 min.
    public mutating func failed(jitter: Double) -> TimeInterval {
        consecutiveFailures += 1
        return min(30 * pow(2, Double(consecutiveFailures - 1)), 1800) * (1 + 0.2 * jitter)
    }
}
