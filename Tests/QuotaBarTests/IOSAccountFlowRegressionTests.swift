import Foundation
import XCTest
@testable import QuotaBar

@MainActor
final class IOSAccountFlowRegressionTests: XCTestCase {
    func testQuotaMenuViewModelReflectsExternalCopilotAccountAddition() async throws {
        let originalAccounts = await AccountStore.shared.allAccounts()
        try await replaceSharedAccounts(with: [])
        defer {
            Task {
                try? await self.replaceSharedAccounts(with: originalAccounts)
            }
        }

        let viewModel = QuotaMenuViewModel()
        let didLoadInitialConfiguration = await waitUntil(timeout: 2) { viewModel.didLoadInitialConfiguration }
        XCTAssertTrue(didLoadInitialConfiguration)
        XCTAssertEqual(viewModel.oauthAccounts(for: .copilot).count, 0)

        let account = OAuthAccount(
            id: "copilot-oauth-ios-regression",
            provider: .copilot,
            email: "ios@example.com",
            login: "ios-regression",
            accessToken: "gho_test_token",
            refreshToken: nil,
            expiresAt: nil,
            projectId: nil,
            isActive: true,
            createdAt: Date()
        )

        try await AccountStore.shared.addAccount(account)

        let reflectedChange = await waitUntil(timeout: 1.5) {
            viewModel.oauthAccounts(for: .copilot).contains(where: { $0.id == account.id })
        }
        XCTAssertTrue(reflectedChange)
    }

    func testIOSSettingsDoNotExposeManagementConfiguration() throws {
        let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let settingsRoot = repoRoot.appendingPathComponent("Sources/QuotaBarIOS/SettingsRootView.swift")
        let configurationView = repoRoot.appendingPathComponent("Sources/QuotaBarIOS/ConfigurationView.swift")

        let settingsContents = try String(contentsOf: settingsRoot, encoding: .utf8)
        XCTAssertFalse(settingsContents.contains("管理面板配置"))
        XCTAssertFalse(settingsContents.contains("ConfigurationView"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configurationView.path))
    }

    private func replaceSharedAccounts(with accounts: [OAuthAccount]) async throws {
        let current = await AccountStore.shared.allAccounts()
        for account in current {
            try await AccountStore.shared.removeAccount(id: account.id)
        }
        for account in accounts {
            try await AccountStore.shared.addAccount(account)
        }
    }

    private func waitUntil(
        timeout: TimeInterval,
        interval: UInt64 = 50_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: interval)
        }
        return condition()
    }
}
