import Foundation

struct CopilotDesktopUsageClient: Sendable {
    private let runner: CommandRunning

    init(runner: CommandRunning = GHCLICommandRunner()) {
        self.runner = runner
    }

    static func isDesktopSessionAvailable() async -> Bool {
        do {
            _ = try await CopilotDesktopUsageClient().loadUser()
            return true
        } catch {
            let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            Log.info("Copilot 会话检测失败：\(description)")
            return false
        }
    }

    func fetchQuotaCard() async throws -> QuotaCard {
        let user = try await loadUser()
        return CopilotQuotaBuilder.makeCard(user: user)
    }

    private func loadUser() async throws -> CopilotUserResponse {
        let data = try await runner.run(arguments: ["api", "/copilot_internal/user"])
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(CopilotUserResponse.self, from: data)
        } catch {
            throw CopilotDesktopError.invalidResponse(error.localizedDescription)
        }
    }
}

protocol CommandRunning: Sendable {
    func run(arguments: [String]) async throws -> Data
}

struct GHCLICommandRunner: CommandRunning, Sendable {
    func run(arguments: [String]) async throws -> Data {
        let executableURL = try Self.findExecutable()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            let stderrText = String(data: errorOutput, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.isSessionUnavailable(stderrText) {
                throw CopilotDesktopError.sessionUnavailable
            }
            throw CopilotDesktopError.commandFailed(stderrText ?? "gh api 执行失败")
        }

        return output
    }

    private static func findExecutable() throws -> URL {
        let candidates = [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "/usr/bin/gh",
        ]

        let fileManager = FileManager.default
        if let path = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }

        throw CopilotDesktopError.cliUnavailable
    }

    private static func isSessionUnavailable(_ message: String?) -> Bool {
        guard let normalized = message?.lowercased(), !normalized.isEmpty else {
            return false
        }

        return normalized.contains("gh auth login")
            || normalized.contains("not logged into any github hosts")
            || normalized.contains("authentication failed")
            || normalized.contains("authentication required")
    }
}

enum CopilotDesktopError: LocalizedError, Sendable {
    case cliUnavailable
    case sessionUnavailable
    case missingPremiumQuota
    case invalidResponse(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .cliUnavailable:
            return "未检测到 gh CLI，无法读取 Copilot 额度。"
        case .sessionUnavailable:
            return "Copilot 会话不可用"
        case .missingPremiumQuota:
            return "未读取到 Copilot Premium Requests 配额。"
        case let .invalidResponse(message):
            return "Copilot 返回格式异常：\(message)"
        case let .commandFailed(message):
            return "读取 Copilot 数据失败：\(message)"
        }
    }
}

struct CopilotUserResponse: Decodable, Sendable {
    let login: String?
    let accessTypeSKU: String?
    let copilotPlan: String?
    let quotaResetDate: String?
    let quotaResetDateUTC: String?
    let quotaSnapshots: CopilotQuotaSnapshots?

    enum CodingKeys: String, CodingKey {
        case login
        case accessTypeSKU = "access_type_sku"
        case copilotPlan = "copilot_plan"
        case quotaResetDate = "quota_reset_date"
        case quotaResetDateUTC = "quota_reset_date_utc"
        case quotaSnapshots = "quota_snapshots"
    }
}

struct CopilotQuotaSnapshots: Decodable, Sendable {
    let premiumInteractions: CopilotQuotaSnapshot?

    enum CodingKeys: String, CodingKey {
        case premiumInteractions = "premium_interactions"
    }
}

struct CopilotQuotaSnapshot: Decodable, Sendable {
    let percentRemaining: Double?
    let quotaRemaining: Double?
    let remaining: Int?
    let entitlement: Int?

    enum CodingKeys: String, CodingKey {
        case percentRemaining = "percent_remaining"
        case quotaRemaining = "quota_remaining"
        case remaining
        case entitlement
    }
}

enum CopilotQuotaBuilder {
    private static let resetLabelStyle = Date.FormatStyle()
        .month(.twoDigits)
        .day(.twoDigits)
        .locale(Locale(identifier: "zh_CN"))
    private static let usageValueFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        formatter.usesGroupingSeparator = false
        return formatter
    }()

    static func makeCard(user: CopilotUserResponse) -> QuotaCard {
        guard let quota = user.quotaSnapshots?.premiumInteractions else {
            return makeErrorCard(error: CopilotDesktopError.missingPremiumQuota)
        }

        let totalValue = quota.entitlement.map(Double.init)
        let usedValue = preciseUsedValue(for: quota)
        let remainingPercent = quota.percentRemaining.map { Int($0.rounded()) }
        let remainingPercentAndUsed = remainingPercentAndUsedText(
            remainingPercent: remainingPercent,
            usedValue: usedValue
        )

        return QuotaCard(
            id: "copilot-\(normalized(user.login) ?? "unknown")",
            provider: .copilot,
            title: normalized(user.login) ?? "Copilot",
            subtitle: nil,
            planLabel: planLabel(for: user),
            windows: [
                QuotaWindowRow(
                    id: "copilot-monthly",
                    label: "本月",
                    remainingPercent: remainingPercent,
                    resetLabel: combinedResetLabel(
                        rawDate: user.quotaResetDateUTC ?? user.quotaResetDate,
                        totalValue: totalValue
                    ),
                    valueText: remainingPercentAndUsed
                )
            ],
            errorMessage: nil
        )
    }

    static func makeErrorCard(error: Error) -> QuotaCard {
        let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return QuotaCard(
            id: "copilot-error",
            provider: .copilot,
            title: "Copilot",
            subtitle: nil,
            planLabel: "错误",
            windows: [],
            errorMessage: description
        )
    }

    private static func planLabel(for user: CopilotUserResponse) -> String {
        switch normalized(user.accessTypeSKU)?.lowercased() {
        case "monthly_subscriber_quota":
            return "PRO"
        case "free_limited_copilot":
            return "FREE"
        default:
            switch normalized(user.copilotPlan)?.lowercased() {
            case "individual":
                return "PRO"
            case let plan?:
                return plan.uppercased()
            default:
                return "COPILOT"
            }
        }
    }

    private static func formatResetLabel(_ rawValue: String?) -> String {
        guard let date = parseDate(rawValue) else { return "-" }
        return date.formatted(resetLabelStyle)
    }

    private static func parseDate(_ rawValue: String?) -> Date? {
        guard let normalized = normalized(rawValue) else { return nil }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = isoFormatter.date(from: normalized) {
            return parsed
        }

        let dateOnlyFormatter = DateFormatter()
        dateOnlyFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateOnlyFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateOnlyFormatter.dateFormat = "yyyy-MM-dd"
        return dateOnlyFormatter.date(from: normalized)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func preciseRemainingValue(for quota: CopilotQuotaSnapshot) -> Double? {
        if let quotaRemaining = quota.quotaRemaining {
            return quotaRemaining
        }
        if let remaining = quota.remaining {
            return Double(remaining)
        }
        return nil
    }

    private static func preciseUsedValue(for quota: CopilotQuotaSnapshot) -> Double? {
        guard let entitlement = quota.entitlement.map(Double.init) else { return nil }
        if let remaining = preciseRemainingValue(for: quota) {
            return max(entitlement - remaining, 0)
        }
        return nil
    }

    private static func remainingPercentAndUsedText(
        remainingPercent: Int?,
        usedValue: Double?
    ) -> String? {
        guard let remainingPercent,
              let usedText = formatUsageValue(usedValue) else {
            return nil
        }
        return "\(remainingPercent)%/\(usedText)"
    }

    private static func combinedResetLabel(
        rawDate: String?,
        totalValue: Double?
    ) -> String {
        let dateLabel = formatResetLabel(rawDate)
        guard let totalText = formatUsageValue(totalValue) else {
            return dateLabel
        }
        return "\(dateLabel) · \(totalText)"
    }

    private static func formatUsageValue(_ value: Double?) -> String? {
        guard let value else { return nil }
        let rounded = (value * 100).rounded() / 100
        return usageValueFormatter.string(from: NSNumber(value: rounded))
    }
}

// MARK: - DirectCopilotClient

struct DirectCopilotClient: Sendable {
    let account: OAuthAccount
    let session: URLSession

    private static let copilotUserURL = URL(string: "https://api.github.com/copilot_internal/user")!

    init(account: OAuthAccount, session: URLSession = .shared) {
        self.account = account
        self.session = session
    }

    func fetchQuotaCard() async throws -> QuotaCard {
        var request = URLRequest(url: Self.copilotUserURL)
        request.setValue("token \(account.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("QuotaBar", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError("Copilot 额度请求失败：无效响应")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            Log.error("Copilot 额度请求失败：HTTP \(http.statusCode)")
            throw AppError("Copilot 额度请求失败：HTTP \(http.statusCode)")
        }

        do {
            let user = try JSONDecoder().decode(CopilotUserResponse.self, from: data)
            return CopilotQuotaBuilder.makeCard(user: user)
        } catch {
            throw AppError("Copilot 额度解析失败：\(error.localizedDescription)")
        }
    }
}
