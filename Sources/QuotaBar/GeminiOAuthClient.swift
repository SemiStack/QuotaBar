import Foundation
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Google OAuth Token Response

struct GoogleTokenResponse: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?
    let tokenType: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
    }
}

// MARK: - Google UserInfo Response

struct GoogleUserInfoResponse: Decodable, Sendable {
    let email: String?
    let name: String?
    let picture: String?
}

// MARK: - GeminiOAuthClient

struct GeminiOAuthClient: Sendable {
    let session: URLSession

    private static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    private static let userInfoURL = URL(string: "https://www.googleapis.com/oauth2/v1/userinfo?alt=json")!
    private static let loadCodeAssistURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    private static let authBaseURL = "https://accounts.google.com/o/oauth2/v2/auth"
    private static let scopes = [
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile",
    ]

    init(session: URLSession = .shared) {
        self.session = session
    }

    static func generateState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Credential Extraction

    func extractCredentials() async throws -> (clientID: String, clientSecret: String) {
        let jsContent = try await findAndReadOAuth2JS()
        return try parseCredentials(from: jsContent)
    }

    /// Visible for testing: extract credentials from raw JS content.
    static func parseCredentials(from jsContent: String) throws -> (clientID: String, clientSecret: String) {
        let clientSecretPattern = #"GOCSPX-[A-Za-z0-9_-]+"#

        guard let clientSecretRange = jsContent.range(of: clientSecretPattern, options: .regularExpression) else {
            throw AppError("无法从 Gemini CLI 提取 client_secret，请确认已安装 Gemini CLI")
        }
        let clientSecret = String(jsContent[clientSecretRange])

        // Look for the OAUTH_CLIENT_ID variable declaration that pairs with the secret.
        // The bundled JS has multiple googleusercontent.com client_ids; only the one
        // assigned to OAUTH_CLIENT_ID is the correct match for OAUTH_CLIENT_SECRET.
        let oauthVarPattern = #"OAUTH_CLIENT_ID\s*=\s*"(\d+-[a-z0-9]+\.apps\.googleusercontent\.com)""#
        let genericPattern = #"\d+-[a-z0-9]+\.apps\.googleusercontent\.com"#

        let clientID: String
        if let varMatch = jsContent.range(of: oauthVarPattern, options: .regularExpression) {
            // Extract the capture group (the client_id inside the quotes)
            let matched = String(jsContent[varMatch])
            if let innerRange = matched.range(of: genericPattern, options: .regularExpression) {
                clientID = String(matched[innerRange])
            } else {
                throw AppError("无法从 Gemini CLI 提取 client_id，请确认已安装 Gemini CLI")
            }
        } else if let genericRange = jsContent.range(of: genericPattern, options: .regularExpression) {
            // Fallback for legacy format without OAUTH_CLIENT_ID variable
            clientID = String(jsContent[genericRange])
        } else {
            throw AppError("无法从 Gemini CLI 提取 client_id，请确认已安装 Gemini CLI")
        }

        Log.debug("Gemini OAuth: 提取到 client_id=\(clientID.prefix(20))..., secret=GOCSPX-****")
        return (clientID: clientID, clientSecret: clientSecret)
    }

    private func parseCredentials(from jsContent: String) throws -> (clientID: String, clientSecret: String) {
        try Self.parseCredentials(from: jsContent)
    }

    private func findAndReadOAuth2JS() async throws -> String {
        let fm = FileManager.default

        // Candidate paths for the `gemini` binary
        var binaryPaths: [String] = []

        // Try `which gemini`
        if let whichResult = try? runShellCommand("which gemini"),
           !whichResult.isEmpty
        {
            binaryPaths.append(whichResult)
        }

        // Common locations
        binaryPaths.append(contentsOf: [
            "/usr/local/bin/gemini",
            "/opt/homebrew/bin/gemini",
        ])

        // Check ~/.nvm paths
        let home = NSHomeDirectory()
        let nvmDir = "\(home)/.nvm/versions/node"
        if let nodeDirs = try? fm.contentsOfDirectory(atPath: nvmDir) {
            for dir in nodeDirs.sorted().reversed() {
                binaryPaths.append("\(nvmDir)/\(dir)/bin/gemini")
            }
        }

        // npm global
        binaryPaths.append("\(home)/.npm-global/bin/gemini")

        for candidatePath in binaryPaths {
            let resolvedPath = resolveSymlink(candidatePath)
            guard fm.fileExists(atPath: resolvedPath) else { continue }

            let resolvedURL = URL(fileURLWithPath: resolvedPath)
            let candidates = findOAuth2JSCandidates(from: resolvedURL)

            for oauth2Path in candidates {
                if let content = try? String(contentsOfFile: oauth2Path, encoding: .utf8),
                   content.contains("googleusercontent.com")
                {
                    return content
                }
            }
        }

        throw AppError("找不到 Gemini CLI 的 OAuth 配置文件，请先安装：npm install -g @google/gemini-cli")
    }

    private func findOAuth2JSCandidates(from binaryURL: URL) -> [String] {
        var candidates: [String] = []
        let resolvedDir = binaryURL.deletingLastPathComponent()

        // Strategy 1: New bundled format (gemini-cli ≥ 0.3x).
        // Binary resolves into .../bundle/gemini.js — search sibling chunk-*.js files.
        if resolvedDir.lastPathComponent == "bundle" {
            if let files = try? FileManager.default.contentsOfDirectory(atPath: resolvedDir.path) {
                for file in files where file.hasSuffix(".js") {
                    candidates.append(resolvedDir.appendingPathComponent(file).path)
                }
            }
        }

        // Strategy 2: Legacy unbundled layout with gemini-cli-core as a separate package.
        var current = resolvedDir
        for _ in 0 ..< 10 {
            let nodeModulesPath = current
                .appendingPathComponent("node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js")
            candidates.append(nodeModulesPath.path)

            let parentNodeModules = current.deletingLastPathComponent()
                .appendingPathComponent("node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js")
            candidates.append(parentNodeModules.path)

            current = current.deletingLastPathComponent()
        }

        return candidates
    }

    private func resolveSymlink(_ path: String) -> String {
        let fm = FileManager.default
        guard let resolved = try? fm.destinationOfSymbolicLink(atPath: path) else {
            return path
        }
        if resolved.hasPrefix("/") {
            return resolved
        }
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        return dir.appendingPathComponent(resolved).standardized.path
    }

    private func runShellCommand(_ command: String) throws -> String {
        #if canImport(AppKit)
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["sh", "-c", command]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        #else
        return ""
        #endif
    }

    // MARK: - Full Login Flow

    func startLogin(
        store: AccountStore = .shared,
        onOpenBrowser: @escaping @Sendable (URL) -> Void
    ) async throws -> OAuthAccount {
        Log.info("Gemini OAuth: 开始授权码登录流程")

        // 1. Extract credentials
        let (clientID, clientSecret) = try await extractCredentials()
        Log.debug("Gemini OAuth: 已提取客户端凭据")

        // 2. Start callback server
        let server = OAuthCallbackServer()
        let port = try await server.start()
        Log.debug("Gemini OAuth: 回调服务器已启动，端口 \(port)")

        defer {
            Task { await server.stop() }
        }

        let redirectURI = "http://127.0.0.1:\(port)/oauth2callback"
        let state = Self.generateState()

        // 3. Build OAuth URL
        var components = URLComponents(string: Self.authBaseURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let authURL = components.url else {
            throw AppError("Gemini OAuth: 无法构建授权 URL")
        }

        // 4. Open browser
        onOpenBrowser(authURL)

        // 5. Wait for callback
        let code = try await server.waitForCode(expectedState: state)
        Log.info("Gemini OAuth: 已收到授权码")

        // 6. Exchange code for tokens
        let tokenResponse = try await exchangeCode(
            code: code,
            clientID: clientID,
            clientSecret: clientSecret,
            redirectURI: redirectURI
        )
        Log.info("Gemini OAuth: 令牌交换成功")

        // 7. Get user info
        let userInfo = try await fetchUserInfo(accessToken: tokenResponse.accessToken)
        Log.info("Gemini OAuth: 用户信息获取成功 email=\(userInfo.email ?? "nil")")

        // 8. Get project ID via loadCodeAssist
        let codeAssist = try await loadCodeAssist(accessToken: tokenResponse.accessToken)
        let projectID = codeAssist.resolvedProjectID

        // 9. Save account
        let expiresAt: Date?
        if let expiresIn = tokenResponse.expiresIn {
            expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        } else {
            expiresAt = nil
        }

        let accountID = "gemini-oauth-\(userInfo.email ?? UUID().uuidString)"
        let account = OAuthAccount(
            id: accountID,
            provider: .gemini,
            email: userInfo.email,
            login: userInfo.name,
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken,
            expiresAt: expiresAt,
            projectId: projectID,
            isActive: true,
            createdAt: Date()
        )

        try await store.addAccount(account)
        Log.info("Gemini OAuth: 登录成功 id=\(accountID)")

        return account
    }

    // MARK: - Token Exchange

    private func exchangeCode(
        code: String,
        clientID: String,
        clientSecret: String,
        redirectURI: String
    ) async throws -> GoogleTokenResponse {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "client_secret", value: clientSecret),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
        ]
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)

        Log.debug("Gemini OAuth: 令牌交换请求 client_id=\(clientID.prefix(20))... redirect_uri=\(redirectURI)")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError("Gemini 令牌交换失败：无效响应")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "(non-utf8)"
            Log.error("Gemini 令牌交换失败：HTTP \(http.statusCode) body=\(body)")
            throw AppError("Gemini 令牌交换失败：HTTP \(http.statusCode)")
        }

        do {
            return try JSONDecoder().decode(GoogleTokenResponse.self, from: data)
        } catch {
            throw AppError("Gemini 令牌解析失败：\(error.localizedDescription)")
        }
    }

    // MARK: - User Info

    private func fetchUserInfo(accessToken: String) async throws -> GoogleUserInfoResponse {
        var request = URLRequest(url: Self.userInfoURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError("Google 用户信息请求失败：无效响应")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            Log.error("Google 用户信息请求失败：HTTP \(http.statusCode)")
            throw AppError("Google 用户信息请求失败：HTTP \(http.statusCode)")
        }

        do {
            return try JSONDecoder().decode(GoogleUserInfoResponse.self, from: data)
        } catch {
            throw AppError("Google 用户信息解析失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Load CodeAssist

    private func loadCodeAssist(accessToken: String, projectID: String? = nil) async throws -> GeminiCodeAssistResponse {
        var request = URLRequest(url: Self.loadCodeAssistURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = GeminiCodeAssistPayload(projectID: projectID)
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError("Gemini CodeAssist 请求失败：无效响应")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            Log.error("Gemini CodeAssist 请求失败：HTTP \(http.statusCode)")
            throw AppError("Gemini CodeAssist 请求失败：HTTP \(http.statusCode)")
        }

        do {
            return try JSONDecoder().decode(GeminiCodeAssistResponse.self, from: data)
        } catch {
            throw AppError("Gemini CodeAssist 解析失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Token Refresh

    func refreshToken(
        refreshToken: String,
        clientID: String,
        clientSecret: String
    ) async throws -> (accessToken: String, expiresIn: Int?) {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "client_secret", value: clientSecret),
        ]
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError("Gemini 令牌刷新失败：无效响应")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            Log.error("Gemini 令牌刷新失败：HTTP \(http.statusCode)")
            throw AppError("Gemini 令牌刷新失败：HTTP \(http.statusCode)")
        }

        do {
            let tokenResponse = try JSONDecoder().decode(GoogleTokenResponse.self, from: data)
            return (accessToken: tokenResponse.accessToken, expiresIn: tokenResponse.expiresIn)
        } catch {
            throw AppError("Gemini 令牌刷新解析失败：\(error.localizedDescription)")
        }
    }
}

// Payload types are defined in ManagementAPI.swift as GeminiCodeAssistPayload / GeminiQuotaPayload

// MARK: - DirectGeminiClient

/// Single-use client. Create a fresh instance for each polling cycle
/// to pick up the latest token from AccountStore.
struct DirectGeminiClient: Sendable {
    let account: OAuthAccount
    let session: URLSession

    private static let loadCodeAssistURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    private static let quotaURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!
    private static let tokenExpiryBuffer: TimeInterval = 5 * 60

    init(account: OAuthAccount, session: URLSession = .shared) {
        self.account = account
        self.session = session
    }

    func fetchQuotaCard() async throws -> QuotaCard {
        let accessToken = try await ensureValidToken()
        let codeAssist = try await loadCodeAssist(token: accessToken)
        let projectID = account.projectId ?? codeAssist.resolvedProjectID
        guard let projectID, !projectID.isEmpty else {
            throw AppError("Gemini 账号缺少项目标识")
        }
        let quota = try await fetchQuota(token: accessToken, projectID: projectID)
        return GeminiQuotaBuilder.makeCard(
            account: account,
            projectID: projectID,
            codeAssist: codeAssist,
            quota: quota
        )
    }

    // MARK: - Token Management

    private func ensureValidToken() async throws -> String {
        if let expiresAt = account.expiresAt {
            let isExpired = expiresAt.timeIntervalSinceNow < Self.tokenExpiryBuffer
            if isExpired {
                return try await refreshAndUpdateToken()
            }
        }
        return account.accessToken
    }

    private func refreshAndUpdateToken() async throws -> String {
        guard let refreshTokenValue = account.refreshToken else {
            throw AppError("Gemini 账号缺少 refresh_token，请重新登录")
        }

        let oauthClient = GeminiOAuthClient(session: session)
        let (clientID, clientSecret) = try await oauthClient.extractCredentials()

        let (newAccessToken, expiresIn) = try await oauthClient.refreshToken(
            refreshToken: refreshTokenValue,
            clientID: clientID,
            clientSecret: clientSecret
        )

        let newExpiresAt: Date?
        if let expiresIn {
            newExpiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        } else {
            newExpiresAt = nil
        }

        try await AccountStore.shared.updateToken(
            id: account.id,
            accessToken: newAccessToken,
            expiresAt: newExpiresAt
        )

        Log.debug("Gemini OAuth: 令牌已刷新 id=\(account.id)")
        return newAccessToken
    }

    // MARK: - API Calls

    private func loadCodeAssist(token: String) async throws -> GeminiCodeAssistResponse {
        var request = URLRequest(url: Self.loadCodeAssistURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = GeminiCodeAssistPayload(projectID: account.projectId)
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError("Gemini CodeAssist 请求失败：无效响应")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            Log.error("Gemini CodeAssist 请求失败：HTTP \(http.statusCode)")
            throw AppError("Gemini CodeAssist 请求失败：HTTP \(http.statusCode)")
        }

        do {
            return try JSONDecoder().decode(GeminiCodeAssistResponse.self, from: data)
        } catch {
            throw AppError("Gemini CodeAssist 解析失败：\(error.localizedDescription)")
        }
    }

    private func fetchQuota(token: String, projectID: String) async throws -> GeminiQuotaResponse {
        var request = URLRequest(url: Self.quotaURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = GeminiQuotaPayload(projectID: projectID)
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError("Gemini 额度查询失败：无效响应")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            Log.error("Gemini 额度查询失败：HTTP \(http.statusCode)")
            throw AppError("Gemini 额度查询失败：HTTP \(http.statusCode)")
        }

        do {
            return try JSONDecoder().decode(GeminiQuotaResponse.self, from: data)
        } catch {
            throw AppError("Gemini 额度解析失败：\(error.localizedDescription)")
        }
    }
}
