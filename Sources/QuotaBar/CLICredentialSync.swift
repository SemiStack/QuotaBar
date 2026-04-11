import Foundation

enum CLICredentialSync {

    // MARK: - Copilot → gh CLI

    /// Writes the active Copilot account's token into `~/.config/gh/hosts.yml`
    /// so the `gh` CLI picks up the same credential.
    static func syncCopilotCLI(account: OAuthAccount, configDir: URL? = nil) throws {
        let dir = configDir ?? defaultGhConfigDir()
        let hostsFile = dir.appendingPathComponent("hosts.yml", isDirectory: false)
        let fm = FileManager.default

        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let login = account.login ?? ""
        let token = account.accessToken

        // Read existing content so we can preserve fields outside github.com block.
        var existingLines: [String] = []
        if fm.fileExists(atPath: hostsFile.path),
           let contents = try? String(contentsOf: hostsFile, encoding: .utf8) {
            existingLines = contents.components(separatedBy: "\n")
        }

        let newBlock = buildGhBlock(login: login, token: token)

        let output: String
        if existingLines.isEmpty {
            output = newBlock
        } else {
            output = replaceGithubComBlock(in: existingLines, replacement: newBlock)
        }

        let data = Data(output.utf8)
        try data.write(to: hostsFile, options: [.atomic])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: hostsFile.path)
    }

    // MARK: - Gemini → Gemini CLI

    /// Writes the active Gemini account's credentials into
    /// `~/.gemini/oauth_creds.json` and `~/.gemini/google_accounts.json`.
    static func syncGeminiCLI(
        account: OAuthAccount,
        allGeminiAccounts: [OAuthAccount] = [],
        configDir: URL? = nil
    ) throws {
        let dir = configDir ?? defaultGeminiConfigDir()
        let fm = FileManager.default

        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // --- oauth_creds.json ---
        try writeOAuthCreds(account: account, directory: dir)

        // --- google_accounts.json ---
        try writeGoogleAccounts(
            activeEmail: account.email ?? "",
            allAccounts: allGeminiAccounts,
            directory: dir
        )
    }

    // MARK: - Private (gh)

    private static func defaultGhConfigDir() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/gh", isDirectory: true)
    }

    private static func buildGhBlock(login: String, token: String) -> String {
        """
        github.com:
            user: \(login)
            oauth_token: \(token)
            git_protocol: https
        """
    }

    /// Replace the `github.com:` block in existing hosts.yml lines,
    /// preserving any other top-level host entries.
    private static func replaceGithubComBlock(in lines: [String], replacement: String) -> String {
        var result: [String] = []
        var insideGithubBlock = false
        var replaced = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("github.com:") {
                insideGithubBlock = true
                if !replaced {
                    result.append(replacement)
                    replaced = true
                }
                continue
            }

            // A non-indented, non-empty line signals a new top-level block.
            if insideGithubBlock {
                let isIndented = line.hasPrefix(" ") || line.hasPrefix("\t")
                if !isIndented && !trimmed.isEmpty {
                    insideGithubBlock = false
                } else {
                    continue // skip old github.com sub-lines
                }
            }

            result.append(line)
        }

        if !replaced {
            result.append(replacement)
        }

        // Trim trailing empty lines, then add single newline at end.
        while result.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            result.removeLast()
        }

        return result.joined(separator: "\n") + "\n"
    }

    // MARK: - Private (Gemini)

    private static func defaultGeminiConfigDir() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".gemini", isDirectory: true)
    }

    private static func writeOAuthCreds(account: OAuthAccount, directory: URL) throws {
        let file = directory.appendingPathComponent("oauth_creds.json", isDirectory: false)
        let fm = FileManager.default

        let expiryMillis: Int64
        if let expiresAt = account.expiresAt {
            expiryMillis = Int64(expiresAt.timeIntervalSince1970 * 1000)
        } else {
            expiryMillis = 0
        }

        let creds: [String: Any] = [
            "access_token": account.accessToken,
            "scope": "https://www.googleapis.com/auth/userinfo.profile https://www.googleapis.com/auth/userinfo.email openid https://www.googleapis.com/auth/cloud-platform",
            "token_type": "Bearer",
            "expiry_date": expiryMillis,
            "refresh_token": account.refreshToken ?? "",
        ]

        let data = try JSONSerialization.data(
            withJSONObject: creds,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: file, options: [.atomic])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private static func writeGoogleAccounts(
        activeEmail: String,
        allAccounts: [OAuthAccount],
        directory: URL
    ) throws {
        let file = directory.appendingPathComponent("google_accounts.json", isDirectory: false)
        let fm = FileManager.default

        // Collect "old" emails from existing file + provided accounts, excluding active.
        var oldEmails: [String] = []

        if fm.fileExists(atPath: file.path),
           let existingData = try? Data(contentsOf: file),
           let json = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] {
            if let existingActive = json["active"] as? String,
               !existingActive.isEmpty,
               existingActive != activeEmail {
                oldEmails.append(existingActive)
            }
            if let existingOld = json["old"] as? [String] {
                oldEmails.append(contentsOf: existingOld)
            }
        }

        // Also include emails from all provided Gemini accounts (except active).
        for acct in allAccounts where acct.email != activeEmail {
            if let email = acct.email, !email.isEmpty {
                oldEmails.append(email)
            }
        }

        // Deduplicate while preserving order, and exclude active email.
        var seen = Set<String>()
        seen.insert(activeEmail)
        var uniqueOld: [String] = []
        for email in oldEmails {
            if seen.insert(email).inserted {
                uniqueOld.append(email)
            }
        }

        let payload: [String: Any] = [
            "active": activeEmail,
            "old": uniqueOld,
        ]

        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: file, options: [.atomic])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
