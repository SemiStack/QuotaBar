import CoreGraphics
import Foundation

enum JSONValue: Decodable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    var stringValue: String? {
        if case let .string(value) = self {
            return value
        }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case let .object(value) = self {
            return value
        }
        return nil
    }
}

struct PanelAuthSnapshot: Decodable, Sendable {
    struct State: Decodable, Sendable {
        let apiBase: String?
        let managementKey: String?
        let rememberPassword: Bool?
    }

    let state: State
    let version: Int?
}

struct BrowserVersionResponse: Decodable, Sendable {
    let userAgent: String

    enum CodingKeys: String, CodingKey {
        case userAgent = "User-Agent"
    }
}

struct PanelConfigurationDraft: Sendable {
    let apiBase: String
    let hasManagementKey: Bool
}

struct AuthFilesResponse: Decodable, Sendable {
    let files: [AuthFile]
}

struct AuthFile: Decodable, Identifiable, Sendable {
    let fileID: String?
    let name: String
    let authIndex: String?
    let provider: String?
    let type: String?
    let status: String?
    let statusMessage: String?
    let disabled: Bool?
    let unavailable: Bool?
    let email: String?
    let account: String?
    let idToken: JSONValue?
    let path: String?
    let nextRetryAfter: String?

    enum CodingKeys: String, CodingKey {
        case fileID = "id"
        case name
        case authIndex = "auth_index"
        case provider
        case type
        case status
        case statusMessage = "status_message"
        case disabled
        case unavailable
        case email
        case account
        case idToken = "id_token"
        case path
        case nextRetryAfter = "next_retry_after"
    }

    var id: String { name }

    var resolvedProvider: String {
        (type ?? provider ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var isDisabled: Bool {
        disabled ?? false
    }

    var isUnavailable: Bool {
        unavailable ?? false
    }

    var chatGPTAccountID: String? {
        if let object = idToken?.objectValue,
           let direct = object["chatgpt_account_id"]?.stringValue {
            return direct
        }

        if let object = idToken?.objectValue,
           let auth = object["https://api.openai.com/auth"]?.objectValue,
           let nested = auth["chatgpt_account_id"]?.stringValue {
            return nested
        }

        if let token = idToken?.stringValue,
           let payload = decodeJWTPayload(from: token),
           let auth = payload["https://api.openai.com/auth"] as? [String: Any],
           let nested = auth["chatgpt_account_id"] as? String {
            return nested
        }

        return nil
    }

    var planTypeHint: String? {
        if let object = idToken?.objectValue,
           let direct = object["plan_type"]?.stringValue {
            return direct
        }

        if let object = idToken?.objectValue,
           let auth = object["https://api.openai.com/auth"]?.objectValue,
           let nested = auth["chatgpt_plan_type"]?.stringValue {
            return nested
        }

        return nil
    }

    var geminiProjectIDHint: String? {
        if let object = idToken?.objectValue,
           let rawProjectID = object["project_id"]?.stringValue {
            let direct = rawProjectID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !direct.isEmpty {
                return direct
            }
        }

        guard let account else { return nil }
        guard let start = account.lastIndex(of: "("),
              let end = account.lastIndex(of: ")"),
              start < end else {
            return nil
        }

        let project = account[account.index(after: start)..<end]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return project.isEmpty ? nil : project
    }

    private func decodeJWTPayload(from token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let padding = payload.count % 4
        if padding != 0 {
            payload.append(String(repeating: "=", count: 4 - padding))
        }

        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return json
    }
}

struct APIProxyRequest: Encodable, Sendable {
    let authIndex: String
    let method: String
    let url: String
    let header: [String: String]
    let data: String?

    init(
        authIndex: String,
        method: String,
        url: String,
        header: [String: String],
        data: String? = nil
    ) {
        self.authIndex = authIndex
        self.method = method
        self.url = url
        self.header = header
        self.data = data
    }

    enum CodingKeys: String, CodingKey {
        case authIndex = "authIndex"
        case method
        case url
        case header
        case data
    }
}

struct APIProxyResponse: Decodable, Sendable {
    let statusCode: Int
    let body: String?
    let bodyText: String?

    enum CodingKeys: String, CodingKey {
        case statusCode = "status_code"
        case body
        case bodyText
    }
}

struct CodexUsageResponse: Decodable, Sendable {
    let planType: String?
    let rateLimit: RateLimit?
    let codeReviewRateLimit: RateLimit?
    let additionalRateLimits: [AdditionalRateLimit]?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case codeReviewRateLimit = "code_review_rate_limit"
        case additionalRateLimits = "additional_rate_limits"
    }
}

struct AdditionalRateLimit: Decodable, Sendable {
    let limitName: String?
    let meteredFeature: String?
    let rateLimit: RateLimit?

    enum CodingKeys: String, CodingKey {
        case limitName = "limit_name"
        case meteredFeature = "metered_feature"
        case rateLimit = "rate_limit"
    }
}

struct RateLimit: Decodable, Sendable {
    let allowed: Bool?
    let limitReached: Bool?
    let primaryWindow: UsageWindow?
    let secondaryWindow: UsageWindow?

    enum CodingKeys: String, CodingKey {
        case allowed
        case limitReached = "limit_reached"
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

struct UsageWindow: Decodable, Sendable, Equatable {
    let usedPercent: Double?
    let limitWindowSeconds: Int?
    let resetAt: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAt = "reset_at"
    }
}

struct GeminiQuotaResponse: Decodable, Sendable {
    let buckets: [GeminiQuotaBucket]
}

struct GeminiQuotaBucket: Decodable, Sendable {
    let resetTime: String?
    let tokenType: String?
    let modelId: String?
    let remainingFraction: Double?

    var normalizedTokenType: String? {
        let normalized = tokenType?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized, !normalized.isEmpty else { return nil }
        return normalized.uppercased()
    }

    var parsedResetTime: Date? {
        Self.parseDate(resetTime)
    }

    var remainingPercent: Int? {
        guard let remainingFraction else { return nil }
        return max(0, min(100, Int((remainingFraction * 100).rounded())))
    }

    private static func parseDate(_ rawValue: String?) -> Date? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !rawValue.isEmpty else {
            return nil
        }

        let formatterWithFractionalSeconds = ISO8601DateFormatter()
        formatterWithFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatterWithFractionalSeconds.date(from: rawValue) {
            return parsed
        }

        let formatterWithoutFractionalSeconds = ISO8601DateFormatter()
        formatterWithoutFractionalSeconds.formatOptions = [.withInternetDateTime]
        return formatterWithoutFractionalSeconds.date(from: rawValue)
    }
}

struct GeminiCodeAssistResponse: Decodable, Sendable {
    let currentTier: GeminiCodeAssistTier?
    let allowedTiers: [GeminiCodeAssistTier]?
    let cloudaicompanionProject: JSONValue?
    let gcpManaged: Bool?
    let paidTier: GeminiCodeAssistTier?

    var resolvedProjectID: String? {
        if let rawProjectID = cloudaicompanionProject?.stringValue {
            let direct = rawProjectID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !direct.isEmpty {
                return direct
            }
        }

        if let object = cloudaicompanionProject?.objectValue,
           let rawNestedID = object["id"]?.stringValue {
            let nested = rawNestedID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !nested.isEmpty {
                return nested
            }
        }

        return nil
    }
}

struct GeminiCodeAssistTier: Decodable, Sendable {
    let id: String?
    let name: String?
    let description: String?
}

struct ResolvedCredentials: Sendable {
    enum Source: String, Sendable {
        case savedConfiguration
        case chromeImport
        case importedConnectionCode

        var displayName: String {
            switch self {
            case .savedConfiguration:
                return "已保存配置"
            case .chromeImport:
                return "浏览器导入"
            case .importedConnectionCode:
                return "连接码导入"
            }
        }
    }

    let apiBase: URL?
    let managementKey: String
    let source: Source

    var candidateBaseURLs: [URL] {
        let localFallback = URL(string: "http://127.0.0.1:8317")!
        guard let apiBase else {
            return [localFallback]
        }
        if apiBase == localFallback {
            return [localFallback]
        }
        return [apiBase, localFallback]
    }

    func withSource(_ source: Source) -> ResolvedCredentials {
        ResolvedCredentials(apiBase: apiBase, managementKey: managementKey, source: source)
    }
}

enum QuotaPanelMetrics {
    static let width: CGFloat = 328
    static let summaryMinHeight: CGFloat = 188
    static let summaryMaxHeight: CGFloat = 560
    static let cornerRadius: CGFloat = 26
}

struct QuotaMetricLineLayout: Equatable, Sendable {
    let labelWidth: CGFloat
    let valueWidth: CGFloat
    let resetWidth: CGFloat
    let columnSpacing: CGFloat
    let barHeight: CGFloat

    static let compact = QuotaMetricLineLayout(
        labelWidth: 26,
        valueWidth: 72,
        resetWidth: 78,
        columnSpacing: 5,
        barHeight: 3.5
    )

    var barLeadingOffset: CGFloat {
        labelWidth + columnSpacing
    }

    var barTrailingReservedWidth: CGFloat {
        valueWidth + resetWidth + (columnSpacing * 2)
    }
}

struct SegmentedQuotaBarLayout: Equatable, Sendable {
    let leadingFraction: CGFloat
    let trailingFraction: CGFloat

    static func forRemainingPercent(_ percent: Int?) -> SegmentedQuotaBarLayout {
        let clamped = max(0, min(percent ?? 0, 100))
        let leading = CGFloat(clamped) / 100
        return SegmentedQuotaBarLayout(
            leadingFraction: leading,
            trailingFraction: 1 - leading
        )
    }
}

struct QuotaWindowRow: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let remainingPercent: Int?
    let resetLabel: String
    let valueText: String?
    let progressText: String?
    let detailText: String?
    let metricSummary: QuotaMetricSummary?

    init(
        id: String,
        label: String,
        remainingPercent: Int?,
        resetLabel: String,
        valueText: String? = nil,
        progressText: String? = nil,
        detailText: String? = nil,
        metricSummary: QuotaMetricSummary? = nil
    ) {
        self.id = id
        self.label = label
        self.remainingPercent = remainingPercent
        self.resetLabel = resetLabel
        self.valueText = valueText
        self.progressText = progressText
        self.detailText = detailText
        self.metricSummary = metricSummary
    }

    var remainingText: String {
        if let valueText {
            return valueText
        }
        guard let remainingPercent else { return "--" }
        return "\(remainingPercent)%"
    }

    var progressBarPercent: Int? {
        if let progressText {
            let rawValue = progressText.replacingOccurrences(of: "%", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let parsed = Int(rawValue) {
                return max(0, min(100, parsed))
            }
        }
        return remainingPercent
    }

    var showsProgressBar: Bool {
        progressBarPercent != nil
    }

    var compactTrailingSummaryText: String {
        let reset = resetLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = detailText?
            .replacingOccurrences(of: "总量", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch (reset.isEmpty ? nil : reset, detail?.isEmpty == false ? detail : nil) {
        case let (reset?, detail?):
            return "\(reset) · \(detail)"
        case let (reset?, nil):
            return reset
        case let (nil, detail?):
            return detail
        default:
            return "-"
        }
    }

    var compactLabel: String {
        switch label {
        case "5 小时限额":
            return "5H"
        case "周限额":
            return "周"
        case "当前会话":
            return "会话"
        case "当周":
            return "周"
        case "本月":
            return "月"
        case "代码审查 5 小时限额":
            return "审查5H"
        case "代码审查周限额":
            return "审查"
        case "Gemini Flash Lite Series":
            return "Lite"
        case "Gemini Flash Series":
            return "Flash"
        case "Gemini Pro Series":
            return "Pro"
        default:
            return label
                .replacingOccurrences(of: "限额", with: "")
                .replacingOccurrences(of: "代码审查", with: "审查")
        }
    }

    var isFiveHourWindow: Bool {
        label.contains("5 小时") || label == "当前会话"
    }

    var isCodeReviewWindow: Bool {
        label.contains("代码审查")
    }

    var isWeeklyWindow: Bool {
        label == "周限额" || label == "当周"
    }
}

struct QuotaMetricSummary: Hashable, Sendable {
    let leadingLabel: String
    let leadingValueText: String
    let trailingLabel: String
    let trailingValueText: String
}

enum QuotaProvider: String, CaseIterable, Hashable, Sendable, Codable {
    case copilot
    case claude
    case codex
    case gemini

    var displayName: String {
        switch self {
        case .copilot:
            return "Copilot"
        case .codex:
            return "Codex"
        case .claude:
            return "Claude"
        case .gemini:
            return "Gemini"
        }
    }

    var isCollapsible: Bool { true }
}

struct QuotaSection: Identifiable, Hashable, Sendable {
    let provider: QuotaProvider
    let cards: [QuotaCard]

    var id: String { provider.rawValue }
}

struct QuotaCard: Identifiable, Hashable, Sendable {
    let id: String
    let provider: QuotaProvider
    let title: String
    let subtitle: String?
    let planLabel: String
    let windows: [QuotaWindowRow]
    let errorMessage: String?
    let accountId: String?
    let isActiveAccount: Bool

    init(
        id: String,
        provider: QuotaProvider,
        title: String,
        subtitle: String?,
        planLabel: String,
        windows: [QuotaWindowRow],
        errorMessage: String?,
        accountId: String? = nil,
        isActiveAccount: Bool = true
    ) {
        self.id = id
        self.provider = provider
        self.title = title
        self.subtitle = subtitle
        self.planLabel = planLabel
        self.windows = windows
        self.errorMessage = errorMessage
        self.accountId = accountId
        self.isActiveAccount = isActiveAccount
    }
}

extension QuotaCard {
    var primaryStatusRow: QuotaWindowRow? {
        if provider == .gemini {
            let primaryCandidates = windows.filter { !$0.isCodeReviewWindow }
            return primaryCandidates.enumerated().min { lhs, rhs in
                let lhsPercent = lhs.element.remainingPercent ?? Int.max
                let rhsPercent = rhs.element.remainingPercent ?? Int.max
                if lhsPercent != rhsPercent {
                    return lhsPercent < rhsPercent
                }
                return lhs.offset < rhs.offset
            }?.element ?? windows.first
        }

        return windows.first(where: { !$0.isCodeReviewWindow && $0.isFiveHourWindow })
            ?? windows.first(where: { !$0.isCodeReviewWindow })
            ?? windows.first
    }

    var primaryWeeklyRow: QuotaWindowRow? {
        windows.first(where: { !$0.isCodeReviewWindow && $0.isWeeklyWindow })
    }

    var isCodexUnavailable: Bool {
        provider == .codex && primaryWeeklyRow?.remainingPercent == 0
    }
}

struct ProviderRefreshState: Sendable, Equatable {
    enum Status: Sendable, Equatable {
        case idle
        case refreshing
        case success
        case failed(String)

        var isRefreshing: Bool {
            if case .refreshing = self { return true }
            return false
        }
    }

    var status: Status = .idle
    var lastRefreshedAt: Date? = nil
}

// MARK: - OAuth Account

struct OAuthAccount: Codable, Identifiable, Sendable {
    var id: String
    let provider: QuotaProvider
    var email: String?
    var login: String?
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var projectId: String?
    var isActive: Bool
    let createdAt: Date
}

struct AccountStoreData: Codable, Sendable {
    var accounts: [OAuthAccount]
}
