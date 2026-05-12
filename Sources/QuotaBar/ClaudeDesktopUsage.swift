import CommonCrypto
import Foundation
import Security
import SQLite3

struct ClaudeDesktopUsageClient: Sendable {
    private let session: URLSession
    private let decoder = JSONDecoder()

    private let baseURL = URL(string: "https://claude.ai/api")!

    init(session: URLSession = ClaudeDesktopUsageClient.makeSession()) {
        self.session = session
    }

    static func isDesktopSessionAvailable() async -> Bool {
        await Task.detached(priority: .utility) {
            (try? ClaudeDesktopAuthStore().loadSession()) != nil
        }.value
    }

    func fetchQuotaCard() async throws -> QuotaCard {
        let desktopSession = try await Task.detached(priority: .utility) {
            try ClaudeDesktopAuthStore().loadSession()
        }.value
        return try await fetchQuotaCard(session: desktopSession)
    }

    func fetchQuotaCard(session: ClaudeDesktopSession) async throws -> QuotaCard {
        let organizations: [ClaudeOrganizationResponse] = try await perform(path: "organizations", sessionKey: session.sessionKey)

        guard let organization = ClaudeDesktopUsageClient.selectOrganization(
            organizations,
            preferredOrgID: session.lastActiveOrgID
        ) else {
            throw ClaudeDesktopError.noOrganization
        }

        async let usageTask: ClaudeWebUsageResponse = perform(
            path: "organizations/\(organization.uuid)/usage",
            sessionKey: session.sessionKey
        )
        async let accountTask: ClaudeAccountResponse? = fetchAccount(sessionKey: session.sessionKey)

        let usage = try await usageTask
        let account = try await accountTask
        let membership = ClaudeDesktopUsageClient.selectMembership(account?.memberships, orgID: organization.uuid)

        return ClaudeQuotaBuilder.makeCard(
            session: session,
            organization: organization,
            membership: membership,
            account: account,
            usage: usage
        )
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration)
    }

    private func fetchAccount(sessionKey: String) async throws -> ClaudeAccountResponse? {
        do {
            return try await perform(path: "account", sessionKey: sessionKey)
        } catch let error as ClaudeDesktopError {
            switch error {
            case .httpError, .invalidResponse, .invalidUsagePayload:
                Log.debug("Claude account 接口读取失败：\(error.localizedDescription)")
                return nil
            default:
                throw error
            }
        }
    }

    private func perform<T: Decodable>(path: String, sessionKey: String) async throws -> T {
        let requestURL = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeDesktopError.invalidResponse
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            throw ClaudeDesktopError.httpError(statusCode: httpResponse.statusCode, body: body)
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw ClaudeDesktopError.invalidUsagePayload(error.localizedDescription)
        }
    }

    private static func selectOrganization(
        _ organizations: [ClaudeOrganizationResponse],
        preferredOrgID: String?
    ) -> ClaudeOrganizationResponse? {
        if let preferredOrgID = normalizedIdentifier(preferredOrgID),
           let preferred = organizations.first(where: { normalizedIdentifier($0.uuid) == preferredOrgID }) {
            return preferred
        }

        return organizations.first(where: { $0.hasChatCapability })
            ?? organizations.first(where: { !$0.isAPIOnly })
            ?? organizations.first
    }

    private static func selectMembership(
        _ memberships: [ClaudeAccountResponse.Membership]?,
        orgID: String
    ) -> ClaudeAccountResponse.Membership? {
        guard let memberships else { return nil }
        return memberships.first(where: { normalizedIdentifier($0.organization.uuid) == normalizedIdentifier(orgID) })
            ?? memberships.first
    }

    private static func normalizedIdentifier(_ value: String?) -> String? {
        value?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' \n\r\t"))
            .lowercased()
    }
}

struct ClaudeDesktopSession: Sendable {
    let sessionKey: String
    let lastActiveOrgID: String?
}

struct ClaudeDesktopAuthStore: Sendable {
    private let cookiesURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/Claude/Cookies")
    private let safeStorageService = "Claude Safe Storage"
    private let safeStorageAccount = "Claude Key"

    func loadSession() throws -> ClaudeDesktopSession {
        guard FileManager.default.fileExists(atPath: cookiesURL.path) else {
            throw ClaudeDesktopError.cookiesDatabaseMissing
        }

        let password = try loadSafeStoragePassword()
        let key = deriveKey(from: password)
        let cookies = try loadClaudeCookieValues(using: key)

        guard let sessionKey = sanitizedCookieValue(cookies["sessionKey"]), !sessionKey.isEmpty else {
            throw ClaudeDesktopError.sessionUnavailable
        }

        return ClaudeDesktopSession(
            sessionKey: sessionKey,
            lastActiveOrgID: sanitizedCookieValue(cookies["lastActiveOrg"])
        )
    }

    private func loadSafeStoragePassword() throws -> String {
        // Skip keychain in test environment to avoid blocking dialogs
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil {
            throw ClaudeDesktopError.safeStorageKeyUnavailable
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: safeStorageService,
            kSecAttrAccount as String: safeStorageAccount,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw ClaudeDesktopError.safeStorageKeyUnavailable
        }
        return password
    }

    private func deriveKey(from password: String) -> Data {
        let salt = Data("saltysalt".utf8)
        var key = Data(count: kCCKeySizeAES128)
        let keyLength = key.count

        _ = key.withUnsafeMutableBytes { keyBytes in
            password.utf8CString.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress,
                        passwordBytes.count - 1,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        keyBytes.bindMemory(to: UInt8.self).baseAddress,
                        keyLength
                    )
                }
            }
        }

        return key
    }

    private func loadClaudeCookieValues(using key: Data) throws -> [String: String] {
        try withCopiedCookiesDatabase { copiedDatabaseURL in
            var database: OpaquePointer?
            guard sqlite3_open_v2(copiedDatabaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
                  let database else {
                throw ClaudeDesktopError.cookiesDatabaseOpenFailed
            }
            defer { sqlite3_close(database) }

            let sql = """
            SELECT name, value, encrypted_value
            FROM cookies
            WHERE host_key LIKE '%claude.ai%' AND name IN ('sessionKey', 'lastActiveOrg')
            ORDER BY last_access_utc DESC
            """

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                throw ClaudeDesktopError.cookiesQueryFailed
            }
            defer { sqlite3_finalize(statement) }

            var values = [String: String]()

            while sqlite3_step(statement) == SQLITE_ROW {
                guard let name = sqliteColumnString(statement, index: 0) else { continue }
                if values[name] != nil {
                    continue
                }

                let rawValue = sqliteColumnString(statement, index: 1)
                let encryptedValue = sqliteColumnBlob(statement, index: 2)
                let decrypted = decryptCookieValue(rawValue: rawValue, encryptedValue: encryptedValue, key: key)
                if let decrypted, !decrypted.isEmpty {
                    values[name] = decrypted
                }
            }

            return values
        }
    }

    private func withCopiedCookiesDatabase<T>(_ body: (URL) throws -> T) throws -> T {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "QuotaBar-ClaudeCookies-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true, attributes: nil)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let copiedDatabaseURL = tempDirectory.appendingPathComponent(cookiesURL.lastPathComponent)
        try fileManager.copyItem(at: cookiesURL, to: copiedDatabaseURL)

        for suffix in ["-wal", "-shm"] {
            let source = URL(fileURLWithPath: cookiesURL.path + suffix)
            let destination = URL(fileURLWithPath: copiedDatabaseURL.path + suffix)
            if fileManager.fileExists(atPath: source.path) {
                try? fileManager.copyItem(at: source, to: destination)
            }
        }

        return try body(copiedDatabaseURL)
    }

    private func decryptCookieValue(rawValue: String?, encryptedValue: Data, key: Data) -> String? {
        if let rawValue = sanitizedCookieValue(rawValue), !rawValue.isEmpty {
            return rawValue
        }

        guard encryptedValue.count > 3,
              String(data: encryptedValue.prefix(3), encoding: .utf8) == "v10" else {
            return nil
        }

        let payload = Data(encryptedValue.dropFirst(3))
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var outLength = 0
        var out = Data(count: payload.count + kCCBlockSizeAES128)
        let outCapacity = out.count

        let status = out.withUnsafeMutableBytes { outBytes in
            payload.withUnsafeBytes { payloadBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            payloadBytes.baseAddress,
                            payload.count,
                            outBytes.baseAddress,
                            outCapacity,
                            &outLength
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else { return nil }
        out.count = outLength

        if let direct = sanitizedCookieValue(String(data: out, encoding: .utf8)), !direct.isEmpty {
            return direct
        }

        guard out.count > 32 else { return nil }
        let trimmed = Data(out.dropFirst(32))
        return sanitizedCookieValue(String(data: trimmed, encoding: .utf8))
    }

    private func sanitizedCookieValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \n\r\t")),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func sqliteColumnString(_ statement: OpaquePointer, index: Int32) -> String? {
        guard let rawText = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: rawText)
    }

    private func sqliteColumnBlob(_ statement: OpaquePointer, index: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let rawBlob = sqlite3_column_blob(statement, index) else {
            return Data()
        }
        return Data(bytes: rawBlob, count: count)
    }
}

enum ClaudeDesktopError: LocalizedError, Sendable {
    case cookiesDatabaseMissing
    case safeStorageKeyUnavailable
    case cookiesDatabaseOpenFailed
    case cookiesQueryFailed
    case sessionUnavailable
    case noOrganization
    case invalidResponse
    case invalidUsagePayload(String)
    case httpError(statusCode: Int, body: String?)

    var errorDescription: String? {
        switch self {
        case .cookiesDatabaseMissing:
            return "没有找到 Claude 官方 App 的 Cookies 数据库。"
        case .safeStorageKeyUnavailable:
            return "无法读取 Claude Safe Storage，暂时不能解密登录态。"
        case .cookiesDatabaseOpenFailed:
            return "Claude Cookies 数据库无法打开。"
        case .cookiesQueryFailed:
            return "Claude Cookies 数据库查询失败。"
        case .sessionUnavailable:
            return "没有找到可用的 Claude sessionKey，请先在官方 App 里登录。"
        case .noOrganization:
            return "当前 Claude 账号没有可用的组织信息。"
        case .invalidResponse:
            return "Claude 接口没有返回有效响应。"
        case let .invalidUsagePayload(reason):
            return "Claude 返回的数据格式无法识别：\(reason)"
        case let .httpError(statusCode, body):
            let detail = body?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(140) ?? ""
            if detail.isEmpty {
                return "Claude 接口请求失败，状态码 \(statusCode)。"
            }
            return "Claude 接口请求失败，状态码 \(statusCode)：\(detail)"
        }
    }
}

struct ClaudeOrganizationResponse: Decodable, Sendable {
    let uuid: String
    let name: String?
    let capabilities: [String]?
    let rateLimitTier: String?
    let billingType: String?

    enum CodingKeys: String, CodingKey {
        case uuid
        case name
        case capabilities
        case rateLimitTier = "rate_limit_tier"
        case billingType = "billing_type"
    }

    var normalizedCapabilities: Set<String> {
        Set((capabilities ?? []).map { $0.lowercased() })
    }

    var hasChatCapability: Bool {
        normalizedCapabilities.contains("chat")
    }

    var isAPIOnly: Bool {
        let normalizedCapabilities = normalizedCapabilities
        return !normalizedCapabilities.isEmpty && normalizedCapabilities == ["api"]
    }
}

struct ClaudeWebUsageResponse: Decodable, Sendable {
    let fiveHour: ClaudeUsageBucket?
    let sevenDay: ClaudeUsageBucket?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

struct ClaudeUsageBucket: Decodable, Sendable {
    let utilization: Double?
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

struct ClaudeAccountResponse: Decodable, Sendable {
    let emailAddress: String?
    let memberships: [Membership]?

    enum CodingKeys: String, CodingKey {
        case emailAddress = "email_address"
        case memberships
    }

    struct Membership: Decodable, Sendable {
        let organization: Organization

        struct Organization: Decodable, Sendable {
            let uuid: String?
            let name: String?
            let rateLimitTier: String?
            let billingType: String?
            let capabilities: [String]?

            enum CodingKeys: String, CodingKey {
                case uuid
                case name
                case rateLimitTier = "rate_limit_tier"
                case billingType = "billing_type"
                case capabilities
            }
        }
    }
}

enum ClaudeQuotaBuilder {
    private static let resetLabelStyle = Date.FormatStyle()
        .month(.twoDigits)
        .day(.twoDigits)
        .hour(.twoDigits(amPM: .omitted))
        .minute(.twoDigits)
        .locale(Locale(identifier: "zh_CN"))

    static func makeCard(
        session: ClaudeDesktopSession,
        organization: ClaudeOrganizationResponse,
        membership: ClaudeAccountResponse.Membership?,
        account: ClaudeAccountResponse?,
        usage: ClaudeWebUsageResponse
    ) -> QuotaCard {
        let email = normalized(account?.emailAddress)
        let organizationName = normalized(membership?.organization.name) ?? normalized(organization.name)
        let rateLimitTier = membership?.organization.rateLimitTier ?? organization.rateLimitTier
        let billingType = membership?.organization.billingType ?? organization.billingType
        let capabilities = membership?.organization.capabilities ?? organization.capabilities

        let rows = [
            makeRow(id: "claude-session", label: "当前会话", bucket: usage.fiveHour),
            makeRow(id: "claude-week", label: "当周", bucket: usage.sevenDay),
        ].compactMap { $0 }

        return QuotaCard(
            id: email ?? session.lastActiveOrgID ?? "claude-desktop",
            provider: .claude,
            title: email ?? organizationName ?? "Claude 官方 App",
            subtitle: subtitle(email: email, organizationName: organizationName),
            planLabel: displayPlan(rateLimitTier: rateLimitTier, billingType: billingType, capabilities: capabilities),
            windows: rows,
            errorMessage: nil
        )
    }

    static func makeErrorCard(error: Error) -> QuotaCard {
        let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return QuotaCard(
            id: "claude-desktop-error",
            provider: .claude,
            title: "Claude 官方 App",
            subtitle: "读取失败",
            planLabel: "错误",
            windows: [],
            errorMessage: description
        )
    }

    static func displayPlan(rateLimitTier: String?, billingType: String?, capabilities: [String]?) -> String {
        let tier = normalized(rateLimitTier)?.lowercased() ?? ""
        let billing = normalized(billingType)?.lowercased() ?? ""
        let normalizedCapabilities = Set((capabilities ?? []).map { $0.lowercased() })

        if tier.contains("max") || normalizedCapabilities.contains("claude_max") || normalizedCapabilities.contains("max") {
            return "Max"
        }
        if tier.contains("team") || billing.contains("team") || normalizedCapabilities.contains("team") {
            return "Team"
        }
        if tier.contains("enterprise") || billing.contains("enterprise") || normalizedCapabilities.contains("enterprise") {
            return "Enterprise"
        }
        if tier.contains("pro")
            || billing.contains("subscription")
            || tier == "default_claude_ai"
            || normalizedCapabilities.contains("claude_pro")
            || normalizedCapabilities.contains("pro") {
            return "Pro"
        }

        return "Claude"
    }

    private static func subtitle(email: String?, organizationName: String?) -> String? {
        if email != nil, let organizationName, !organizationName.isEmpty {
            return organizationName
        }
        return email == nil ? "当前登录账号" : nil
    }

    private static func makeRow(id: String, label: String, bucket: ClaudeUsageBucket?) -> QuotaWindowRow? {
        guard let bucket else { return nil }
        let remaining = bucket.utilization.map { utilization in
            max(0, min(100, Int(round(100 - utilization))))
        }

        return QuotaWindowRow(
            id: id,
            label: label,
            remainingPercent: remaining,
            resetLabel: formatResetLabel(from: bucket.resetsAt)
        )
    }

    private static func formatResetLabel(from rawDate: String?) -> String {
        guard let rawDate = normalized(rawDate) else { return "-" }
        let date = parseISO8601Date(rawDate)
        guard let date else { return "-" }
        return date.formatted(resetLabelStyle)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \n\r\t")),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func parseISO8601Date(_ rawDate: String) -> Date? {
        let formatterWithFractionalSeconds = ISO8601DateFormatter()
        formatterWithFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatterWithFractionalSeconds.date(from: rawDate) {
            return parsed
        }

        let formatterWithoutFractionalSeconds = ISO8601DateFormatter()
        formatterWithoutFractionalSeconds.formatOptions = [.withInternetDateTime]
        return formatterWithoutFractionalSeconds.date(from: rawDate)
    }
}
