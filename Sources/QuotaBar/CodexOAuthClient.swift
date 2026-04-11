import CommonCrypto
import Foundation
@preconcurrency import Network
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Codex Token Response

private struct CodexTokenResponse: Decodable, Sendable {
    let idToken: String?
    let accessToken: String?
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

// MARK: - Codex Refresh Token Response

private struct CodexRefreshResponse: Decodable, Sendable {
    let accessToken: String
    let idToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case idToken = "id_token"
    }
}

// MARK: - CodexOAuthClient (Browser Auth Code + PKCE)

struct CodexOAuthClient: Sendable {
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let authorizeURL = "https://auth.openai.com/oauth/authorize"
    private static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    private static let scope = "openid profile email offline_access api.connectors.read api.connectors.invoke"
    private static let callbackPath = "/auth/callback"
    /// OpenAI requires a fixed registered redirect_uri port
    static let callbackPort: UInt16 = 1455

    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - PKCE

    struct PKCEPair: Sendable {
        let codeVerifier: String
        let codeChallenge: String
    }

    static func generatePKCE() -> PKCEPair {
        let verifier = generateCodeVerifier()
        let challenge = computeCodeChallenge(verifier)
        return PKCEPair(codeVerifier: verifier, codeChallenge: challenge)
    }

    private static func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// 生成 OAuth state 参数（32 字节随机 base64url，匹配官方 CLI）
    static func generateState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func computeCodeChallenge(_ verifier: String) -> String {
        let data = Data(verifier.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        _ = data.withUnsafeBytes { CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash) }
        return Data(hash)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Step 1: Build Authorization URL

    func buildAuthorizeURL(port: Int, pkce: PKCEPair, state: String) -> URL {
        let redirectURI = "http://localhost:\(port)\(Self.callbackPath)"
        var components = URLComponents(string: Self.authorizeURL)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: pkce.codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "originator", value: "QuotaBar"),
        ]
        return components.url!
    }

    // MARK: - Step 2: Exchange Code for Token

    func exchangeToken(code: String, port: Int, codeVerifier: String) async throws -> (accessToken: String, refreshToken: String?, idToken: String?, chatgptAccountId: String?) {
        let redirectURI = "http://localhost:\(port)\(Self.callbackPath)"

        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let params = [
            "grant_type": "authorization_code",
            "client_id": Self.clientID,
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": codeVerifier,
        ]
        request.httpBody = Data(params.urlEncoded.utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            Log.error("Codex token exchange failed: HTTP \(statusCode) body=\(body)")
            throw AppError("Codex Token 交换失败：HTTP \(statusCode)")
        }

        let tokenResponse = try JSONDecoder().decode(CodexTokenResponse.self, from: data)
        guard let accessToken = tokenResponse.accessToken else {
            throw AppError("Codex Token 响应缺少 access_token")
        }

        let accountId = tokenResponse.idToken.flatMap { Self.extractChatGPTAccountId(from: $0) }
        return (accessToken: accessToken, refreshToken: tokenResponse.refreshToken, idToken: tokenResponse.idToken, chatgptAccountId: accountId)
    }

    // MARK: - Refresh Token

    func refreshAccessToken(refreshToken: String) async throws -> (accessToken: String, chatgptAccountId: String?) {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let params = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID,
        ]
        request.httpBody = Data(params.urlEncoded.utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw AppError("Codex Token 刷新失败：HTTP \(statusCode)")
        }

        let refreshResponse = try JSONDecoder().decode(CodexRefreshResponse.self, from: data)
        let accountId = refreshResponse.idToken.flatMap { Self.extractChatGPTAccountId(from: $0) }
        return (accessToken: refreshResponse.accessToken, chatgptAccountId: accountId)
    }

    // MARK: - JWT Helpers

    static func extractChatGPTAccountId(from idToken: String) -> String? {
        guard let json = decodeJWTPayload(idToken) else { return nil }
        if let auth = json["https://api.openai.com/auth"] as? [String: Any],
           let accountId = auth["chatgpt_account_id"] as? String
        {
            return accountId
        }
        return nil
    }

    static func extractEmail(from jwt: String) -> String? {
        guard let json = decodeJWTPayload(jwt) else { return nil }
        // Top-level email (id_token format)
        if let email = json["email"] as? String { return email }
        // Nested OpenAI profile (access_token format)
        if let profile = json["https://api.openai.com/profile"] as? [String: Any],
           let email = profile["email"] as? String
        { return email }
        return nil
    }

    static func extractName(from jwt: String) -> String? {
        guard let json = decodeJWTPayload(jwt) else { return nil }
        if let name = json["name"] as? String { return name }
        if let profile = json["https://api.openai.com/profile"] as? [String: Any],
           let name = profile["name"] as? String
        { return name }
        return nil
    }

    private static func decodeJWTPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        var base64 = String(parts[1])
        let remainder = base64.count % 4
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        base64 = base64.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    // MARK: - Full Login Flow (Browser-based)

    func startLogin(store: AccountStore = .shared) async throws -> OAuthAccount {
        Log.info("Codex OAuth: 开始浏览器授权码登录")

        let pkce = Self.generatePKCE()
        let state = Self.generateState()

        let callbackServer = OAuthCallbackServer()
        let port = try await callbackServer.start(port: NWEndpoint.Port(rawValue: Self.callbackPort)!)
        let authorizeURL = buildAuthorizeURL(port: port, pkce: pkce, state: state)

        Log.info("Codex OAuth: 打开授权页面 \(authorizeURL.absoluteString)")
        #if canImport(AppKit)
        await MainActor.run { NSWorkspace.shared.open(authorizeURL) }
        #endif

        let code = try await callbackServer.waitForCode(expectedState: state)
        Log.info("Codex OAuth: 收到授权码")

        let (accessToken, refreshToken, idToken, chatgptAccountId) = try await exchangeToken(
            code: code,
            port: port,
            codeVerifier: pkce.codeVerifier
        )

        // Extract email and name from id_token JWT (the actual identity token, not the access token)
        let email = idToken.flatMap { Self.extractEmail(from: $0) }
        let name = idToken.flatMap { Self.extractName(from: $0) }
        let displayLogin = name ?? email ?? "codex-user"

        let account = OAuthAccount(
            id: "codex-oauth-\(displayLogin)",
            provider: .codex,
            email: email,
            login: displayLogin,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: nil,
            projectId: chatgptAccountId,
            isActive: true,
            createdAt: Date()
        )

        try await store.addAccount(account)
        Log.info("Codex OAuth: 登录成功 login=\(displayLogin)")

        return account
    }
}

// MARK: - DirectCodexClient

struct DirectCodexClient: Sendable {
    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private let account: OAuthAccount
    private let session: URLSession

    init(account: OAuthAccount, session: URLSession = .shared) {
        self.account = account
        self.session = session
    }

    func fetchQuotaCard() async throws -> QuotaCard {
        var currentToken = account.accessToken

        // Refresh token if we have a refresh token
        if let refreshToken = account.refreshToken {
            do {
                let client = CodexOAuthClient(session: session)
                let (newToken, _) = try await client.refreshAccessToken(refreshToken: refreshToken)
                currentToken = newToken
                try? await AccountStore.shared.updateToken(
                    id: account.id,
                    accessToken: newToken,
                    expiresAt: nil
                )
            } catch {
                Log.error("Codex token refresh failed for \(account.id): \(error.localizedDescription)")
            }
        }

        // Self-correct: if login looks like a UUID, extract real name from JWT
        let correctedName = await selfCorrectAccountName(token: currentToken)

        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(currentToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("codex_cli_rs/0.76.0 (Debian 13.0.0; x86_64) WindowsTerminal", forHTTPHeaderField: "User-Agent")

        if let accountId = account.projectId {
            request.setValue(accountId, forHTTPHeaderField: "Chatgpt-Account-Id")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError("Codex 额度请求失败：无效响应")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw AppError("Codex 额度请求失败：HTTP \(http.statusCode)")
        }

        let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
        return makeCard(usage: usage, correctedName: correctedName)
    }

    private func makeCard(usage: CodexUsageResponse, correctedName: String?) -> QuotaCard {
        let plan = displayPlan(for: usage.planType)
        var rows = [QuotaWindowRow]()

        CodexQuotaBuilder.appendLimitRowsForDirect(
            into: &rows,
            primaryLabel: "5 小时限额",
            secondaryLabel: "周限额",
            limit: usage.rateLimit,
            keyPrefix: "usage"
        )

        if let extras = usage.additionalRateLimits {
            for (index, extra) in extras.enumerated() {
                let name = (extra.limitName ?? extra.meteredFeature ?? "additional-\(index + 1)")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                CodexQuotaBuilder.appendLimitRowsForDirect(
                    into: &rows,
                    primaryLabel: "\(name) 5 小时限额",
                    secondaryLabel: "\(name) 周限额",
                    limit: extra.rateLimit,
                    keyPrefix: "extra-\(index)"
                )
            }
        }

        let displayTitle = correctedName ?? account.login ?? account.email ?? account.id
        return QuotaCard(
            id: "codex-oauth-\(account.id)",
            provider: .codex,
            title: displayTitle,
            subtitle: nil,
            planLabel: plan,
            windows: rows,
            errorMessage: nil,
            accountId: account.id,
            isActiveAccount: account.isActive
        )
    }

    private func displayPlan(for rawPlan: String?) -> String {
        switch rawPlan?.lowercased() {
        case "plus": return "Plus"
        case "team": return "Team"
        case "free": return "Free"
        case let value? where !value.isEmpty: return value.capitalized
        default: return "未知"
        }
    }

    /// If the stored login looks like a UUID, try to extract real email from the JWT access token.
    /// Returns the corrected name for immediate use in display.
    private func selfCorrectAccountName(token: String) async -> String? {
        let login = account.login ?? ""
        let uuidPattern = #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#
        guard login.range(of: uuidPattern, options: .regularExpression) != nil else { return nil }

        let email = CodexOAuthClient.extractEmail(from: token)
        let name = CodexOAuthClient.extractName(from: token)
        let betterLogin = name ?? email
        guard let betterLogin else { return nil }

        Log.info("Codex: migrating display name from UUID to \(betterLogin)")
        try? await AccountStore.shared.updateAccountInfo(
            id: account.id,
            login: betterLogin,
            email: email
        )
        return betterLogin
    }
}

// MARK: - URL encoding helper

private extension Dictionary where Key == String, Value == String {
    var urlEncoded: String {
        map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
    }
}
