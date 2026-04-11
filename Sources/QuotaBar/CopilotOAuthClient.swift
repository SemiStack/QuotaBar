import Foundation

// MARK: - Device Code Response

struct DeviceCodeResponse: Decodable, Sendable {
    let deviceCode: String
    let userCode: String
    let verificationUri: String
    let expiresIn: Int
    let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationUri = "verification_uri"
        case expiresIn = "expires_in"
        case interval
    }
}

// MARK: - Token Poll Response

struct TokenPollResponse: Decodable, Sendable {
    let accessToken: String?
    let tokenType: String?
    let scope: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case scope
        case error
    }
}

// MARK: - GitHub User Response (for /user endpoint)

private struct GitHubUserResponse: Decodable {
    let login: String
    let email: String?
}

// MARK: - CopilotOAuthClient

struct CopilotOAuthClient: Sendable {
    private static let clientID = "178c6fc778ccc68e1d6a"
    private static let deviceCodeURL = URL(string: "https://github.com/login/device/code")!
    private static let tokenURL = URL(string: "https://github.com/login/oauth/access_token")!
    private static let userURL = URL(string: "https://api.github.com/user")!
    private static let scopes = "read:user copilot"

    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Step 1: Request Device Code

    func requestDeviceCode() async throws -> DeviceCodeResponse {
        var request = URLRequest(url: Self.deviceCodeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "client_id=\(Self.clientID)&scope=\(Self.scopes.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? Self.scopes)"
        request.httpBody = Data(body.utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError("GitHub 设备码请求失败：无效响应")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            Log.error("GitHub 设备码请求失败：HTTP \(http.statusCode)")
            throw AppError("GitHub 设备码请求失败：HTTP \(http.statusCode)")
        }

        do {
            return try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
        } catch {
            throw AppError("GitHub 设备码解析失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Step 3: Poll for Token

    func pollForToken(deviceCode: String, interval: Int) async throws -> String {
        var currentInterval = interval
        let deadline = Date().addingTimeInterval(900) // 15 min max

        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(currentInterval) * 1_000_000_000)
            try Task.checkCancellation()

            let result = try await requestToken(deviceCode: deviceCode)

            if let token = result.accessToken {
                return token
            }

            switch result.error {
            case "authorization_pending":
                continue
            case "slow_down":
                currentInterval += 5
                continue
            case "expired_token":
                throw AppError("GitHub 授权已过期，请重新登录。")
            case "access_denied":
                throw AppError("用户拒绝了 GitHub 授权。")
            case let error?:
                throw AppError("GitHub 授权失败：\(error)")
            default:
                throw AppError("GitHub 授权返回格式异常")
            }
        }

        throw AppError("GitHub 授权超时，请重新登录。")
    }

    private func requestToken(deviceCode: String) async throws -> TokenPollResponse {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let grantType = "urn:ietf:params:oauth:grant-type:device_code"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let encodedDeviceCode = deviceCode.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? deviceCode
        let body = "client_id=\(Self.clientID)&device_code=\(encodedDeviceCode)&grant_type=\(grantType)"
        request.httpBody = Data(body.utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError("GitHub Token 请求失败：无效响应")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            Log.error("GitHub Token 请求失败：HTTP \(http.statusCode)")
            throw AppError("GitHub Token 请求失败：HTTP \(http.statusCode)")
        }

        do {
            return try JSONDecoder().decode(TokenPollResponse.self, from: data)
        } catch {
            throw AppError("GitHub Token 解析失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Step 4: Fetch User Info

    func fetchUserInfo(accessToken: String) async throws -> (login: String, email: String?) {
        var request = URLRequest(url: Self.userURL)
        request.setValue("token \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("QuotaBar", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError("GitHub 用户信息请求失败：无效响应")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            Log.error("GitHub 用户信息请求失败：HTTP \(http.statusCode)")
            throw AppError("GitHub 用户信息请求失败：HTTP \(http.statusCode)")
        }

        do {
            let user = try JSONDecoder().decode(GitHubUserResponse.self, from: data)
            return (login: user.login, email: user.email)
        } catch {
            throw AppError("GitHub 用户信息解析失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Full Flow (Steps 1-5)

    func startLogin(
        store: AccountStore = .shared,
        onDeviceCode: @escaping @Sendable (DeviceCodeResponse) -> Void
    ) async throws -> OAuthAccount {
        Log.info("Copilot OAuth: 开始设备流登录")

        let deviceResponse = try await requestDeviceCode()
        onDeviceCode(deviceResponse)

        Log.info("Copilot OAuth: 等待用户授权 (user_code=\(deviceResponse.userCode))")
        let accessToken = try await pollForToken(
            deviceCode: deviceResponse.deviceCode,
            interval: deviceResponse.interval
        )

        Log.info("Copilot OAuth: 获取用户信息")
        let (login, email) = try await fetchUserInfo(accessToken: accessToken)

        let account = OAuthAccount(
            id: "copilot-oauth-\(login)",
            provider: .copilot,
            email: email,
            login: login,
            accessToken: accessToken,
            refreshToken: nil,
            expiresAt: nil,
            projectId: nil,
            isActive: true,
            createdAt: Date()
        )

        try await store.addAccount(account)
        Log.info("Copilot OAuth: 登录成功 login=\(login)")

        return account
    }
}
