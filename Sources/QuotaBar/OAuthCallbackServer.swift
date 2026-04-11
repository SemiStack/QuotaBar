@preconcurrency import Network
import Foundation

actor OAuthCallbackServer {
    struct AuthorizationResponse: Sendable, Equatable {
        let code: String
        let state: String
    }

    private var listener: NWListener?
    private var codeContinuation: CheckedContinuation<AuthorizationResponse, Error>?
    private var pendingResult: Result<AuthorizationResponse, any Error>?
    private var timeoutTask: Task<Void, Never>?
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 300) {
        self.timeout = timeout
    }

    // MARK: - Public API

    func start(port fixedPort: NWEndpoint.Port? = nil) async throws -> Int {
        guard listener == nil else {
            throw AppError("OAuth 回调服务器已在运行")
        }
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let listener = try NWListener(using: params, on: fixedPort ?? .any)
        self.listener = listener
        let queue = DispatchQueue(label: "com.semiquotabar.oauth-callback")

        let port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    if let port = listener.port?.rawValue {
                        continuation.resume(returning: Int(port))
                    } else {
                        continuation.resume(throwing: AppError("无法获取服务器端口"))
                    }
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                case .cancelled:
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: AppError("OAuth 回调服务器已取消"))
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connection.start(queue: queue)
                self.receiveRequest(on: connection)
            }

            listener.start(queue: queue)
        }

        Log.debug("OAuth 回调服务器已启动，端口: \(port)")
        return port
    }

    func waitForCode(expectedState: String? = nil) async throws -> String {
        let response = try await waitForAuthorizationResponse()

        if let expectedState,
           response.state != expectedState {
            throw AppError("OAuth 回调 state 不匹配")
        }

        return response.code
    }

    func waitForAuthorizationResponse() async throws -> AuthorizationResponse {
        if let pending = pendingResult {
            pendingResult = nil
            stop()
            return try pending.get()
        }

        guard codeContinuation == nil else {
            throw AppError("waitForCode() 已在等待中，不能重复调用")
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.codeContinuation = continuation
            self.timeoutTask = Task { [timeout] in
                try? await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000_000)
                guard !Task.isCancelled else { return }
                self.deliverError(AppError("OAuth 回调超时"))
            }
        }
    }

    func stop() {
        cancelListener()
        if let continuation = codeContinuation {
            codeContinuation = nil
            continuation.resume(throwing: CancellationError())
        }
    }

    // MARK: - Connection Handling

    private nonisolated func receiveRequest(on connection: NWConnection) {
        // OAuth callback requests are small enough to arrive in a single TCP segment.
        // If this assumption ever breaks, implement buffered reading until "\r\n\r\n".
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data else {
                connection.cancel()
                return
            }

            let request = String(data: data, encoding: .utf8) ?? ""
            switch Self.parseRequest(request) {
            case .code(let code):
                Self.sendResponse(on: connection, success: true)
                Task { await self.deliverCode(code) }
            case .oauthError(let error):
                Self.sendResponse(on: connection, success: false)
                Task { await self.deliverError(error) }
            case .notCallback:
                Self.sendNotFound(on: connection)
            }
        }
    }

    // MARK: - Result Delivery

    private func deliverCode(_ response: AuthorizationResponse) {
        resumeContinuation(with: .success(response))
    }

    private func deliverError(_ error: AppError) {
        resumeContinuation(with: .failure(error))
    }

    private func cancelListener() {
        listener?.cancel()
        listener = nil
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    private func resumeContinuation(with result: Result<AuthorizationResponse, any Error>) {
        if let continuation = codeContinuation {
            codeContinuation = nil
            cancelListener()
            continuation.resume(with: result)
        } else if pendingResult == nil {
            pendingResult = result
        }
    }

    // MARK: - HTTP Parsing

    enum ParseResult: Sendable {
        case code(AuthorizationResponse)
        case oauthError(AppError)
        case notCallback
    }

    static func parseRequest(_ request: String) -> ParseResult {
        guard let firstLine = request.split(separator: "\r\n", maxSplits: 1).first else {
            return .notCallback
        }

        let parts = firstLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2,
              let components = URLComponents(string: String(parts[1])),
              components.path == "/oauth2callback" || components.path == "/callback" || components.path == "/auth/callback" else {
            return .notCallback
        }

        let queryItems = components.queryItems ?? []

        if let error = queryItems.first(where: { $0.name == "error" })?.value {
            let description = queryItems.first(where: { $0.name == "error_description" })?.value ?? error
            return .oauthError(AppError("OAuth 错误: \(description)"))
        }

        guard let code = queryItems.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            return .oauthError(AppError("OAuth 回调缺少授权码"))
        }

        guard let state = queryItems.first(where: { $0.name == "state" })?.value, !state.isEmpty else {
            return .oauthError(AppError("OAuth 回调缺少 state"))
        }

        return .code(AuthorizationResponse(code: code, state: state))
    }

    // MARK: - HTTP Responses

    private static func sendResponse(on connection: NWConnection, success: Bool) {
        let statusLine = success ? "HTTP/1.1 200 OK" : "HTTP/1.1 400 Bad Request"
        let body = success
            ? "<html><body><h2>认证成功！</h2><p>您可以关闭此页面。</p></body></html>"
            : "<html><body><h2>认证失败</h2><p>请重试。</p></body></html>"
        let contentLength = body.utf8.count
        let headers = "\(statusLine)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(contentLength)\r\nConnection: close\r\n\r\n"
        let responseData = Data(headers.utf8) + Data(body.utf8)
        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func sendNotFound(on connection: NWConnection) {
        let response = "HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
