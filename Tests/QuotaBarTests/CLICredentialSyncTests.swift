import XCTest
@testable import QuotaBar

final class CLICredentialSyncTests: XCTestCase {

    private var testDirectory: URL!

    override func setUp() {
        super.setUp()
        testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLICredentialSyncTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: testDirectory)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeAccount(
        id: String = "acct-1",
        provider: QuotaProvider = .copilot,
        email: String? = "user@example.com",
        login: String? = "octocat",
        accessToken: String = "gho_test_token",
        refreshToken: String? = "ref_test",
        expiresAt: Date? = Date(timeIntervalSince1970: 1_700_000),
        projectId: String? = nil,
        isActive: Bool = true
    ) -> OAuthAccount {
        OAuthAccount(
            id: id,
            provider: provider,
            email: email,
            login: login,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            projectId: projectId,
            isActive: isActive,
            createdAt: Date()
        )
    }

    // MARK: - Copilot CLI: YAML format

    func testSyncCopilotWritesCorrectYAML() throws {
        let account = makeAccount(login: "octocat", accessToken: "gho_abc123")
        try CLICredentialSync.syncCopilotCLI(account: account, configDir: testDirectory)

        let hostsFile = testDirectory.appendingPathComponent("hosts.yml")
        let content = try String(contentsOf: hostsFile, encoding: .utf8)

        XCTAssertTrue(content.contains("github.com:"))
        XCTAssertTrue(content.contains("user: octocat"))
        XCTAssertTrue(content.contains("oauth_token: gho_abc123"))
        XCTAssertTrue(content.contains("git_protocol: https"))
    }

    func testSyncCopilotPreservesExistingFields() throws {
        // Write an existing hosts.yml with an extra host
        let dir = testDirectory!
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let hostsFile = dir.appendingPathComponent("hosts.yml")
        let existing = """
        github.com:
            user: old_user
            oauth_token: old_token
            git_protocol: https
        enterprise.example.com:
            user: corp_user
            oauth_token: corp_token
            git_protocol: ssh
        """
        try Data(existing.utf8).write(to: hostsFile, options: [.atomic])

        let account = makeAccount(login: "newuser", accessToken: "gho_new")
        try CLICredentialSync.syncCopilotCLI(account: account, configDir: dir)

        let content = try String(contentsOf: hostsFile, encoding: .utf8)

        // New github.com credentials written
        XCTAssertTrue(content.contains("user: newuser"))
        XCTAssertTrue(content.contains("oauth_token: gho_new"))
        // Enterprise host block preserved
        XCTAssertTrue(content.contains("enterprise.example.com:"))
        XCTAssertTrue(content.contains("corp_user"))
    }

    // MARK: - Copilot CLI: directory creation

    func testSyncCopilotCreatesDirectoryIfMissing() throws {
        let nested = testDirectory.appendingPathComponent("deep/nested/gh", isDirectory: true)
        let account = makeAccount()
        try CLICredentialSync.syncCopilotCLI(account: account, configDir: nested)

        let hostsFile = nested.appendingPathComponent("hosts.yml")
        XCTAssertTrue(FileManager.default.fileExists(atPath: hostsFile.path))
    }

    // MARK: - Copilot CLI: file permissions

    func testSyncCopilotSetsFilePermissions() throws {
        let account = makeAccount()
        try CLICredentialSync.syncCopilotCLI(account: account, configDir: testDirectory)

        let hostsFile = testDirectory.appendingPathComponent("hosts.yml")
        let attrs = try FileManager.default.attributesOfItem(atPath: hostsFile.path)
        let perms = attrs[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
    }

    // MARK: - Gemini CLI: oauth_creds.json format

    func testSyncGeminiWritesCorrectOAuthCreds() throws {
        let expiry = Date(timeIntervalSince1970: 1_700_000)
        let account = makeAccount(
            provider: .gemini,
            accessToken: "ya29.test",
            refreshToken: "1//refresh",
            expiresAt: expiry
        )
        try CLICredentialSync.syncGeminiCLI(account: account, configDir: testDirectory)

        let file = testDirectory.appendingPathComponent("oauth_creds.json")
        let data = try Data(contentsOf: file)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["access_token"] as? String, "ya29.test")
        XCTAssertEqual(json["refresh_token"] as? String, "1//refresh")
        XCTAssertEqual(json["token_type"] as? String, "Bearer")
        XCTAssertEqual(json["expiry_date"] as? Int64, 1_700_000_000) // seconds * 1000
        XCTAssertTrue((json["scope"] as? String ?? "").contains("userinfo.profile"))
    }

    // MARK: - Gemini CLI: google_accounts.json format

    func testSyncGeminiWritesCorrectGoogleAccounts() throws {
        let account = makeAccount(
            provider: .gemini,
            email: "active@gmail.com"
        )
        try CLICredentialSync.syncGeminiCLI(account: account, configDir: testDirectory)

        let file = testDirectory.appendingPathComponent("google_accounts.json")
        let data = try Data(contentsOf: file)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["active"] as? String, "active@gmail.com")
        XCTAssertEqual(json["old"] as? [String], [])
    }

    // MARK: - Gemini CLI: preserves old accounts

    func testSyncGeminiPreservesOldAccounts() throws {
        // Pre-populate google_accounts.json with an existing active + old list
        let dir = testDirectory!
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let gaFile = dir.appendingPathComponent("google_accounts.json")
        let existing: [String: Any] = [
            "active": "previous@gmail.com",
            "old": ["ancient@gmail.com"],
        ]
        let existingData = try JSONSerialization.data(withJSONObject: existing)
        try existingData.write(to: gaFile, options: [.atomic])

        // Now switch to a new account
        let account = makeAccount(
            provider: .gemini,
            email: "new@gmail.com"
        )
        try CLICredentialSync.syncGeminiCLI(account: account, configDir: dir)

        let data = try Data(contentsOf: gaFile)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["active"] as? String, "new@gmail.com")
        let old = json["old"] as? [String] ?? []
        XCTAssertTrue(old.contains("previous@gmail.com"))
        XCTAssertTrue(old.contains("ancient@gmail.com"))
        XCTAssertFalse(old.contains("new@gmail.com"))
    }

    // MARK: - Gemini CLI: oauth_creds.json permissions

    func testSyncGeminiOAuthCredsPermissions() throws {
        let account = makeAccount(provider: .gemini)
        try CLICredentialSync.syncGeminiCLI(account: account, configDir: testDirectory)

        let file = testDirectory.appendingPathComponent("oauth_creds.json")
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        let perms = attrs[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
    }

    func testSyncGeminiGoogleAccountsPermissions() throws {
        let account = makeAccount(provider: .gemini)
        try CLICredentialSync.syncGeminiCLI(account: account, configDir: testDirectory)

        let file = testDirectory.appendingPathComponent("google_accounts.json")
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        let perms = attrs[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
    }

    // MARK: - Gemini CLI: directory creation

    func testSyncGeminiCreatesDirectoryIfMissing() throws {
        let nested = testDirectory.appendingPathComponent("deep/gemini", isDirectory: true)
        let account = makeAccount(provider: .gemini)
        try CLICredentialSync.syncGeminiCLI(account: account, configDir: nested)

        let file = nested.appendingPathComponent("oauth_creds.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - Gemini CLI: allGeminiAccounts populates old list

    func testSyncGeminiIncludesOtherAccountEmails() throws {
        let active = makeAccount(id: "a1", provider: .gemini, email: "active@gmail.com")
        let other = makeAccount(id: "a2", provider: .gemini, email: "other@gmail.com", isActive: false)

        try CLICredentialSync.syncGeminiCLI(
            account: active,
            allGeminiAccounts: [active, other],
            configDir: testDirectory
        )

        let file = testDirectory.appendingPathComponent("google_accounts.json")
        let data = try Data(contentsOf: file)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["active"] as? String, "active@gmail.com")
        let old = json["old"] as? [String] ?? []
        XCTAssertTrue(old.contains("other@gmail.com"))
        XCTAssertFalse(old.contains("active@gmail.com"))
    }
}
