import Foundation

actor AccountStore {
    static let shared = AccountStore()

    private let storageURL: URL
    private var cache: [OAuthAccount]?

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? Self.defaultStorageURL()
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
        guard !all.contains(where: { $0.id == account.id }) else {
            throw AppError("Account already exists: \(account.id)")
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
        guard fm.fileExists(atPath: storageURL.path) else { return [] }
        let data = try Data(contentsOf: storageURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AccountStoreData.self, from: data).accounts
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
    }

    private static func defaultStorageURL() -> URL {
        let baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return baseDirectory
            .appendingPathComponent("QuotaBar", isDirectory: true)
            .appendingPathComponent("accounts.json", isDirectory: false)
    }
}
