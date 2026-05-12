import Foundation

actor AccountStore {
    static let shared = AccountStore()

    private let storageURL: URL
    private let legacyStorageURL: URL?
    private var cache: [OAuthAccount]?

    init(storageURL: URL? = nil, legacyStorageURL: URL? = nil) {
        self.storageURL = storageURL ?? Self.defaultStorageURL()
        if let legacyStorageURL {
            self.legacyStorageURL = legacyStorageURL
        } else if storageURL == nil {
            self.legacyStorageURL = Self.legacyStorageURL()
        } else {
            self.legacyStorageURL = nil
        }
    }

    // MARK: - Read

    func allAccounts() -> [OAuthAccount] {
        loadedAccounts()
    }

    func accounts(for provider: QuotaProvider) -> [OAuthAccount] {
        let all = loadedAccounts()
        return all.filter { $0.provider == provider }
    }

    func activeAccount(for provider: QuotaProvider) -> OAuthAccount? {
        accounts(for: provider).first(where: { $0.isActive })
    }

    // MARK: - Write

    func addAccount(_ account: OAuthAccount) throws {
        var all = loadedAccounts()
        if let existingIndex = all.firstIndex(where: { $0.id == account.id }) {
            let existing = all[existingIndex]
            let shouldBeActive = account.isActive || existing.isActive
            let replacement = OAuthAccount(
                id: account.id,
                provider: account.provider,
                email: account.email ?? existing.email,
                login: account.login ?? existing.login,
                accessToken: account.accessToken,
                refreshToken: account.refreshToken ?? existing.refreshToken,
                expiresAt: account.expiresAt ?? existing.expiresAt,
                projectId: account.projectId ?? existing.projectId,
                isActive: shouldBeActive,
                createdAt: existing.createdAt
            )

            if shouldBeActive {
                for i in all.indices where all[i].provider == account.provider {
                    all[i].isActive = false
                }
            }

            all[existingIndex] = replacement
            try save(all)
            Log.debug("Account updated: \(replacement.id) provider=\(replacement.provider.rawValue)")

            if replacement.isActive {
                syncToCLI(account: replacement, allAccounts: all)
            }
            return
        }
        var newAccount = account

        let providerAccounts = all.filter { $0.provider == account.provider }
        if providerAccounts.isEmpty {
            newAccount.isActive = true
        } else if newAccount.isActive {
            // Deactivate other accounts for the same provider
            for i in all.indices where all[i].provider == account.provider {
                all[i].isActive = false
            }
        }

        all.append(newAccount)
        try save(all)
        Log.debug("Account added: \(newAccount.id) provider=\(newAccount.provider.rawValue)")
    }

    func removeAccount(id: String) throws {
        var all = loadedAccounts()
        guard let index = all.firstIndex(where: { $0.id == id }) else {
            throw AppError("Account not found: \(id)")
        }

        let removed = all.remove(at: index)

        // If removed account was active, activate the first remaining for same provider
        if removed.isActive {
            if let next = all.firstIndex(where: { $0.provider == removed.provider }) {
                all[next].isActive = true
            }
        }

        try save(all)
        Log.debug("Account removed: \(id)")
    }

    func setActiveAccount(id: String, provider: QuotaProvider) throws {
        var all = loadedAccounts()
        guard all.contains(where: { $0.id == id && $0.provider == provider }) else {
            throw AppError("Account not found: \(id)")
        }

        for i in all.indices where all[i].provider == provider {
            all[i].isActive = (all[i].id == id)
        }

        try save(all)
        Log.debug("Active account set: \(id) provider=\(provider.rawValue)")

        if let active = all.first(where: { $0.id == id }) {
            syncToCLI(account: active, allAccounts: all)
        }
    }

    func updateToken(id: String, accessToken: String, expiresAt: Date?) throws {
        var all = loadedAccounts()
        guard let index = all.firstIndex(where: { $0.id == id }) else {
            throw AppError("Account not found: \(id)")
        }

        all[index].accessToken = accessToken
        all[index].expiresAt = expiresAt

        try save(all)
        Log.debug("Token updated for account: \(id)")
    }

    func updateRefreshToken(id: String, refreshToken: String) throws {
        var all = loadedAccounts()
        guard let index = all.firstIndex(where: { $0.id == id }) else {
            throw AppError("Account not found: \(id)")
        }

        all[index].refreshToken = refreshToken

        try save(all)
        Log.debug("Refresh token updated for account: \(id)")
    }

    func updateAccountInfo(id: String, login: String?, email: String?) throws {
        var all = loadedAccounts()
        guard let index = all.firstIndex(where: { $0.id == id }) else {
            throw AppError("Account not found: \(id)")
        }

        if let login { all[index].login = login }
        if let email { all[index].email = email }

        try save(all)
        Log.debug("Account info updated: \(id) login=\(login ?? "-") email=\(email ?? "-")")
    }

    // MARK: - CLI Sync

    /// Syncs credentials to CLI config files on account switch only.
    /// Token refreshes (updateToken) intentionally skip CLI sync — the spec
    /// requires sync only on explicit user-initiated account switching.
    private func syncToCLI(account: OAuthAccount, allAccounts: [OAuthAccount]) {
        do {
            switch account.provider {
            case .copilot:
                try CLICredentialSync.syncCopilotCLI(account: account)
            case .gemini:
                let geminiAccounts = allAccounts.filter { $0.provider == .gemini }
                try CLICredentialSync.syncGeminiCLI(
                    account: account,
                    allGeminiAccounts: geminiAccounts
                )
            case .claude, .codex:
                return
            }
            Log.info("CLI 配置已同步：\(account.provider.rawValue)")
        } catch {
            Log.error("CLI 配置同步失败：\(error)")
        }
    }

    // MARK: - Persistence

    private func loadedAccounts() -> [OAuthAccount] {
        if let cache { return cache }
        let loaded = (try? load()) ?? []
        cache = loaded
        return loaded
    }

    private func load() throws -> [OAuthAccount] {
        let fm = FileManager.default
        if fm.fileExists(atPath: storageURL.path) {
            let currentAccounts = try decodeAccounts(from: storageURL)
            if currentAccounts.isEmpty == false {
                return currentAccounts
            }
        }

        if let legacyStorageURL,
           fm.fileExists(atPath: legacyStorageURL.path) {
            let accounts = try decodeAccounts(from: legacyStorageURL)
            try save(accounts)
            Log.info("迁移旧版账号存储：\(legacyStorageURL.lastPathComponent) -> \(storageURL.lastPathComponent)")
            return accounts
        }

        return []
    }

    private func save(_ accounts: [OAuthAccount]) throws {
        let directory = storageURL.deletingLastPathComponent()
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(AccountStoreData(accounts: accounts))

        try data.write(to: storageURL, options: [.atomic])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)

        cache = accounts
        NotificationCenter.default.post(name: .accountStoreDidChange, object: nil)
    }

    private static func defaultStorageURL() -> URL {
        let baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return baseDirectory
            .appendingPathComponent("QuotaBar", isDirectory: true)
            .appendingPathComponent("accounts.json", isDirectory: false)
    }

    private static func legacyStorageURL() -> URL {
        let baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return baseDirectory
            .appendingPathComponent("SemiQuotaBar", isDirectory: true)
            .appendingPathComponent("accounts.json", isDirectory: false)
    }

    private func decodeAccounts(from url: URL) throws -> [OAuthAccount] {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AccountStoreData.self, from: data).accounts
    }
}

extension Notification.Name {
    static let accountStoreDidChange = Notification.Name("AccountStore.didChange")
}
