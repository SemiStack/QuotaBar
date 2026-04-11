import Foundation

actor PanelCredentialsProvider {
    private let host = ""
    private let storagePrefix = "enc::v1::"
    private let storageSeed = "cli-proxy-api-webui::secure-storage"
    private let configurationStore = PanelConfigurationStore.shared

    func resolve() async throws -> ResolvedCredentials {
        if let saved = try? await configurationStore.loadSavedCredentials() {
            Log.debug("从已保存配置读取管理密钥")
            return saved
        }

        throw AppError("请先配置管理面板地址和 management key。")
    }

    func loadConfigurationDraft() async -> PanelConfigurationDraft {
        do {
            return try await configurationStore.loadDraft()
        } catch {
            Log.error("读取配置草稿失败：\(error.localizedDescription)")
            return PanelConfigurationDraft(apiBase: "", hasManagementKey: false)
        }
    }

    func prepareManualConfiguration(apiBase: String, managementKey: String?) async throws -> ResolvedCredentials {
        try await configurationStore.prepareCredentials(apiBase: apiBase, managementKey: managementKey)
    }

    func persist(_ credentials: ResolvedCredentials) async throws {
        try await configurationStore.persist(credentials)
        Log.info("管理配置已保存到本地配置")
    }

    func clearSavedConfiguration() async throws {
        try await configurationStore.clear()
        Log.info("已清空本地保存的管理配置")
    }

    func exportConnectionCode() async throws -> String {
        guard let saved = try await configurationStore.loadSavedCredentials() else {
            throw AppError("请先保存连接配置。")
        }
        Log.info("已生成连接码")
        return try ConnectionTransferCodec.encode(credentials: saved)
    }

    func importConnectionCode(_ code: String) async throws -> ResolvedCredentials {
        let decoded = try ConnectionTransferCodec.decode(code)
        let prepared = try await configurationStore.prepareCredentials(
            apiBase: decoded.apiBase?.absoluteString ?? "",
            managementKey: decoded.managementKey
        )
        Log.info("已解析连接码")
        return prepared.withSource(.importedConnectionCode)
    }

    func importFromChrome() async throws -> ResolvedCredentials {
        let imported = try await loadFromChromeStorage()
        try await configurationStore.persist(imported.withSource(.chromeImport))
        Log.info("已从共享 Chrome 导入管理配置")
        return imported.withSource(.chromeImport)
    }

    private func loadFromChromeStorage() async throws -> ResolvedCredentials {
        let userAgent = try await fetchSharedChromeUserAgent()
        let encrypted = try readEncryptedSnapshotFromChromeProfile()
        let snapshot = try decryptSnapshot(encrypted, userAgent: userAgent)

        guard let key = snapshot.state.managementKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw AppError("共享 Chrome 里没有可用的 managementKey。")
        }

        let apiBaseURL = snapshot.state.apiBase.flatMap(URL.init(string:))
        Log.debug("解出 apiBase=\(apiBaseURL?.absoluteString ?? "nil")")
        return ResolvedCredentials(apiBase: apiBaseURL, managementKey: key, source: .chromeImport)
    }

    private func fetchSharedChromeUserAgent() async throws -> String {
        let url = URL(string: "http://127.0.0.1:9223/json/version")!
        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse, (200 ..< 300).contains(httpResponse.statusCode) else {
            throw AppError("共享 Chrome 调试端口不可用，无法读取浏览器登录态。")
        }

        let decoded = try JSONDecoder().decode(BrowserVersionResponse.self, from: data)
        return decoded.userAgent
    }

    private func readEncryptedSnapshotFromChromeProfile() throws -> String {
        let fileManager = FileManager.default
        let root = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex/chrome-shared-profile")
        let levelDBDirectories = [
            root.appendingPathComponent("Default/Local Storage/leveldb"),
            root.appendingPathComponent("Profile 1/Local Storage/leveldb")
        ]

        var matches: [(date: Date, value: String)] = []
        let regex = try NSRegularExpression(pattern: "cli-proxy-auth.{0,512}?(enc::v1::[A-Za-z0-9+/=]+)", options: [.dotMatchesLineSeparators])

        for directory in levelDBDirectories where fileManager.fileExists(atPath: directory.path) {
            let fileURLs = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
                .filter { ["ldb", "log"].contains($0.pathExtension.lowercased()) }
                .sorted { lhs, rhs in
                    let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return lhsDate > rhsDate
                }

            for fileURL in fileURLs {
                guard let raw = try? String(data: Data(contentsOf: fileURL, options: [.mappedIfSafe]), encoding: .isoLatin1) else {
                    continue
                }

                let range = NSRange(raw.startIndex ..< raw.endIndex, in: raw)
                let results = regex.matches(in: raw, options: [], range: range)
                guard let result = results.last,
                      let captureRange = Range(result.range(at: 1), in: raw) else {
                    continue
                }

                let modifiedAt = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                matches.append((modifiedAt, String(raw[captureRange])))
            }
        }

        guard let selected = matches.sorted(by: { $0.date > $1.date }).first?.value else {
            throw AppError("没有在共享 Chrome 的 Local Storage 里找到 cli-proxy-auth。")
        }

        return selected
    }

    private func decryptSnapshot(_ encrypted: String, userAgent: String) throws -> PanelAuthSnapshot {
        guard encrypted.hasPrefix(storagePrefix) else {
            throw AppError("Chrome Local Storage 里的 cli-proxy-auth 不是预期格式。")
        }

        let payload = String(encrypted.dropFirst(storagePrefix.count))
        guard let encryptedData = Data(base64Encoded: payload) else {
            throw AppError("无法解析被混淆的 cli-proxy-auth。")
        }

        let seed = "\(storageSeed)|\(host)|\(userAgent)"
        let key = Array(seed.utf8)
        let encryptedBytes = Array(encryptedData)
        let decryptedBytes = encryptedBytes.enumerated().map { index, byte in
            byte ^ key[index % key.count]
        }
        let decryptedData = Data(decryptedBytes)

        guard let decryptedJSON = String(data: decryptedData, encoding: .utf8)?.data(using: .utf8) else {
            throw AppError("解密 cli-proxy-auth 后不是有效 UTF-8。")
        }

        return try JSONDecoder().decode(PanelAuthSnapshot.self, from: decryptedJSON)
    }
}
