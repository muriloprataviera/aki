import Foundation
import Network

/// HTTP server bound to 127.0.0.1 only: nothing else on the network can reach it.
public final class HTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let requestedPort: UInt16
    private let maxBody: Int
    private let handler: Handler
    // Every NWListener/NWConnection callback runs on this queue, which guards the mutable state.
    private let queue = DispatchQueue(label: "aki.http")
    private var listener: NWListener?

    /// `port` 0 picks a free port (used by the checks).
    public init(port: UInt16, maxBody: Int = 25 * 1024 * 1024, handler: @escaping Handler) {
        requestedPort = port
        self.maxBody = maxBody
        self.handler = handler
    }

    /// Starts listening and returns the port. Throws if the port is taken.
    public func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let port = requestedPort == 0 ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: requestedPort)!
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        let once = Once()
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error), .waiting(let error):
                    listener.cancel()
                    if once.claim() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        queue.async { [listener] in listener?.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequest.parse(buffer, maxBody: self.maxBody) {
            case .complete(let request):
                let handler = self.handler
                Task {
                    let response = await handler(request)
                    self.send(response, on: connection)
                }
            case .incomplete where !isComplete && error == nil:
                self.receive(on: connection, buffer: buffer)
            case .incomplete:
                connection.cancel()
            case .invalid(let status, let reason):
                self.send(.error(status, reason), on: connection)
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(
            content: response.serialized(),
            completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// Lets exactly one of several racing callbacks through.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.withLock {
            if done { return false }
            done = true
            return true
        }
    }
}
