import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class QuotaMenuViewModel: ObservableObject {
    @Published private(set) var copilotCards: [QuotaCard] = []
    @Published private(set) var codexCards: [QuotaCard] = []
    @Published private(set) var claudeCards: [QuotaCard] = []
    @Published private(set) var geminiCards: [QuotaCard] = []
    @Published private(set) var sections: [QuotaSection] = []

    @Published private(set) var expandedProviders: Set<QuotaProvider> = []
    @Published private(set) var providerOrder: [QuotaProvider] = QuotaProvider.allCases
    @Published private(set) var hiddenProviders: Set<QuotaProvider> = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshedAt: Date?
    @Published private(set) var providerStates: [QuotaProvider: ProviderRefreshState] = [:]
    @Published private(set) var errorMessage: String?
    @Published private(set) var noticeMessage: String?
    @Published private(set) var activeOAuthProviders: Set<QuotaProvider> = []
    @Published private(set) var oauthAccounts: [OAuthAccount] = []
    @Published private(set) var didLoadInitialConfiguration = false
    @Published private(set) var isSwitchingAccount = false
    @Published private(set) var preferredSummaryHeight: CGFloat = QuotaPanelMetrics.summaryMinHeight

    @Published var isShowingConfiguration = false
    private let autoRefreshCooldown: TimeInterval = 30
    private let menuOpenAttemptDebounce: TimeInterval = 10
    private var refreshTask: Task<Void, Never>?
    private var refreshToken = UUID()
    private var lastMenuOpenRefreshAt: Date?
    private var providerTasks: [QuotaProvider: Task<Void, Never>] = [:]
    private var noticeDismissTask: Task<Void, Never>?
    private var accountStoreObserver: NSObjectProtocol?

    init() {
        providerOrder = Self.loadProviderOrder()
        hiddenProviders = Self.loadHiddenProviders()
        for provider in QuotaProvider.allCases {
            providerStates[provider] = ProviderRefreshState()
        }
        accountStoreObserver = NotificationCenter.default.addObserver(
            forName: .accountStoreDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.reloadOAuthState()
            }
        }
        Task {
            await reloadOAuthState()
            didLoadInitialConfiguration = true
            logSourceAvailability()
        }
    }

    var allCards: [QuotaCard] {
        sections.flatMap(\.cards)
    }

    var totalAccountCount: Int {
        allCards.count
    }

    var hasAnyAvailableSource: Bool {
        !activeOAuthProviders.isEmpty
    }

    var connectedSourceCount: Int {
        activeOAuthProviders.count
    }

    func updateSummaryPreferredHeight(_ height: CGFloat) {
        let sanitized = max(height, QuotaPanelMetrics.summaryMinHeight)
        guard abs(preferredSummaryHeight - sanitized) > 1 else { return }
        preferredSummaryHeight = sanitized
    }

    func toggleExpanded(_ provider: QuotaProvider) {
        if expandedProviders.contains(provider) {
            expandedProviders.remove(provider)
        } else {
            expandedProviders.insert(provider)
        }
    }

    func isExpanded(_ provider: QuotaProvider) -> Bool {
        expandedProviders.contains(provider)
    }

    func switchAccount(_ account: OAuthAccount) {
        guard !account.isActive else { return }
        isSwitchingAccount = true
        Task {
            do {
                try await AccountStore.shared.setActiveAccount(id: account.id, provider: account.provider)
                let allAccounts = await AccountStore.shared.allAccounts()
                oauthAccounts = allAccounts
                activeOAuthProviders = Set(allAccounts.filter(\.isActive).map(\.provider))
                refreshProvider(account.provider)
                // Wait for the provider refresh task to complete
                await providerTasks[account.provider]?.value
            } catch {
                Log.error("切换账号失败：\(error.localizedDescription)")
            }
            isSwitchingAccount = false
        }
    }

    func switchToAccount(id accountId: String, provider: QuotaProvider) {
        guard let account = oauthAccounts.first(where: { $0.id == accountId }) else { return }
        switchAccount(account)
    }

    func oauthAccounts(for provider: QuotaProvider) -> [OAuthAccount] {
        oauthAccounts.filter { $0.provider == provider }
    }

    func moveProvider(from source: QuotaProvider, to target: QuotaProvider) {
        guard source != target else { return }
        guard let sourceIndex = providerOrder.firstIndex(of: source),
              let targetIndex = providerOrder.firstIndex(of: target) else { return }
        providerOrder.remove(at: sourceIndex)
        providerOrder.insert(source, at: targetIndex)
        Self.persistProviderOrder(providerOrder)
        rebuildSections()
    }

    func setProviderHidden(_ provider: QuotaProvider, hidden: Bool) {
        if hidden {
            let visibleCount = QuotaProvider.allCases.count - hiddenProviders.count
            guard visibleCount > 1 else { return }
            hiddenProviders.insert(provider)
        } else {
            hiddenProviders.remove(provider)
        }
        Self.persistHiddenProviders(hiddenProviders)
        rebuildSections()
    }

    func isProviderHidden(_ provider: QuotaProvider) -> Bool {
        hiddenProviders.contains(provider)
    }

    private static let providerOrderKey = "providerOrder"

    private static func loadProviderOrder() -> [QuotaProvider] {
        guard let rawValues = UserDefaults.standard.stringArray(forKey: providerOrderKey) else {
            return QuotaProvider.allCases
        }
        let decoded = rawValues.compactMap { QuotaProvider(rawValue: $0) }
        let missing = QuotaProvider.allCases.filter { !decoded.contains($0) }
        let order = decoded + missing
        guard order.count == QuotaProvider.allCases.count else { return QuotaProvider.allCases }
        return order
    }

    private static func persistProviderOrder(_ order: [QuotaProvider]) {
        UserDefaults.standard.set(order.map(\.rawValue), forKey: providerOrderKey)
    }

    private static let hiddenProvidersKey = "hiddenProviders"

    private static func loadHiddenProviders() -> Set<QuotaProvider> {
        guard let rawValues = UserDefaults.standard.stringArray(forKey: hiddenProvidersKey) else {
            return []
        }
        return Set(rawValues.compactMap { QuotaProvider(rawValue: $0) })
    }

    private static func persistHiddenProviders(_ hidden: Set<QuotaProvider>) {
        UserDefaults.standard.set(hidden.map(\.rawValue), forKey: hiddenProvidersKey)
    }

    func handlePanelClosed() {
        // Settings window is independent — closing the main panel does not dismiss it.
    }

    func refreshOnOpen() {
        if shouldReuseRecentDataOnOpen() {
            Log.debug("跳过打开弹窗刷新：30 秒内沿用已有缓存")
            return
        }

        if shouldDebounceMenuOpenRefresh() {
            Log.debug("跳过打开弹窗刷新：10 秒内重复开关，沿用当前状态")
            return
        }

        lastMenuOpenRefreshAt = Date()
        triggerRefresh(reason: .menuOpen, restartIfNeeded: false)
    }

    func manualRefresh() {
        triggerRefresh(reason: .manual, restartIfNeeded: true)
    }

    func refreshProvider(_ provider: QuotaProvider) {
        providerStates[provider] = ProviderRefreshState(
            status: .refreshing,
            lastRefreshedAt: providerStates[provider]?.lastRefreshedAt
        )
        syncDerivedState()
        launchProviderRefresh(provider)
    }

    func providerState(for provider: QuotaProvider) -> ProviderRefreshState {
        providerStates[provider] ?? ProviderRefreshState()
    }

    func cancelRefresh() {
        if let refreshTask {
            Log.info("取消当前刷新任务")
            refreshTask.cancel()
        }
        for (provider, task) in providerTasks {
            task.cancel()
            providerTasks[provider] = nil
        }
    }

    private func setNotice(_ message: String) {
        noticeDismissTask?.cancel()
        noticeMessage = message
        noticeDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.noticeMessage = nil
        }
    }

    private func triggerRefresh(reason: RefreshReason, restartIfNeeded: Bool) {
        if refreshTask != nil {
            if restartIfNeeded {
                Log.info("\(reason.rawValue) 请求重启刷新")
                cancelRefresh()
            } else {
                Log.debug("忽略 \(reason.rawValue) 刷新请求：已有任务在执行")
                return
            }
        }

        let token = UUID()
        refreshToken = token
        refreshTask = Task { [weak self] in
            await self?.refreshAll(reason: reason, token: token)
        }
    }

    private func refreshAll(reason: RefreshReason, token: UUID) async {
        let startedAt = Date()
        Log.info("开始刷新（原因：\(reason.rawValue)）")
        errorMessage = nil

        for provider in QuotaProvider.allCases {
            providerStates[provider] = ProviderRefreshState(
                status: .refreshing,
                lastRefreshedAt: providerStates[provider]?.lastRefreshedAt
            )
        }
        syncDerivedState()

        defer {
            if refreshToken == token {
                refreshTask = nil
            }
        }

        do {
            try Task.checkCancellation()

            await reloadOAuthState()

            try Task.checkCancellation()

            launchProviderRefresh(.copilot)
            launchProviderRefresh(.claude)
            launchProviderRefresh(.codex)
            launchProviderRefresh(.gemini)

            // Wait for all provider tasks to complete
            for provider in QuotaProvider.allCases {
                if let task = providerTasks[provider] {
                    await task.value
                }
            }

            let elapsed = Date().timeIntervalSince(startedAt)
            Log.info(
                "全部刷新完成：Copilot \(copilotCards.count) 项，Codex \(codexCards.count) 项，Claude \(claudeCards.count) 项，Gemini \(geminiCards.count) 项，耗时 \(String(format: "%.2f", elapsed))s"
            )
        } catch is CancellationError {
            Log.info("刷新被取消（原因：\(reason.rawValue)）")
            for (_, task) in providerTasks {
                task.cancel()
            }
            for provider in QuotaProvider.allCases {
                if let task = providerTasks[provider] {
                    await task.value
                }
            }
            for provider in QuotaProvider.allCases {
                if providerStates[provider]?.status.isRefreshing == true {
                    providerStates[provider] = ProviderRefreshState(
                        status: .idle,
                        lastRefreshedAt: providerStates[provider]?.lastRefreshedAt
                    )
                }
            }
            syncDerivedState()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            errorMessage = message
            Log.error("刷新失败：\(message)")
        }
    }

    private func launchProviderRefresh(_ provider: QuotaProvider) {
        providerTasks[provider]?.cancel()

        providerTasks[provider] = Task { [weak self] in
            guard let self else { return }

            do {
                let cards: [QuotaCard]

                switch provider {
                case .copilot:
                    cards = try await self.loadCopilotCards()
                case .claude:
                    cards = try await self.loadClaudeCards()
                case .codex:
                    cards = try await self.loadCodexCards()
                case .gemini:
                    cards = try await self.loadGeminiCards()
                }

                self.applyProviderCards(provider, cards: cards)
            } catch is CancellationError {
                if self.providerStates[provider]?.status.isRefreshing == true {
                    self.providerStates[provider] = ProviderRefreshState(
                        status: .idle,
                        lastRefreshedAt: self.providerStates[provider]?.lastRefreshedAt
                    )
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.providerStates[provider] = ProviderRefreshState(
                    status: .failed(message),
                    lastRefreshedAt: self.providerStates[provider]?.lastRefreshedAt
                )
            }

            self.providerTasks[provider] = nil
            self.syncDerivedState()
        }
    }

    private func applyProviderCards(_ provider: QuotaProvider, cards: [QuotaCard]) {
        let sorted = cards.sorted(by: Self.cardSort(lhs:rhs:))
        switch provider {
        case .copilot: copilotCards = sorted
        case .claude: claudeCards = sorted
        case .codex: codexCards = sorted
        case .gemini: geminiCards = sorted
        }
        rebuildSections()

        let allError = !cards.isEmpty && cards.allSatisfy { $0.errorMessage != nil }
        if allError {
            let errorMsg = cards.first?.errorMessage ?? "未知错误"
            providerStates[provider] = ProviderRefreshState(
                status: .failed(errorMsg),
                lastRefreshedAt: Date()
            )
        } else {
            providerStates[provider] = ProviderRefreshState(
                status: .success,
                lastRefreshedAt: Date()
            )
        }
    }

    private func syncDerivedState() {
        isRefreshing = providerStates.values.contains { $0.status.isRefreshing }
        lastRefreshedAt = providerStates.values.compactMap(\.lastRefreshedAt).max()
    }

    private func reloadOAuthState() async {
        let allAccounts = await AccountStore.shared.allAccounts()
        oauthAccounts = allAccounts
        activeOAuthProviders = Set(allAccounts.filter(\.isActive).map(\.provider))
        logSourceAvailability()
    }

    private func logSourceAvailability() {
        Log.debug("OAuth 来源状态：\(activeOAuthProviders)")
    }

    private func loadCodexCards() async throws -> [QuotaCard] {
        // OAuth accounts only — no Management API fallback for Codex.
        if let cards = try await loadOAuthCards(
            provider: .codex,
            fetchCard: { account in try await DirectCodexClient(account: account).fetchQuotaCard() },
            displayName: { $0.login ?? $0.email ?? $0.id }
        ) {
            return cards
        }
        return []
    }

    private func loadClaudeCards() async throws -> [QuotaCard] {
        // OAuth accounts only — no Desktop session fallback for Claude.
        if let cards = try await loadOAuthCards(
            provider: .claude,
            fetchCard: { account in try await DirectClaudeClient(account: account).fetchQuotaCard() },
            displayName: { $0.email ?? $0.login ?? $0.id }
        ) {
            return cards
        }
        return []
    }

    /// Fetches quota cards for active OAuth accounts of the given provider.
    /// Returns `nil` if no active accounts exist (caller should fall back to legacy path).
    private func loadOAuthCards(
        provider: QuotaProvider,
        fetchCard: @Sendable @escaping (OAuthAccount) async throws -> QuotaCard,
        displayName: @Sendable @escaping (OAuthAccount) -> String
    ) async throws -> [QuotaCard]? {
        let allAccounts = await AccountStore.shared.accounts(for: provider)
        guard !allAccounts.isEmpty else { return nil }

        // Sort: active accounts first, then by creation date
        let sorted = allAccounts.sorted { a, b in
            if a.isActive != b.isActive { return a.isActive }
            return a.createdAt < b.createdAt
        }

        // Show placeholder cards immediately so the UI has something to display
        let placeholders: [QuotaCard] = sorted.map { account in
            QuotaCard(
                id: "\(provider.rawValue)-loading-\(account.id)",
                provider: provider,
                title: displayName(account),
                subtitle: "加载中...",
                planLabel: "—",
                windows: [],
                errorMessage: nil,
                accountId: account.id,
                isActiveAccount: account.isActive
            )
        }
        applyProviderCardsIncremental(provider, cards: placeholders)

        // Fetch all accounts concurrently
        let cardResults: [(index: Int, card: QuotaCard)] = await withTaskGroup(
            of: (Int, QuotaCard).self,
            returning: [(Int, QuotaCard)].self
        ) { group in
            for (index, account) in sorted.enumerated() {
                group.addTask {
                    do {
                        var card = try await fetchCard(account)
                        card = QuotaCard(
                            id: card.id,
                            provider: card.provider,
                            title: card.title,
                            subtitle: card.subtitle,
                            planLabel: card.planLabel,
                            windows: card.windows,
                            errorMessage: card.errorMessage,
                            accountId: account.id,
                            isActiveAccount: account.isActive
                        )
                        Log.info("\(provider) OAuth 额度拉取成功：\(displayName(account)) active=\(account.isActive)")
                        return (index, card)
                    } catch is CancellationError {
                        return (index, QuotaCard(
                            id: "\(provider.rawValue)-cancelled-\(account.id)",
                            provider: provider,
                            title: displayName(account),
                            subtitle: nil,
                            planLabel: "—",
                            windows: [],
                            errorMessage: "已取消",
                            accountId: account.id,
                            isActiveAccount: account.isActive
                        ))
                    } catch {
                        let name = displayName(account)
                        Log.error("\(provider) OAuth 额度拉取失败：\(name) - \(error.localizedDescription)")
                        return (index, QuotaCard(
                            id: "\(provider.rawValue)-oauth-error-\(account.id)",
                            provider: provider,
                            title: name,
                            subtitle: nil,
                            planLabel: "—",
                            windows: [],
                            errorMessage: error.localizedDescription,
                            accountId: account.id,
                            isActiveAccount: account.isActive
                        ))
                    }
                }
            }

            var results: [(Int, QuotaCard)] = []
            for await result in group {
                results.append(result)
                // Incremental display: update the card array as each completes
                let currentCards = self.currentProviderCards(provider)
                let updated = Self.replacingIncrementalCard(in: currentCards, with: result.1)
                self.applyProviderCardsIncremental(provider, cards: updated)
            }
            return results
        }

        // Final sorted result
        let finalCards = cardResults.sorted(by: { $0.index < $1.index }).map(\.card)
        return finalCards
    }

    /// Apply cards without updating provider state (for incremental updates during loading).
    private func applyProviderCardsIncremental(_ provider: QuotaProvider, cards: [QuotaCard]) {
        let sorted = cards.sorted(by: Self.cardSort(lhs:rhs:))
        switch provider {
        case .copilot: copilotCards = sorted
        case .claude: claudeCards = sorted
        case .codex: codexCards = sorted
        case .gemini: geminiCards = sorted
        }
        rebuildSections()
    }

    /// Get current cards for a provider.
    private func currentProviderCards(_ provider: QuotaProvider) -> [QuotaCard] {
        switch provider {
        case .copilot: return copilotCards
        case .claude: return claudeCards
        case .codex: return codexCards
        case .gemini: return geminiCards
        }
    }

    nonisolated static func replacingIncrementalCard(in currentCards: [QuotaCard], with replacement: QuotaCard) -> [QuotaCard] {
        guard !currentCards.isEmpty else { return [replacement] }

        var updated = currentCards

        if let accountId = replacement.accountId,
           let index = updated.firstIndex(where: { $0.accountId == accountId }) {
            updated[index] = replacement
            return updated
        }

        if let index = updated.firstIndex(where: { $0.id == replacement.id }) {
            updated[index] = replacement
            return updated
        }

        updated.append(replacement)
        return updated
    }

    private func loadGeminiCards() async throws -> [QuotaCard] {
        // OAuth accounts only — no Management API fallback for Gemini.
        if let cards = try await loadOAuthCards(
            provider: .gemini,
            fetchCard: { account in try await DirectGeminiClient(account: account).fetchQuotaCard() },
            displayName: { $0.email ?? $0.id }
        ) {
            return cards
        }
        return []
    }

    private func loadCopilotCards() async throws -> [QuotaCard] {
        // OAuth accounts only — no gh CLI fallback for Copilot.
        if let cards = try await loadOAuthCards(
            provider: .copilot,
            fetchCard: { account in try await DirectCopilotClient(account: account).fetchQuotaCard() },
            displayName: { $0.login ?? $0.email ?? $0.id }
        ) {
            return cards
        }
        return []
    }

    private func rebuildSections() {
        sections = providerOrder.filter { !hiddenProviders.contains($0) }.compactMap { provider in
            let cards: [QuotaCard]
            switch provider {
            case .copilot:
                cards = copilotCards
            case .codex:
                cards = codexCards
            case .claude:
                cards = claudeCards
            case .gemini:
                cards = geminiCards
            }

            guard !cards.isEmpty else { return nil }
            return QuotaSection(provider: provider, cards: cards.sorted(by: Self.cardSort(lhs:rhs:)))
        }
    }

    private func shouldReuseRecentDataOnOpen() -> Bool {
        guard allCards.isEmpty == false else { return false }
        guard allCards.contains(where: { $0.errorMessage != nil }) == false else { return false }
        guard let lastRefreshedAt else { return false }
        return Date().timeIntervalSince(lastRefreshedAt) < autoRefreshCooldown
    }

    private func shouldDebounceMenuOpenRefresh() -> Bool {
        guard let lastMenuOpenRefreshAt else { return false }
        return Date().timeIntervalSince(lastMenuOpenRefreshAt) < menuOpenAttemptDebounce
    }

    private nonisolated static func cardSort(lhs: QuotaCard, rhs: QuotaCard) -> Bool {
        if lhs.isCodexUnavailable != rhs.isCodexUnavailable {
            return rhs.isCodexUnavailable
        }

        let lhsScore = primaryRemaining(for: lhs)
        let rhsScore = primaryRemaining(for: rhs)
        if lhsScore != rhsScore {
            return lhsScore > rhsScore
        }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    private nonisolated static func primaryRemaining(for card: QuotaCard) -> Int {
        card.primaryStatusRow?.remainingPercent ?? -1
    }

    private static func makeProviderErrorCard(
        provider: QuotaProvider,
        title: String,
        subtitle: String?,
        message: String,
        id: String? = nil
    ) -> QuotaCard {
        QuotaCard(
            id: id ?? "\(provider.rawValue)-connection-error",
            provider: provider,
            title: title,
            subtitle: subtitle,
            planLabel: "错误",
            windows: [],
            errorMessage: message
        )
    }
}

private enum RefreshReason: String {
    case menuOpen = "打开弹窗"
    case manual = "手动刷新"
}
