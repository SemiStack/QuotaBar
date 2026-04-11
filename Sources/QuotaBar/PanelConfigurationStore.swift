import Foundation

actor PanelConfigurationStore {
    static let shared = PanelConfigurationStore()

    private struct StoredCredentialPayload: Codable {
        let apiBase: String
        let managementKey: String
    }

    private let defaults = UserDefaults.standard
    private let apiBaseKey = "panel.apiBase"
    private let hasLocalManagementKeyKey = "panel.hasLocalManagementKey"
    private let legacyAPIBaseKey = "apiBase"
    private let legacyManagementKeyKey = "managementKey"
    private let defaultAPIBase = ""

    func loadDraft() throws -> PanelConfigurationDraft {
        try migrateLegacyCacheIfNeeded()
        let apiBase = storedAPIBaseString()
        let hasManagementKey = hasPersistedManagementKey()
        return PanelConfigurationDraft(apiBase: apiBase, hasManagementKey: hasManagementKey)
    }

    func loadSavedCredentials() throws -> ResolvedCredentials? {
        try migrateLegacyCacheIfNeeded()

        if let payload = try loadPersistedPayload() {
            let apiBase = try normalizeAPIBase(payload.apiBase)
            let managementKey = payload.managementKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard managementKey.isEmpty == false else { return nil }
            return ResolvedCredentials(apiBase: apiBase, managementKey: managementKey, source: .savedConfiguration)
        }

        return nil
    }

    func prepareCredentials(apiBase rawAPIBase: String, managementKey rawManagementKey: String?) throws -> ResolvedCredentials {
        try migrateLegacyCacheIfNeeded()

        let apiBase = try normalizeAPIBase(rawAPIBase)
        let typedManagementKey = rawManagementKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let persistedManagementKey = (try loadPersistedPayload()?.managementKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let managementKey = typedManagementKey.isEmpty ? persistedManagementKey : typedManagementKey

        guard managementKey.isEmpty == false else {
            throw AppError("请输入 management key。")
        }

        return ResolvedCredentials(apiBase: apiBase, managementKey: managementKey, source: .savedConfiguration)
    }

    func persist(_ credentials: ResolvedCredentials) throws {
        guard let apiBase = credentials.apiBase else {
            throw AppError("请先配置管理面板地址。")
        }
        defaults.set(apiBase.absoluteString, forKey: apiBaseKey)
        defaults.set(true, forKey: hasLocalManagementKeyKey)
        try writePayload(StoredCredentialPayload(apiBase: apiBase.absoluteString, managementKey: credentials.managementKey))
        defaults.removeObject(forKey: legacyManagementKeyKey)
    }

    func clear() throws {
        defaults.removeObject(forKey: apiBaseKey)
        defaults.removeObject(forKey: hasLocalManagementKeyKey)
        defaults.removeObject(forKey: legacyAPIBaseKey)
        defaults.removeObject(forKey: legacyManagementKeyKey)
        try? FileManager.default.removeItem(at: credentialFileURL())
    }

    private func migrateLegacyCacheIfNeeded() throws {
        if let legacyKey = defaults.string(forKey: legacyManagementKeyKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
           legacyKey.isEmpty == false {
            let payload = StoredCredentialPayload(apiBase: storedAPIBaseString(), managementKey: legacyKey)
            try writePayload(payload)
            defaults.set(true, forKey: hasLocalManagementKeyKey)
            defaults.removeObject(forKey: legacyManagementKeyKey)
        }

        if defaults.string(forKey: apiBaseKey) == nil,
           let legacyBase = defaults.string(forKey: legacyAPIBaseKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
           legacyBase.isEmpty == false {
            defaults.set(legacyBase, forKey: apiBaseKey)
        }
    }

    private func loadPersistedPayload() throws -> StoredCredentialPayload? {
        let url = credentialFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(StoredCredentialPayload.self, from: data)
    }

    private func writePayload(_ payload: StoredCredentialPayload) throws {
        let url = credentialFileURL()
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(payload)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func credentialFileURL() -> URL {
        let baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return baseDirectory
            .appendingPathComponent("QuotaBar", isDirectory: true)
            .appendingPathComponent("panel-credentials.json", isDirectory: false)
    }

    private func hasPersistedManagementKey() -> Bool {
        if defaults.bool(forKey: hasLocalManagementKeyKey) {
            return true
        }
        return (try? loadPersistedPayload()?.managementKey.isEmpty == false) ?? false
    }

    private func storedAPIBaseString() -> String {
        let candidate = defaults.string(forKey: apiBaseKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let candidate, !candidate.isEmpty {
            return candidate
        }

        let legacy = defaults.string(forKey: legacyAPIBaseKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let legacy, !legacy.isEmpty {
            return legacy
        }

        return defaultAPIBase
    }

    private func normalizeAPIBase(_ rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppError("请先配置管理面板地址。")
        }
        let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        let sanitized = normalized.hasSuffix("/") ? String(normalized.dropLast()) : normalized

        guard let url = URL(string: sanitized),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            throw AppError("管理面板地址格式不正确。")
        }

        return url
    }
}
