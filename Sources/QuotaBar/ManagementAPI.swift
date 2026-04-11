import Foundation

struct ManagementAPIClient: Sendable {
    private let credentials: ResolvedCredentials
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private let codexUsageURL = "https://chatgpt.com/backend-api/wham/usage"
    private let geminiQuotaURL = "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota"
    private let geminiLoadCodeAssistURL = "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
    private let codexHeaders = [
        "Authorization": "Bearer $TOKEN$",
        "Content-Type": "application/json",
        "User-Agent": "codex_cli_rs/0.76.0 (Debian 13.0.0; x86_64) WindowsTerminal"
    ]
    private let geminiHeaders = [
        "Authorization": "Bearer $TOKEN$",
        "Content-Type": "application/json",
    ]

    init(credentials: ResolvedCredentials, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
    }

    func fetchAuthFiles() async throws -> [AuthFile] {
        let response: AuthFilesResponse = try await perform(path: "/v0/management/auth-files", method: "GET")
        Log.debug("管理接口返回认证文件数量：\(response.files.count)")
        return response.files
    }

    func fetchCodexQuota(for file: AuthFile) async throws -> QuotaCard {
        guard let authIndex = file.authIndex?.trimmingCharacters(in: .whitespacesAndNewlines), !authIndex.isEmpty else {
            throw AppError("\(file.name) 缺少 auth_index。")
        }

        guard let accountID = file.chatGPTAccountID?.trimmingCharacters(in: .whitespacesAndNewlines), !accountID.isEmpty else {
            throw AppError("\(file.name) 缺少 ChatGPT 账号 ID。")
        }

        var headers = codexHeaders
        headers["Chatgpt-Account-Id"] = accountID

        let payload = APIProxyRequest(
            authIndex: authIndex,
            method: "GET",
            url: codexUsageURL,
            header: headers
        )

        let proxyResponse: APIProxyResponse = try await perform(path: "/v0/management/api-call", method: "POST", body: payload)
        guard (200 ..< 300).contains(proxyResponse.statusCode) else {
            throw AppError("\(file.name) 刷新失败，状态码 \(proxyResponse.statusCode)。")
        }

        guard let body = proxyResponse.body ?? proxyResponse.bodyText else {
            throw AppError("\(file.name) 返回了空数据。")
        }

        let usage = try decoder.decode(CodexUsageResponse.self, from: Data(body.utf8))
        Log.debug("额度拉取成功：\(file.name) plan=\(usage.planType ?? "unknown")")
        return CodexQuotaBuilder.makeCard(file: file, usage: usage)
    }

    func fetchGeminiQuota(for file: AuthFile) async throws -> QuotaCard {
        let codeAssistContext = try await fetchGeminiCodeAssist(for: file, requestedProjectID: file.geminiProjectIDHint)
        let codeAssist = codeAssistContext.response
        let projectID = codeAssistContext.projectID

        guard let projectID, !projectID.isEmpty else {
            throw AppError("\(file.name) 缺少 Gemini 项目标识。")
        }

        let quota = try await fetchGeminiQuotaSnapshot(for: file, projectID: projectID)
        Log.debug("Gemini 额度拉取成功：\(file.name) tier=\(codeAssist.currentTier?.id ?? "unknown") project=\(projectID)")
        return GeminiQuotaBuilder.makeCard(file: file, projectID: projectID, codeAssist: codeAssist, quota: quota)
    }

    private func perform<T: Decodable>(path: String, method: String) async throws -> T {
        try await perform(path: path, method: method, bodyData: nil)
    }

    private func perform<T: Decodable, Body: Encodable>(path: String, method: String, body: Body) async throws -> T {
        let bodyData = try encoder.encode(body)
        return try await perform(path: path, method: method, bodyData: bodyData)
    }

    private func perform<T: Decodable>(path: String, method: String, bodyData: Data?) async throws -> T {
        var lastError: Error?

        for baseURL in credentials.candidateBaseURLs {
            do {
                let requestURL = baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                var request = URLRequest(url: requestURL)
                request.httpMethod = method
                request.timeoutInterval = 30
                request.setValue("Bearer \(credentials.managementKey)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = bodyData

                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw AppError("管理接口没有返回 HTTP 响应。")
                }

                guard (200 ..< 300).contains(httpResponse.statusCode) else {
                    let message = String(data: data, encoding: .utf8) ?? "<empty>"
                    throw AppError("请求 \(path) 失败：HTTP \(httpResponse.statusCode) - \(message)")
                }

                return try decoder.decode(T.self, from: data)
            } catch {
                Log.error("请求失败：\(method) \(path) via \(baseURL.absoluteString) - \(error.localizedDescription)")
                lastError = error
            }
        }

        throw lastError ?? AppError("请求管理接口失败。")
    }

    private func fetchGeminiCodeAssist(for file: AuthFile, requestedProjectID: String?) async throws -> GeminiCodeAssistContext {
        do {
            let response = try await performGeminiCodeAssist(for: file, requestedProjectID: requestedProjectID)
            return GeminiCodeAssistContext(response: response, projectID: requestedProjectID ?? response.resolvedProjectID)
        } catch {
            guard requestedProjectID != nil else { throw error }

            Log.error("Gemini loadCodeAssist 失败：\(file.name) via 项目 \(requestedProjectID ?? "-")，尝试自动发现项目 - \(error.localizedDescription)")
            let response = try await performGeminiCodeAssist(for: file, requestedProjectID: nil)
            return GeminiCodeAssistContext(response: response, projectID: response.resolvedProjectID)
        }
    }

    private func performGeminiCodeAssist(for file: AuthFile, requestedProjectID: String?) async throws -> GeminiCodeAssistResponse {
        let payload = GeminiCodeAssistPayload(projectID: requestedProjectID)
        return try await performProxyCall(
            file: file,
            method: "POST",
            url: geminiLoadCodeAssistURL,
            headers: geminiHeaders,
            payload: payload
        )
    }

    private func fetchGeminiQuotaSnapshot(for file: AuthFile, projectID: String) async throws -> GeminiQuotaResponse {
        let payload = GeminiQuotaPayload(projectID: projectID)
        return try await performProxyCall(
            file: file,
            method: "POST",
            url: geminiQuotaURL,
            headers: geminiHeaders,
            payload: payload
        )
    }

    private func performProxyCall<T: Decodable, Payload: Encodable>(
        file: AuthFile,
        method: String,
        url: String,
        headers: [String: String],
        payload: Payload
    ) async throws -> T {
        guard let authIndex = file.authIndex?.trimmingCharacters(in: .whitespacesAndNewlines), !authIndex.isEmpty else {
            throw AppError("\(file.name) 缺少 auth_index。")
        }

        let payloadData = try encoder.encode(payload)
        guard let payloadString = String(data: payloadData, encoding: .utf8) else {
            throw AppError("无法编码 Gemini 请求体。")
        }

        let request = APIProxyRequest(
            authIndex: authIndex,
            method: method,
            url: url,
            header: headers,
            data: payloadString
        )

        let proxyResponse: APIProxyResponse = try await perform(path: "/v0/management/api-call", method: "POST", body: request)
        guard (200 ..< 300).contains(proxyResponse.statusCode) else {
            throw AppError("\(file.name) 请求失败，状态码 \(proxyResponse.statusCode)。")
        }

        guard let body = proxyResponse.body ?? proxyResponse.bodyText else {
            throw AppError("\(file.name) 返回了空数据。")
        }

        do {
            return try decoder.decode(T.self, from: Data(body.utf8))
        } catch {
            let preview = body
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(320)
            Log.error("代理响应解码失败：\(file.name) \(url) - \(error.localizedDescription)\nRaw body preview: \(preview)")
            throw error
        }
    }
}

private struct GeminiCodeAssistContext {
    let response: GeminiCodeAssistResponse
    let projectID: String?
}

struct GeminiCodeAssistPayload: Encodable, Sendable {
    struct Metadata: Encodable, Sendable {
        let ideType = "IDE_UNSPECIFIED"
        let platform = "PLATFORM_UNSPECIFIED"
        let pluginType = "GEMINI"
        let duetProject: String?
    }

    let cloudaicompanionProject: String?
    let metadata: Metadata

    init(projectID: String?) {
        let normalizedProjectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalProjectID = normalizedProjectID?.isEmpty == false ? normalizedProjectID : nil

        cloudaicompanionProject = finalProjectID
        metadata = Metadata(duetProject: finalProjectID)
    }
}

struct GeminiQuotaPayload: Encodable, Sendable {
    let project: String

    init(projectID: String) {
        project = projectID
    }
}

enum CodexQuotaBuilder {
    private static let resetLabelStyle = Date.FormatStyle()
        .month(.twoDigits)
        .day(.twoDigits)
        .hour(.twoDigits(amPM: .omitted))
        .minute(.twoDigits)
        .locale(Locale(identifier: "zh_CN"))

    static func makeCard(file: AuthFile, usage: CodexUsageResponse) -> QuotaCard {
        let plan = displayPlan(for: usage.planType ?? file.planTypeHint)
        var rows = [QuotaWindowRow]()

        appendLimitRows(into: &rows, primaryLabel: "5 小时限额", secondaryLabel: "周限额", limit: usage.rateLimit, keyPrefix: "usage")

        if let extras = usage.additionalRateLimits {
            for (index, extra) in extras.enumerated() {
                let name = (extra.limitName ?? extra.meteredFeature ?? "additional-\(index + 1)")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                appendLimitRows(into: &rows, primaryLabel: "\(name) 5 小时限额", secondaryLabel: "\(name) 周限额", limit: extra.rateLimit, keyPrefix: "extra-\(index)")
            }
        }

        return QuotaCard(
            id: file.name,
            provider: .codex,
            title: displayTitle(for: file.name),
            subtitle: rows.contains(where: { $0.label == "5 小时限额" }) ? nil : "仅周限额",
            planLabel: plan,
            windows: rows,
            errorMessage: nil
        )
    }

    static func makeErrorCard(file: AuthFile, error: Error) -> QuotaCard {
        let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return QuotaCard(
            id: file.name,
            provider: .codex,
            title: displayTitle(for: file.name),
            subtitle: nil,
            planLabel: displayPlan(for: file.planTypeHint),
            windows: [],
            errorMessage: description
        )
    }

    /// Public entry point used by DirectCodexClient to reuse Codex card-building logic.
    static func appendLimitRowsForDirect(into rows: inout [QuotaWindowRow], primaryLabel: String, secondaryLabel: String, limit: RateLimit?, keyPrefix: String) {
        appendLimitRows(into: &rows, primaryLabel: primaryLabel, secondaryLabel: secondaryLabel, limit: limit, keyPrefix: keyPrefix)
    }

    private static func appendLimitRows(into rows: inout [QuotaWindowRow], primaryLabel: String, secondaryLabel: String, limit: RateLimit?, keyPrefix: String) {
        let split = splitWindows(from: limit)
        if let primary = split.fiveHour {
            rows.append(makeRow(id: "\(keyPrefix)-5h", label: primaryLabel, window: primary, limit: limit))
        }
        if let weekly = split.weekly {
            rows.append(makeRow(id: "\(keyPrefix)-weekly", label: secondaryLabel, window: weekly, limit: limit))
        }
    }

    private static func makeRow(id: String, label: String, window: UsageWindow, limit: RateLimit?) -> QuotaWindowRow {
        let resetLabel = formatResetLabel(from: window.resetAt)
        let used = window.usedPercent ?? (((limit?.limitReached == true) || (limit?.allowed == false)) && resetLabel != "-" ? 100 : nil)
        let remaining = used.map { max(0, min(100, Int(round(100 - $0)))) }
        return QuotaWindowRow(id: id, label: label, remainingPercent: remaining, resetLabel: resetLabel)
    }

    private static func splitWindows(from limit: RateLimit?) -> (fiveHour: UsageWindow?, weekly: UsageWindow?) {
        let primary = limit?.primaryWindow
        let secondary = limit?.secondaryWindow
        let windows = [primary, secondary]

        var fiveHour: UsageWindow?
        var weekly: UsageWindow?

        for window in windows {
            guard let window, let seconds = window.limitWindowSeconds else { continue }
            if seconds == 18_000, fiveHour == nil {
                fiveHour = window
            } else if seconds == 604_800, weekly == nil {
                weekly = window
            }
        }

        if fiveHour == nil, let primary, primary != weekly {
            fiveHour = primary
        }
        if weekly == nil, let secondary, secondary != fiveHour {
            weekly = secondary
        }

        return (fiveHour, weekly)
    }

    private static func displayPlan(for rawPlan: String?) -> String {
        switch rawPlan?.lowercased() {
        case "plus": return "Plus"
        case "team": return "Team"
        case "free": return "Free"
        case let value? where !value.isEmpty: return value.capitalized
        default: return "未知"
        }
    }

    private static func formatResetLabel(from timestamp: TimeInterval?) -> String {
        guard let timestamp else { return "-" }
        let date = Date(timeIntervalSince1970: timestamp)
        return date.formatted(resetLabelStyle)
    }

    private static func displayTitle(for fileName: String) -> String {
        var title = fileName
        if title.hasPrefix("codex-") {
            title.removeFirst("codex-".count)
        }
        if title.hasSuffix(".json") {
            title.removeLast(".json".count)
        }
        if title.hasSuffix("-free") {
            title.removeLast("-free".count)
        } else if title.hasSuffix("-plus") {
            title.removeLast("-plus".count)
        }
        return title
    }
}

enum GeminiQuotaBuilder {
    private static let retryLabelStyle = Date.FormatStyle()
        .month(.twoDigits)
        .day(.twoDigits)
        .hour(.twoDigits(amPM: .omitted))
        .minute(.twoDigits)
        .locale(Locale(identifier: "zh_CN"))
    private static let resetLabelStyle = Date.FormatStyle()
        .month(.twoDigits)
        .day(.twoDigits)
        .hour(.twoDigits(amPM: .omitted))
        .minute(.twoDigits)
        .locale(Locale(identifier: "zh_CN"))

    static func makeCard(
        file: AuthFile,
        projectID: String,
        codeAssist: GeminiCodeAssistResponse,
        quota: GeminiQuotaResponse
    ) -> QuotaCard {
        return QuotaCard(
            id: file.name,
            provider: .gemini,
            title: displayTitle(for: file),
            subtitle: subtitle(for: file, projectID: projectID),
            planLabel: planLabel(for: file, codeAssist: codeAssist),
            windows: rows(for: quota),
            errorMessage: nil
        )
    }

    static func makeCard(
        account: OAuthAccount,
        projectID: String,
        codeAssist: GeminiCodeAssistResponse,
        quota: GeminiQuotaResponse
    ) -> QuotaCard {
        return QuotaCard(
            id: "gemini-oauth-\(account.email ?? account.id)",
            provider: .gemini,
            title: account.email ?? "Gemini",
            subtitle: projectID,
            planLabel: planLabel(for: codeAssist),
            windows: rows(for: quota),
            errorMessage: nil
        )
    }

    static func makeErrorCard(file: AuthFile, error: Error) -> QuotaCard {
        let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return QuotaCard(
            id: file.name,
            provider: .gemini,
            title: displayTitle(for: file),
            subtitle: subtitle(for: file, projectID: file.geminiProjectIDHint),
            planLabel: planLabel(for: file, codeAssist: nil),
            windows: [],
            errorMessage: description
        )
    }

    private static func rows(for quota: GeminiQuotaResponse) -> [QuotaWindowRow] {
        let groupedBuckets = Dictionary(grouping: relevantBuckets(from: quota.buckets), by: seriesKey(for:))
        let orderedSeries = groupedBuckets.keys.sorted(by: { lhs, rhs in
            if lhs.sortOrder != rhs.sortOrder {
                return lhs.sortOrder < rhs.sortOrder
            }
            return lhs.label < rhs.label
        })

        return orderedSeries.compactMap { key in
            guard let buckets = groupedBuckets[key], !buckets.isEmpty else { return nil }
            let remainingPercent = buckets.compactMap(\.remainingPercent).min()
            let resetAt = buckets.compactMap(\.parsedResetTime).min()

            return QuotaWindowRow(
                id: "gemini-\(key.id)",
                label: key.label,
                remainingPercent: remainingPercent,
                resetLabel: formatResetLabel(from: resetAt)
            )
        }
    }

    private static func planLabel(for file: AuthFile, codeAssist: GeminiCodeAssistResponse?) -> String {
        if file.isUnavailable {
            return "冷却"
        }

        return planLabel(for: codeAssist)
    }

    private static func planLabel(for codeAssist: GeminiCodeAssistResponse?) -> String {
        switch normalized(codeAssist?.currentTier?.id)?.lowercased() {
        case "free-tier":
            return "免费版"
        case "standard-tier":
            return "Pro"
        case let tierID? where !tierID.isEmpty:
            return tierID
        default:
            return "CLI"
        }
    }

    private static func subtitle(for file: AuthFile, projectID: String?) -> String? {
        if file.isUnavailable {
            if let nextRetryAt = parseDate(file.nextRetryAfter) {
                return "冷却至 \(nextRetryAt.formatted(retryLabelStyle))"
            }
            if let statusMessage = normalized(file.statusMessage) {
                return statusMessage
            }
            return "暂不可用"
        }

        if let statusMessage = normalized(file.statusMessage), statusMessage.lowercased() != "active" {
            return statusMessage
        }

        return normalized(projectID) ?? projectLabel(for: file)
    }

    private static func displayTitle(for file: AuthFile) -> String {
        if let email = normalized(file.email) {
            return email
        }

        var title = file.name
        if title.hasPrefix("gemini-") {
            title.removeFirst("gemini-".count)
        }
        if title.hasSuffix(".json") {
            title.removeLast(".json".count)
        }
        return title
    }

    private static func projectLabel(for file: AuthFile) -> String? {
        file.geminiProjectIDHint
    }

    private static func formatResetLabel(from date: Date?) -> String {
        guard let date else { return "-" }
        return date.formatted(resetLabelStyle)
    }

    private static func relevantBuckets(from buckets: [GeminiQuotaBucket]) -> [GeminiQuotaBucket] {
        let requestBuckets = buckets.filter { $0.normalizedTokenType == "REQUESTS" }
        return requestBuckets.isEmpty ? buckets : requestBuckets
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func parseDate(_ rawValue: String?) -> Date? {
        guard let rawValue = normalized(rawValue) else { return nil }

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

private struct GeminiSeriesKey: Hashable {
    let id: String
    let label: String
    let sortOrder: Int
}

private func seriesKey(for bucket: GeminiQuotaBucket) -> GeminiSeriesKey {
    let modelID = bucket.modelId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""

    if modelID.contains("flash-lite") {
        return GeminiSeriesKey(id: "flash-lite", label: "Gemini Flash Lite Series", sortOrder: 0)
    }

    if modelID.contains("pro") {
        return GeminiSeriesKey(id: "pro", label: "Gemini Pro Series", sortOrder: 2)
    }

    if modelID.contains("flash") {
        return GeminiSeriesKey(id: "flash", label: "Gemini Flash Series", sortOrder: 1)
    }

    let fallbackLabel = bucket.modelId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Gemini"
    let fallbackID = fallbackLabel
        .lowercased()
        .replacingOccurrences(of: " ", with: "-")
    return GeminiSeriesKey(id: fallbackID, label: fallbackLabel, sortOrder: 99)
}
