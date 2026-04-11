import CommonCrypto
import Foundation
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Claude OAuth Token Response

private struct ClaudeTokenResponse: Decodable, Sendable {
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

// MARK: - Claude Roles Response

private struct ClaudeRolesResponse: Decodable, Sendable {
    let organizationUuid: String?
    let organizationName: String?
    let organizationRole: String?

    enum CodingKeys: String, CodingKey {
        case organizationUuid = "organization_uuid"
        case organizationName = "organization_name"
        case organizationRole = "organization_role"
    }

    /// Extract email from org name like "user@example.com's Organization"
    var inferredEmail: String? {
        guard let name = organizationName else { return nil }
        let suffixes = ["'s Organization", "'s Organization", "的组织"]
        for suffix in suffixes {
            if name.hasSuffix(suffix) {
                let email = String(name.dropLast(suffix.count))
                if email.contains("@") { return email }
            }
        }
        return nil
    }
}

// MARK: - ClaudeOAuthClient

struct ClaudeOAuthClient: Sendable {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let authorizeURL = "https://claude.com/cai/oauth/authorize"
    private static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let rolesURL = URL(string: "https://api.anthropic.com/api/oauth/claude_cli/roles")!
    private static let callbackPath = "/callback"

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

    /// 生成 OAuth state 参数（32 字节随机 base64url）
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
            URLQueryItem(name: "code_challenge", value: pkce.codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"),
        ]
        return components.url!
    }

    // MARK: - Step 2: Exchange Code for Token

    func exchangeToken(code: String, port: Int, codeVerifier: String, state: String) async throws -> (accessToken: String, refreshToken: String?, expiresIn: Int?) {
        let redirectURI = "http://localhost:\(port)\(Self.callbackPath)"

        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": Self.clientID,
            "code_verifier": codeVerifier,
            "state": state,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            Log.error("Claude token exchange failed: HTTP \(statusCode) body=\(responseBody)")
            throw AppError("Claude Token 交换失败：HTTP \(statusCode)")
        }

        let tokenResponse = try JSONDecoder().decode(ClaudeTokenResponse.self, from: data)
        return (accessToken: tokenResponse.accessToken, refreshToken: tokenResponse.refreshToken, expiresIn: tokenResponse.expiresIn)
    }

    // MARK: - Step 3: Fetch User Info (Roles)

    func fetchRoles(accessToken: String) async throws -> (email: String?, name: String?, orgId: String?, orgName: String?) {
        var request = URLRequest(url: Self.rolesURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            Log.error("Claude roles fetch failed: HTTP \(statusCode) body=\(body)")
            return (email: nil, name: nil, orgId: nil, orgName: nil)
        }

        let roles = try JSONDecoder().decode(ClaudeRolesResponse.self, from: data)
        let email = roles.inferredEmail
        Log.info("Claude roles: orgName=\(roles.organizationName ?? "nil") email=\(email ?? "nil") orgId=\(roles.organizationUuid ?? "nil")")
        return (email: email, name: nil, orgId: roles.organizationUuid, orgName: roles.organizationName)
    }

    // MARK: - Refresh Token

    func refreshAccessToken(refreshToken: String) async throws -> (accessToken: String, newRefreshToken: String?, expiresIn: Int?) {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID,
            "scope": "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw AppError("Claude Token 刷新失败：HTTP \(statusCode)")
        }

        let tokenResponse = try JSONDecoder().decode(ClaudeTokenResponse.self, from: data)
        return (accessToken: tokenResponse.accessToken, newRefreshToken: tokenResponse.refreshToken, expiresIn: tokenResponse.expiresIn)
    }

    // MARK: - Full Login Flow

    func startLogin(
        store: AccountStore = .shared
    ) async throws -> OAuthAccount {
        Log.info("Claude OAuth: 开始授权码登录")

        let pkce = Self.generatePKCE()
        let state = Self.generateState()

        let callbackServer = OAuthCallbackServer()
        let port = try await callbackServer.start()
        let authorizeURL = buildAuthorizeURL(port: port, pkce: pkce, state: state)

        Log.info("Claude OAuth: 打开授权页面 \(authorizeURL.absoluteString)")
        #if canImport(AppKit)
        await MainActor.run { NSWorkspace.shared.open(authorizeURL) }
        #endif

        let code = try await callbackServer.waitForCode(expectedState: state)
        Log.info("Claude OAuth: 收到授权码")

        let (accessToken, refreshToken, expiresIn) = try await exchangeToken(
            code: code,
            port: port,
            codeVerifier: pkce.codeVerifier,
            state: state
        )

        let expiresAt = expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }

        // Fetch user info
        let (email, name, orgId, _) = try await fetchRoles(accessToken: accessToken)
        let displayLogin = name ?? email ?? "claude-user"

        let account = OAuthAccount(
            id: "claude-oauth-\(displayLogin)",
            provider: .claude,
            email: email,
            login: displayLogin,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            projectId: orgId,
            isActive: true,
            createdAt: Date()
        )

        try await store.addAccount(account)
        Log.info("Claude OAuth: 登录成功 login=\(displayLogin)")

        return account
    }
}

// MARK: - DirectClaudeClient

struct DirectClaudeClient: Sendable {
    private let account: OAuthAccount
    private let session: URLSession
    private let baseURL = URL(string: "https://claude.ai/api")!
    private let decoder = JSONDecoder()

    init(account: OAuthAccount, session: URLSession = .shared) {
        self.account = account
        self.session = session
    }

    func fetchQuotaCard() async throws -> QuotaCard {
        var currentToken = account.accessToken

        // Refresh token if we have one
        if let refreshToken = account.refreshToken {
            do {
                let client = ClaudeOAuthClient(session: session)
                let (newToken, newRefresh, expiresIn) = try await client.refreshAccessToken(refreshToken: refreshToken)
                currentToken = newToken
                let expiresAt = expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
                try? await AccountStore.shared.updateToken(
                    id: account.id,
                    accessToken: newToken,
                    expiresAt: expiresAt
                )
                if let newRefresh {
                    try? await AccountStore.shared.updateRefreshToken(id: account.id, refreshToken: newRefresh)
                }

                // Self-correct: if login is "claude-user", fetch real name
                await selfCorrectAccountName(token: newToken)
            } catch {
                Log.error("Claude token refresh failed for \(account.id): \(error.localizedDescription)")
            }
        }

        // Fetch org info from roles endpoint (works with OAuth tokens)
        let client = ClaudeOAuthClient(session: session)
        let (email, _, orgId, orgName) = try await client.fetchRoles(accessToken: currentToken)

        // Try to fetch usage from claude.ai/api (may fail due to Cloudflare)
        var usage: ClaudeWebUsageResponse?
        var accountInfo: ClaudeAccountResponse?
        if let orgId {
            do {
                let organizations: [ClaudeOrganizationResponse] = try await perform(path: "organizations", token: currentToken)
                if let org = selectOrganization(organizations, preferredOrgID: orgId) {
                    async let usageTask: ClaudeWebUsageResponse = perform(
                        path: "organizations/\(org.uuid)/usage",
                        token: currentToken
                    )
                    async let accountTask: ClaudeAccountResponse? = fetchAccount(token: currentToken)
                    usage = try? await usageTask
                    accountInfo = await accountTask
                }
            } catch {
                Log.debug("Claude web API unavailable (expected with OAuth tokens): \(error.localizedDescription)")
            }
        }

        let displayEmail = email ?? accountInfo?.emailAddress ?? account.email
        let displayLogin = account.login ?? displayEmail ?? account.id

        // Fallback: try local Claude Desktop session if OAuth couldn't get usage
        if usage == nil {
            do {
                let desktopClient = ClaudeDesktopUsageClient()
                let desktopCard = try await desktopClient.fetchQuotaCard()
                Log.info("Claude: 本地桌面会话回退成功")
                return QuotaCard(
                    id: "claude-oauth-\(account.id)",
                    provider: .claude,
                    title: displayEmail ?? displayLogin,
                    subtitle: orgName,
                    planLabel: desktopCard.planLabel,
                    windows: desktopCard.windows,
                    errorMessage: nil,
                    accountId: account.id,
                    isActiveAccount: account.isActive
                )
            } catch {
                Log.debug("Claude 本地桌面会话回退失败: \(error.localizedDescription)")
            }
        }

        if let usage {
            // Full card with usage data
            let rows = [
                makeRow(id: "claude-5h", label: "当前会话", bucket: usage.fiveHour),
                makeRow(id: "claude-week", label: "当周", bucket: usage.sevenDay),
            ].compactMap { $0 }

            return QuotaCard(
                id: "claude-oauth-\(account.id)",
                provider: .claude,
                title: displayEmail ?? displayLogin,
                subtitle: orgName,
                planLabel: "",
                windows: rows,
                errorMessage: nil,
                accountId: account.id,
                isActiveAccount: account.isActive
            )
        } else {
            // Limited card: no usage data available (OAuth tokens can't access claude.ai/api)
            return QuotaCard(
                id: "claude-oauth-\(account.id)",
                provider: .claude,
                title: displayEmail ?? displayLogin,
                subtitle: orgName,
                planLabel: "",
                windows: [],
                errorMessage: "用量数据暂不可用（OAuth 限制）",
                accountId: account.id,
                isActiveAccount: account.isActive
            )
        }
    }

    private func perform<T: Decodable>(path: String, token: String) async throws -> T {
        let requestURL = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // claude.ai/api uses cookie-based auth; try both Cookie and Bearer
        request.setValue("sessionKey=\(token)", forHTTPHeaderField: "Cookie")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeDesktopError.invalidResponse
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            Log.error("Claude API \(path) failed: HTTP \(httpResponse.statusCode) body=\(body ?? "nil")")
            throw ClaudeDesktopError.httpError(statusCode: httpResponse.statusCode, body: body)
        }

        return try decoder.decode(T.self, from: data)
    }

    private func fetchAccount(token: String) async -> ClaudeAccountResponse? {
        do {
            return try await perform(path: "account", token: token)
        } catch {
            Log.debug("Claude account endpoint failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func selectOrganization(
        _ organizations: [ClaudeOrganizationResponse],
        preferredOrgID: String?
    ) -> ClaudeOrganizationResponse? {
        if let preferredOrgID = preferredOrgID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !preferredOrgID.isEmpty,
           let preferred = organizations.first(where: { $0.uuid.lowercased() == preferredOrgID })
        {
            return preferred
        }
        return organizations.first(where: { $0.hasChatCapability })
            ?? organizations.first(where: { !$0.isAPIOnly })
            ?? organizations.first
    }

    private func selectMembership(
        _ memberships: [ClaudeAccountResponse.Membership]?,
        orgID: String
    ) -> ClaudeAccountResponse.Membership? {
        guard let memberships else { return nil }
        return memberships.first(where: { $0.organization.uuid?.lowercased() == orgID.lowercased() })
            ?? memberships.first
    }

    private func makeRow(id: String, label: String, bucket: ClaudeUsageBucket?) -> QuotaWindowRow? {
        guard let bucket else { return nil }
        let usedPercent = bucket.utilization.map { $0 * 100 }
        let remaining = usedPercent.map { max(0, min(100, Int(round(100 - $0)))) }

        var resetLabel = "-"
        if let resetsAt = bucket.resetsAt {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: resetsAt) ?? ISO8601DateFormatter().date(from: resetsAt) {
                let style = Date.FormatStyle()
                    .month(.twoDigits)
                    .day(.twoDigits)
                    .hour(.twoDigits(amPM: .omitted))
                    .minute(.twoDigits)
                    .locale(Locale(identifier: "zh_CN"))
                resetLabel = date.formatted(style)
            }
        }

        return QuotaWindowRow(id: id, label: label, remainingPercent: remaining, resetLabel: resetLabel)
    }

    /// If the stored login is "claude-user", fetch real name/email from the roles endpoint.
    private func selfCorrectAccountName(token: String) async {
        let login = account.login ?? ""
        guard login == "claude-user" || login.isEmpty else { return }

        do {
            let client = ClaudeOAuthClient(session: session)
            let (email, name, _, _) = try await client.fetchRoles(accessToken: token)
            let betterLogin = name ?? email
            guard let betterLogin, betterLogin != "claude-user" else { return }

            Log.info("Claude: migrating display name from '\(login)' to \(betterLogin)")
            try? await AccountStore.shared.updateAccountInfo(
                id: account.id,
                login: betterLogin,
                email: email
            )
        } catch {
            Log.debug("Claude self-correct name failed: \(error.localizedDescription)")
        }
    }
}
