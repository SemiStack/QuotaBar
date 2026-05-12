import XCTest
@testable import QuotaBar

final class AccountStoreTests: XCTestCase {

    private var testDirectory: URL!
    private var storageURL: URL!
    private var legacyStorageURL: URL!

    override func setUp() {
        super.setUp()
        testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AccountStoreTests-\(UUID().uuidString)", isDirectory: true)
        storageURL = testDirectory.appendingPathComponent("accounts.json", isDirectory: false)
        legacyStorageURL = testDirectory
            .appendingPathComponent("SemiQuotaBar", isDirectory: true)
            .appendingPathComponent("accounts.json", isDirectory: false)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: testDirectory)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeStore() -> AccountStore {
        AccountStore(storageURL: storageURL)
    }

    private func makeAccount(
        id: String = UUID().uuidString,
        provider: QuotaProvider = .gemini,
        email: String? = "test@example.com",
        login: String? = nil,
        accessToken: String = "tok_test",
        refreshToken: String? = "ref_test",
        expiresAt: Date? = nil,
        projectId: String? = nil,
        isActive: Bool = false,
        createdAt: Date = Date()
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
            createdAt: createdAt
        )
    }

    // MARK: - Add

    func testAddFirstAccountBecomesActive() async throws {
        let store = makeStore()
        let account = makeAccount(provider: .gemini, isActive: false)
        try await store.addAccount(account)

        let accounts = await store.accounts(for: .gemini)
        XCTAssertEqual(accounts.count, 1)
        XCTAssertTrue(accounts[0].isActive)
    }

    func testAddSecondAccountKeepsFirstActive() async throws {
        let store = makeStore()
        let first = makeAccount(id: "first", provider: .copilot, isActive: false)
        let second = makeAccount(id: "second", provider: .copilot, isActive: false)

        try await store.addAccount(first)
        try await store.addAccount(second)

        let accounts = await store.accounts(for: .copilot)
        XCTAssertEqual(accounts.count, 2)
        XCTAssertTrue(accounts.first(where: { $0.id == "first" })!.isActive)
        XCTAssertFalse(accounts.first(where: { $0.id == "second" })!.isActive)
    }

    func testAddAccountWithIsActiveTrueDeactivatesOthers() async throws {
        let store = makeStore()
        let first = makeAccount(id: "first", provider: .gemini, isActive: false)
        let second = makeAccount(id: "second", provider: .gemini, isActive: true)

        try await store.addAccount(first)
        try await store.addAccount(second)

        let accounts = await store.accounts(for: .gemini)
        XCTAssertFalse(accounts.first(where: { $0.id == "first" })!.isActive)
        XCTAssertTrue(accounts.first(where: { $0.id == "second" })!.isActive)
    }

    func testAddAccountDoesNotAffectOtherProvider() async throws {
        let store = makeStore()
        let gemini = makeAccount(id: "g1", provider: .gemini)
        let copilot = makeAccount(id: "c1", provider: .copilot)

        try await store.addAccount(gemini)
        try await store.addAccount(copilot)

        let geminiAccounts = await store.accounts(for: .gemini)
        let copilotAccounts = await store.accounts(for: .copilot)
        XCTAssertEqual(geminiAccounts.count, 1)
        XCTAssertEqual(copilotAccounts.count, 1)
        XCTAssertTrue(geminiAccounts[0].isActive)
        XCTAssertTrue(copilotAccounts[0].isActive)
    }

    func testAddAccountWithSameIDRefreshesExistingCredentials() async throws {
        let store = makeStore()
        let first = makeAccount(
            id: "copilot-oauth-SemiStack",
            provider: .copilot,
            login: "SemiStack",
            accessToken: "old_token",
            isActive: true,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let refreshed = makeAccount(
            id: "copilot-oauth-SemiStack",
            provider: .copilot,
            login: "SemiStack",
            accessToken: "new_token",
            isActive: true,
            createdAt: Date(timeIntervalSince1970: 200)
        )

        try await store.addAccount(first)
        try await store.addAccount(refreshed)

        let accounts = await store.accounts(for: .copilot)
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts[0].accessToken, "new_token")
        XCTAssertEqual(accounts[0].createdAt.timeIntervalSince1970, 100, accuracy: 0.1)
        XCTAssertTrue(accounts[0].isActive)
    }

    // MARK: - Remove

    func testRemoveActiveAccountActivatesNext() async throws {
        let store = makeStore()
        let first = makeAccount(id: "first", provider: .gemini)
        let second = makeAccount(id: "second", provider: .gemini)

        try await store.addAccount(first)
        try await store.addAccount(second)
        try await store.removeAccount(id: "first")

        let accounts = await store.accounts(for: .gemini)
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts[0].id, "second")
        XCTAssertTrue(accounts[0].isActive)
    }

    func testRemoveInactiveAccountDoesNotChangeActive() async throws {
        let store = makeStore()
        let first = makeAccount(id: "first", provider: .gemini)
        let second = makeAccount(id: "second", provider: .gemini)

        try await store.addAccount(first)
        try await store.addAccount(second)
        try await store.removeAccount(id: "second")

        let accounts = await store.accounts(for: .gemini)
        XCTAssertEqual(accounts.count, 1)
        XCTAssertTrue(accounts[0].isActive)
        XCTAssertEqual(accounts[0].id, "first")
    }

    func testRemoveNonExistentAccountThrows() async {
        let store = makeStore()
        do {
            try await store.removeAccount(id: "nonexistent")
            XCTFail("Expected error")
        } catch {
            XCTAssertTrue(error is AppError)
        }
    }

    // MARK: - Set Active

    func testSetActiveAccount() async throws {
        let store = makeStore()
        let first = makeAccount(id: "first", provider: .gemini)
        let second = makeAccount(id: "second", provider: .gemini)

        try await store.addAccount(first)
        try await store.addAccount(second)
        try await store.setActiveAccount(id: "second", provider: .gemini)

        let active = await store.activeAccount(for: .gemini)
        XCTAssertEqual(active?.id, "second")

        let accounts = await store.accounts(for: .gemini)
        XCTAssertFalse(accounts.first(where: { $0.id == "first" })!.isActive)
    }

    func testSetActiveAccountForNonExistentThrows() async {
        let store = makeStore()
        do {
            try await store.setActiveAccount(id: "ghost", provider: .gemini)
            XCTFail("Expected error")
        } catch {
            XCTAssertTrue(error is AppError)
        }
    }

    // MARK: - Update Token

    func testUpdateToken() async throws {
        let store = makeStore()
        let account = makeAccount(id: "tok1", provider: .copilot, accessToken: "old_token")
        try await store.addAccount(account)

        let newExpiry = Date(timeIntervalSince1970: 2_000_000_000)
        try await store.updateToken(id: "tok1", accessToken: "new_token", expiresAt: newExpiry)

        let updated = await store.activeAccount(for: .copilot)
        XCTAssertEqual(updated?.accessToken, "new_token")
        XCTAssertEqual(updated?.expiresAt?.timeIntervalSince1970 ?? 0, newExpiry.timeIntervalSince1970, accuracy: 1)
    }

    func testUpdateTokenForNonExistentThrows() async {
        let store = makeStore()
        do {
            try await store.updateToken(id: "ghost", accessToken: "tok", expiresAt: nil)
            XCTFail("Expected error")
        } catch {
            XCTAssertTrue(error is AppError)
        }
    }

    // MARK: - Persistence

    func testPersistenceRoundTrip() async throws {
        let store1 = makeStore()
        let account = makeAccount(id: "persist1", provider: .gemini, email: "a@b.com", accessToken: "tok_abc")
        try await store1.addAccount(account)

        // New store instance reads from the same file
        let store2 = makeStore()
        let loaded = await store2.accounts(for: .gemini)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, "persist1")
        XCTAssertEqual(loaded[0].email, "a@b.com")
        XCTAssertEqual(loaded[0].accessToken, "tok_abc")
        XCTAssertTrue(loaded[0].isActive)
    }

    func testLegacySemiQuotaBarStoreMigratesOnFirstLoad() async throws {
        try FileManager.default.createDirectory(
            at: legacyStorageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let legacyAccount = makeAccount(
            id: "copilot-oauth-SemiStack",
            provider: .copilot,
            login: "SemiStack",
            accessToken: "legacy_token",
            isActive: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(AccountStoreData(accounts: [legacyAccount]))
        try data.write(to: legacyStorageURL)

        let store = AccountStore(storageURL: storageURL, legacyStorageURL: legacyStorageURL)
        let loaded = await store.accounts(for: .copilot)

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].accessToken, "legacy_token")
        XCTAssertTrue(FileManager.default.fileExists(atPath: storageURL.path))
    }

    func testLegacySemiQuotaBarStoreMigratesWhenCurrentStoreExistsButIsEmpty() async throws {
        try FileManager.default.createDirectory(
            at: legacyStorageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let legacyAccount = makeAccount(
            id: "copilot-oauth-SemiStack",
            provider: .copilot,
            login: "SemiStack",
            accessToken: "legacy_token",
            isActive: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(AccountStoreData(accounts: [legacyAccount])).write(to: legacyStorageURL)
        try FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(AccountStoreData(accounts: [])).write(to: storageURL)

        let store = AccountStore(storageURL: storageURL, legacyStorageURL: legacyStorageURL)
        let loaded = await store.accounts(for: .copilot)

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.accessToken, "legacy_token")
    }

    func testFilePermissions() async throws {
        let store = makeStore()
        let account = makeAccount()
        try await store.addAccount(account)

        let attributes = try FileManager.default.attributesOfItem(atPath: storageURL.path)
        let permissions = attributes[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testEmptyStoreReturnsNoAccounts() async {
        let store = makeStore()
        let accounts = await store.accounts(for: .gemini)
        XCTAssertTrue(accounts.isEmpty)
        let active = await store.activeAccount(for: .gemini)
        XCTAssertNil(active)
    }
}
