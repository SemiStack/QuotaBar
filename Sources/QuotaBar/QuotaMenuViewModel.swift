import AppKit
import Foundation

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
    @Published private(set) var credentialSource = "未配置"
    @Published private(set) var hasSavedConfiguration = false
    @Published private(set) var activeOAuthProviders: Set<QuotaProvider> = []
    @Published private(set) var oauthAccounts: [OAuthAccount] = []
    @Published private(set) var didLoadInitialConfiguration = false
    @Published private(set) var isSavingConfiguration = false
    @Published private(set) var isSwitchingAccount = false
    @Published private(set) var preferredSummaryHeight: CGFloat = QuotaPanelMetrics.summaryMinHeight

    @Published var isShowingConfiguration = false
    @Published var apiBaseInput = ""
    @Published var managementKeyInput = ""
    @Published var connectionCodeInput = ""

    private let credentialsProvider = PanelCredentialsProvider()
    private let autoRefreshCooldown: TimeInterval = 30
    private let menuOpenAttemptDebounce: TimeInterval = 10
    private var refreshTask: Task<Void, Never>?
    private var refreshToken = UUID()
    private var lastMenuOpenRefreshAt: Date?
    private var providerTasks: [QuotaProvider: Task<Void, Never>] = [:]
    private var cachedManagementContext: ManagementContextState?
    private var noticeDismissTask: Task<Void, Never>?

    init() {
        providerOrder = Self.loadProviderOrder()
        hiddenProviders = Self.loadHiddenProviders()
        for provider in QuotaProvider.allCases {
            providerStates[provider] = ProviderRefreshState()
        }
        Task { await reloadConfigurationState() }
    }

    var allCards: [QuotaCard] {
        sections.flatMap(\.cards)
    }

    var totalAccountCount: Int {
        allCards.count
    }

    var hasAnyAvailableSource: Bool {
        hasSavedConfiguration || !activeOAuthProviders.isEmpty
    }

    var connectedSourceCount: Int {
        (hasSavedConfiguration ? 1 : 0) + activeOAuthProviders.count
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

    func presentConfiguration() {
        Task {
            await reloadConfigurationState()
            isShowingConfiguration = true
        }
    }

    func dismissConfiguration() {
        guard hasAnyAvailableSource else { return }
        managementKeyInput = ""
        connectionCodeInput = ""
        errorMessage = nil
        noticeMessage = nil
        isShowingConfiguration = false
    }

    func saveConfiguration() {
        guard !isSavingConfiguration else { return }
        isSavingConfiguration = true
        errorMessage = nil
        noticeMessage = nil
        cancelRefresh()

        let apiBase = apiBaseInput
        let managementKey = managementKeyInput
        Task { [weak self] in
            await self?.runSaveConfiguration(apiBase: apiBase, managementKey: managementKey)
        }
    }

    func importConfigurationFromBrowser() {
        guard !isSavingConfiguration else { return }
        isSavingConfiguration = true
        errorMessage = nil
        noticeMessage = nil
        cancelRefresh()

        Task { [weak self] in
            await self?.runImportFromBrowser()
        }
    }

    func copyConnectionCode() {
        guard !isSavingConfiguration else { return }
        isSavingConfiguration = true
        errorMessage = nil
        noticeMessage = nil

        Task { [weak self] in
            await self?.runCopyConnectionCode()
        }
    }

    func importConnectionCode() {
        guard !isSavingConfiguration else { return }
        isSavingConfiguration = true
        errorMessage = nil
        noticeMessage = nil
        cancelRefresh()

        let code = connectionCodeInput
        Task { [weak self] in
            await self?.runImportConnectionCode(code)
        }
    }

    func clearSavedConfiguration() {
        guard !isSavingConfiguration else { return }
        isSavingConfiguration = true
        errorMessage = nil
        noticeMessage = nil
        cancelRefresh()

        Task { [weak self] in
            await self?.runClearConfiguration()
        }
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

            let draft = await credentialsProvider.loadConfigurationDraft()
            applyConfigurationDraft(draft)

            // Refresh OAuth account availability
            let allAccounts = await AccountStore.shared.allAccounts()
            oauthAccounts = allAccounts
            activeOAuthProviders = Set(allAccounts.filter(\.isActive).map(\.provider))

            try Task.checkCancellation()

            // Copilot — fully independent
            launchProviderRefresh(.copilot)

            // Claude — uses imported session from AccountStore
            launchProviderRefresh(.claude)

            try Task.checkCancellation()

            // Management context — shared dependency for Codex and Gemini
            // Use try? so that missing management config doesn't block OAuth-based Gemini refresh
            let management: ManagementContextState
            if draft.hasManagementKey {
                management = (try? await loadManagementContext(hasSavedConfiguration: true)) ?? .unavailable
            } else {
                management = .unavailable
            }
            cachedManagementContext = management

            try Task.checkCancellation()

            // Codex and Gemini — depend on management context
            launchProviderRefresh(.codex, management: management)
            launchProviderRefresh(.gemini, management: management)

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
            if Self.shouldPresentConfiguration(for: message) {
                isShowingConfiguration = true
            }
            Log.error("刷新失败：\(message)")
        }
    }

    private func launchProviderRefresh(_ provider: QuotaProvider, management: ManagementContextState? = nil) {
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
                    let mgmt: ManagementContextState
                    if let m = management {
                        mgmt = m
                    } else {
                        do {
                            mgmt = try await self.resolveManagementContext()
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            mgmt = .unavailable
                        }
                    }
                    cards = try await self.loadGeminiCards(management: mgmt)
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

    private func resolveManagementContext() async throws -> ManagementContextState {
        if let cached = cachedManagementContext {
            return cached
        }
        let draft = await credentialsProvider.loadConfigurationDraft()
        let context = try await loadManagementContext(hasSavedConfiguration: draft.hasManagementKey)
        cachedManagementContext = context
        return context
    }

    private func runSaveConfiguration(apiBase: String, managementKey: String) async {
        defer { isSavingConfiguration = false }

        do {
            let credentials = try await credentialsProvider.prepareManualConfiguration(apiBase: apiBase, managementKey: managementKey)
            let client = ManagementAPIClient(credentials: credentials)
            _ = try await client.fetchAuthFiles()
            try await credentialsProvider.persist(credentials)

            managementKeyInput = ""
            credentialSource = ResolvedCredentials.Source.savedConfiguration.displayName
            errorMessage = nil
            setNotice("连接已保存。")
            cachedManagementContext = nil
            await reloadConfigurationState()
            isShowingConfiguration = false
            Log.info("手动配置保存成功：\(credentials.apiBase?.absoluteString ?? "-")")
            manualRefresh()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            errorMessage = message
            isShowingConfiguration = true
            Log.error("保存配置失败：\(message)")
        }
    }

    private func runImportFromBrowser() async {
        defer { isSavingConfiguration = false }

        do {
            let credentials = try await credentialsProvider.importFromChrome()
            let client = ManagementAPIClient(credentials: credentials)
            _ = try await client.fetchAuthFiles()
            try await credentialsProvider.persist(credentials)

            apiBaseInput = credentials.apiBase?.absoluteString ?? apiBaseInput
            managementKeyInput = ""
            credentialSource = ResolvedCredentials.Source.savedConfiguration.displayName
            errorMessage = nil
            setNotice("已从浏览器导入并保存。")
            cachedManagementContext = nil
            await reloadConfigurationState()
            isShowingConfiguration = false
            Log.info("浏览器导入配置成功并已保存")
            manualRefresh()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            errorMessage = message
            isShowingConfiguration = true
            Log.error("浏览器导入失败：\(message)")
        }
    }

    private func runCopyConnectionCode() async {
        defer { isSavingConfiguration = false }

        do {
            let code = try await credentialsProvider.exportConnectionCode()
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(code, forType: .string)
            setNotice("连接码已复制。")
            Log.info("连接码已复制到剪贴板")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            errorMessage = message
            Log.error("复制连接码失败：\(message)")
        }
    }

    private func runImportConnectionCode(_ code: String) async {
        defer { isSavingConfiguration = false }

        do {
            let credentials = try await credentialsProvider.importConnectionCode(code)
            let client = ManagementAPIClient(credentials: credentials)
            _ = try await client.fetchAuthFiles()
            try await credentialsProvider.persist(credentials)

            apiBaseInput = credentials.apiBase?.absoluteString ?? apiBaseInput
            managementKeyInput = ""
            connectionCodeInput = ""
            credentialSource = credentials.source.displayName
            errorMessage = nil
            setNotice("连接码导入成功。")
            cachedManagementContext = nil
            await reloadConfigurationState()
            isShowingConfiguration = false
            Log.info("连接码导入成功")
            manualRefresh()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            errorMessage = message
            isShowingConfiguration = true
            Log.error("导入连接码失败：\(message)")
        }
    }

    private func runClearConfiguration() async {
        defer { isSavingConfiguration = false }

        do {
            try await credentialsProvider.clearSavedConfiguration()
            copilotCards = []
            codexCards = []
            claudeCards = []
            geminiCards = []
            rebuildSections()
            credentialSource = "未配置"
            managementKeyInput = ""
            connectionCodeInput = ""
            errorMessage = nil
            setNotice("已清空本地连接配置。")
            cachedManagementContext = nil
            for provider in QuotaProvider.allCases {
                providerStates[provider] = ProviderRefreshState()
            }
            syncDerivedState()
            await reloadConfigurationState()
            isShowingConfiguration = !hasAnyAvailableSource

            if hasAnyAvailableSource {
                manualRefresh()
            } else {
                lastRefreshedAt = nil
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            errorMessage = message
            Log.error("清空配置失败：\(message)")
        }
    }

    private func reloadConfigurationState() async {
        let draft = await credentialsProvider.loadConfigurationDraft()
        applyConfigurationDraft(draft)
        didLoadInitialConfiguration = true

        let allAccounts = await AccountStore.shared.allAccounts()
        oauthAccounts = allAccounts
        activeOAuthProviders = Set(allAccounts.filter(\.isActive).map(\.provider))
    }

    private func applyConfigurationDraft(_ draft: PanelConfigurationDraft) {
        apiBaseInput = draft.apiBase
        hasSavedConfiguration = draft.hasManagementKey

        if draft.hasManagementKey {
            credentialSource = credentialSource == ResolvedCredentials.Source.chromeImport.displayName
                || credentialSource == ResolvedCredentials.Source.importedConnectionCode.displayName
                ? credentialSource
                : ResolvedCredentials.Source.savedConfiguration.displayName
        } else {
            credentialSource = "未配置"
        }

        logSourceAvailability()
    }

    private func logSourceAvailability() {
        Log.debug("来源状态：Codex=\(hasSavedConfiguration) OAuth=\(activeOAuthProviders)")
    }

    private func loadManagementContext(hasSavedConfiguration: Bool) async throws -> ManagementContextState {
        guard hasSavedConfiguration else {
            Log.info("跳过管理面板读取：未配置管理面板")
            credentialSource = "未配置"
            return .unavailable
        }

        do {
            let credentials = try await credentialsProvider.resolve()
            credentialSource = credentials.source.displayName
            Log.info("凭证来源：\(credentials.source.displayName)")

            let client = ManagementAPIClient(credentials: credentials)
            let files = try await client.fetchAuthFiles()
            return .ready(ManagementRefreshContext(client: client, files: files))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            Log.error("管理面板读取失败：\(description)")
            return .failed(description)
        }
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

    private func loadGeminiCards(management: ManagementContextState) async throws -> [QuotaCard] {
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

    private static func shouldPresentConfiguration(for message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("请先配置")
            || normalized.contains("management key")
            || normalized.contains("http 401")
            || normalized.contains("http 403")
    }

    private static func cardSort(lhs: QuotaCard, rhs: QuotaCard) -> Bool {
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

    private static func primaryRemaining(for card: QuotaCard) -> Int {
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

private struct ManagementRefreshContext: Sendable {
    let client: ManagementAPIClient
    let files: [AuthFile]
}

private enum ManagementContextState: Sendable {
    case unavailable
    case ready(ManagementRefreshContext)
    case failed(String)
}

private enum RefreshReason: String {
    case menuOpen = "打开弹窗"
    case manual = "手动刷新"
}
