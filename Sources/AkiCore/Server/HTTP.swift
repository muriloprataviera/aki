import Foundation

/// The small slice of HTTP/1.1 Aki needs: one request per connection,
/// bodies sized by Content-Length.
public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    /// Header names are lowercased.
    public var headers: [String: String]
    public var body: Data

    public init(
        method: String, path: String, query: [String: String] = [:],
        headers: [String: String] = [:], body: Data = Data()
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    enum Parse {
        case complete(HTTPRequest)
        case incomplete
        case invalid(status: Int, reason: String)
    }

    static func parse(_ buffer: Data, maxBody: Int) -> Parse {
        guard let end = buffer.firstRange(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > 64 * 1024 ? .invalid(status: 431, reason: "Headers too large") : .incomplete
        }
        guard let head = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else {
            return .invalid(status: 400, reason: "Bad request")
        }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count == 3, let components = URLComponents(string: "http://h" + parts[1]) else {
            return .invalid(status: 400, reason: "Bad request line")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil {
            return .invalid(status: 411, reason: "Content-Length required")
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .invalid(status: 400, reason: "Bad Content-Length") }
        guard length <= maxBody else { return .invalid(status: 413, reason: "Body too large") }
        let bodyStart = end.upperBound
        guard buffer.count - (bodyStart - buffer.startIndex) >= length else { return .incomplete }

        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        return .complete(
            HTTPRequest(
                method: String(parts[0]).uppercased(),
                path: components.path,
                query: query,
                headers: headers,
                body: Data(buffer[bodyStart..<(bodyStart + length)])))
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json(_ status: Int, _ value: JSONValue) -> HTTPResponse {
        let body = (try? JSON.encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: body)
    }

    public static func error(_ status: Int, _ message: String) -> HTTPResponse {
        json(status, ["error": .string(message)])
    }

    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        var all = headers
        all["Content-Length"] = String(body.count)
        all["Connection"] = "close"
        for (name, value) in all.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        return Data(head.utf8) + body
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 411: "Length Required"
        case 413: "Payload Too Large"
        case 431: "Request Header Fields Too Large"
        default: status >= 500 ? "Internal Server Error" : "Status"
        }
    }
}
