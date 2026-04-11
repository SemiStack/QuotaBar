import XCTest
@testable import QuotaBar
import AppKit

final class CopilotAndRedesignTests: XCTestCase {
    private var originalHiddenProviders: [String]?
    private var originalProviderOrder: [String]?

    override func setUp() {
        super.setUp()
        originalHiddenProviders = UserDefaults.standard.stringArray(forKey: "hiddenProviders")
        originalProviderOrder = UserDefaults.standard.stringArray(forKey: "providerOrder")
    }

    override func tearDown() {
        if let originalHiddenProviders {
            UserDefaults.standard.set(originalHiddenProviders, forKey: "hiddenProviders")
        } else {
            UserDefaults.standard.removeObject(forKey: "hiddenProviders")
        }

        if let originalProviderOrder {
            UserDefaults.standard.set(originalProviderOrder, forKey: "providerOrder")
        } else {
            UserDefaults.standard.removeObject(forKey: "providerOrder")
        }

        super.tearDown()
    }

    // MARK: - QuotaProvider.allCases order

    func testProviderAllCasesOrder() {
        XCTAssertEqual(
            QuotaProvider.allCases,
            [.copilot, .claude, .codex, .gemini]
        )
    }

    // MARK: - QuotaProvider.isCollapsible

    func testIsCollapsibleValues() {
        XCTAssertTrue(QuotaProvider.copilot.isCollapsible)
        XCTAssertTrue(QuotaProvider.claude.isCollapsible)
        XCTAssertTrue(QuotaProvider.codex.isCollapsible)
        XCTAssertTrue(QuotaProvider.gemini.isCollapsible)
    }

    // MARK: - QuotaProvider.displayName

    func testCopilotDisplayName() {
        XCTAssertEqual(QuotaProvider.copilot.displayName, "Copilot")
    }

    // MARK: - CopilotQuotaBuilder.makeErrorCard

    func testMakeErrorCardPopulatesFields() {
        let error = CopilotDesktopError.sessionUnavailable
        let card = CopilotQuotaBuilder.makeErrorCard(error: error)

        XCTAssertEqual(card.id, "copilot-error")
        XCTAssertEqual(card.provider, .copilot)
        XCTAssertEqual(card.title, "Copilot")
        XCTAssertNil(card.subtitle)
        XCTAssertEqual(card.planLabel, "错误")
        XCTAssertTrue(card.windows.isEmpty)
        XCTAssertEqual(card.errorMessage, "Copilot 会话不可用")
    }

    // MARK: - compactLabel "本月" → "月"

    func testCompactLabelMonthly() {
        let row = QuotaWindowRow(
            id: "copilot-monthly",
            label: "本月",
            remainingPercent: 97,
            resetLabel: "05/01",
            valueText: "291 剩余"
        )
        XCTAssertEqual(row.compactLabel, "月")
    }

    // MARK: - QuotaMenuViewModel.toggleExpanded

    @MainActor
    func testToggleExpandedSequence() {
        let vm = QuotaMenuViewModel()

        XCTAssertTrue(vm.expandedProviders.isEmpty)

        vm.toggleExpanded(.codex)
        XCTAssertEqual(vm.expandedProviders, [.codex])

        vm.toggleExpanded(.gemini)
        XCTAssertEqual(vm.expandedProviders, [.codex, .gemini])

        vm.toggleExpanded(.gemini)
        XCTAssertEqual(vm.expandedProviders, [.codex])
    }

    @MainActor
    func testToggleExpandedWorksForAllProviders() {
        let vm = QuotaMenuViewModel()

        vm.toggleExpanded(.copilot)
        XCTAssertTrue(vm.expandedProviders.contains(.copilot))

        vm.toggleExpanded(.claude)
        XCTAssertTrue(vm.expandedProviders.contains(.claude))

        vm.toggleExpanded(.copilot)
        XCTAssertFalse(vm.expandedProviders.contains(.copilot))
    }

    func testCopilotQuotaBuilderBuildsMonthlyQuotaCard() {
        let card = CopilotQuotaBuilder.makeCard(
            user: CopilotUserResponse(
                login: "TestUser",
                accessTypeSKU: "monthly_subscriber_quota",
                copilotPlan: "individual",
                quotaResetDate: "2026-05-01",
                quotaResetDateUTC: "2026-05-01T00:00:00.000Z",
                quotaSnapshots: CopilotQuotaSnapshots(
                    premiumInteractions: CopilotQuotaSnapshot(
                        percentRemaining: 92.5,
                        quotaRemaining: 277.6,
                        remaining: 277,
                        entitlement: 300
                    )
                )
            )
        )

        XCTAssertEqual(card.provider, .copilot)
        XCTAssertEqual(card.title, "TestUser")
        XCTAssertEqual(card.planLabel, "PRO")
        XCTAssertEqual(card.windows.count, 1)
        XCTAssertEqual(card.windows.first?.label, "本月")
        XCTAssertEqual(card.windows.first?.remainingPercent, 93)
        XCTAssertEqual(card.windows.first?.valueText, "93%/22.4")
        XCTAssertNil(card.windows.first?.progressText)
        XCTAssertNil(card.windows.first?.metricSummary)
        XCTAssertNil(card.windows.first?.detailText)
        XCTAssertEqual(card.windows.first?.resetLabel, "05/01 · 300")
    }

    func testCopilotQuotaBuilderPreservesFractionalPrecision() {
        let card = CopilotQuotaBuilder.makeCard(
            user: CopilotUserResponse(
                login: "TestUser",
                accessTypeSKU: "monthly_subscriber_quota",
                copilotPlan: "individual",
                quotaResetDate: "2026-05-01",
                quotaResetDateUTC: "2026-05-01T00:00:00.000Z",
                quotaSnapshots: CopilotQuotaSnapshots(
                    premiumInteractions: CopilotQuotaSnapshot(
                        percentRemaining: 94.89,
                        quotaRemaining: 284.67,
                        remaining: 285,
                        entitlement: 300
                    )
                )
            )
        )

        XCTAssertEqual(card.windows.first?.valueText, "95%/15.33")
        XCTAssertEqual(card.windows.first?.resetLabel, "05/01 · 300")
        XCTAssertNil(card.windows.first?.metricSummary)
        XCTAssertNil(card.windows.first?.detailText)
    }

    func testCopilotQuotaBuilderOmitsTrailingZerosInUsedAmountDisplay() {
        let card = CopilotQuotaBuilder.makeCard(
            user: CopilotUserResponse(
                login: "TestUser",
                accessTypeSKU: "monthly_subscriber_quota",
                copilotPlan: "individual",
                quotaResetDate: "2026-05-01",
                quotaResetDateUTC: "2026-05-01T00:00:00.000Z",
                quotaSnapshots: CopilotQuotaSnapshots(
                    premiumInteractions: CopilotQuotaSnapshot(
                        percentRemaining: 77.67,
                        quotaRemaining: 233,
                        remaining: 233,
                        entitlement: 300
                    )
                )
            )
        )

        XCTAssertEqual(card.windows.first?.valueText, "78%/67")
        XCTAssertEqual(card.windows.first?.resetLabel, "05/01 · 300")
    }

    // MARK: - Hidden Providers

    @MainActor
    func testSetProviderHidden() {
        UserDefaults.standard.removeObject(forKey: "hiddenProviders")
        let vm = QuotaMenuViewModel()
        XCTAssertFalse(vm.isProviderHidden(.codex))

        vm.setProviderHidden(.codex, hidden: true)
        XCTAssertTrue(vm.isProviderHidden(.codex))
        XCTAssertTrue(vm.hiddenProviders.contains(.codex))

        vm.setProviderHidden(.codex, hidden: false)
        XCTAssertFalse(vm.isProviderHidden(.codex))
        XCTAssertFalse(vm.hiddenProviders.contains(.codex))
    }

    @MainActor
    func testCannotHideAllProviders() {
        UserDefaults.standard.removeObject(forKey: "hiddenProviders")
        let vm = QuotaMenuViewModel()
        vm.setProviderHidden(.copilot, hidden: true)
        vm.setProviderHidden(.claude, hidden: true)
        vm.setProviderHidden(.codex, hidden: true)
        // Attempt to hide the last one should fail
        vm.setProviderHidden(.gemini, hidden: true)
        XCTAssertFalse(vm.isProviderHidden(.gemini))
        XCTAssertEqual(vm.hiddenProviders.count, 3)
    }

    // MARK: - Settings Panel Presentation

    @MainActor
    func testHandlePanelClosedDoesNotClearSettingsVisibility() {
        let vm = QuotaMenuViewModel()
        vm.isShowingConfiguration = true

        vm.handlePanelClosed()

        XCTAssertTrue(vm.isShowingConfiguration)
    }

    func testSettingsWindowPlacementCentersWindowInsideAnchorScreen() {
        let anchorFrame = NSRect(x: 1500, y: 720, width: 32, height: 24)
        let secondaryVisibleFrame = NSRect(x: 1440, y: 0, width: 1440, height: 900)
        let frame = SettingsWindowPlacement.frame(
            windowSize: NSSize(width: 720, height: 520),
            anchorFrame: anchorFrame,
            visibleFrame: secondaryVisibleFrame
        )

        XCTAssertEqual(frame.origin.x, 1800, accuracy: 0.1)
        XCTAssertEqual(frame.origin.y, 190, accuracy: 0.1)
    }

    func testSettingsWindowPlacementClampsOversizedWindowIntoVisibleFrame() {
        let anchorFrame = NSRect(x: 20, y: 860, width: 24, height: 24)
        let visibleFrame = NSRect(x: 0, y: 0, width: 1280, height: 700)
        let frame = SettingsWindowPlacement.frame(
            windowSize: NSSize(width: 1360, height: 760),
            anchorFrame: anchorFrame,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(frame.origin.x, 0, accuracy: 0.1)
        XCTAssertEqual(frame.origin.y, 0, accuracy: 0.1)
        XCTAssertEqual(frame.size.width, 1280, accuracy: 0.1)
        XCTAssertEqual(frame.size.height, 700, accuracy: 0.1)
    }

    func testSegmentedQuotaBarLayoutKeepsRemainingProgressOnLeadingSide() {
        let layout = SegmentedQuotaBarLayout.forRemainingPercent(79)

        XCTAssertEqual(layout.leadingFraction, 0.79, accuracy: 0.001)
        XCTAssertEqual(layout.trailingFraction, 0.21, accuracy: 0.001)
    }

    func testCompactMetricLineLayoutMatchesStandardRowGrid() {
        let layout = QuotaMetricLineLayout.compact

        XCTAssertEqual(layout.labelWidth, 26, accuracy: 0.001)
        XCTAssertEqual(layout.valueWidth, 72, accuracy: 0.001)
        XCTAssertEqual(layout.resetWidth, 78, accuracy: 0.001)
        XCTAssertEqual(layout.columnSpacing, 5, accuracy: 0.001)
        XCTAssertEqual(layout.barHeight, 3.5, accuracy: 0.001)
        XCTAssertEqual(layout.barLeadingOffset, 31, accuracy: 0.001)
        XCTAssertEqual(layout.barTrailingReservedWidth, 160, accuracy: 0.001)
    }

    func testCompactTrailingSummaryTextCombinesResetAndTotalIntoSingleLine() {
        let row = QuotaWindowRow(
            id: "copilot-monthly",
            label: "本月",
            remainingPercent: 79,
            resetLabel: "05/01",
            valueText: "236.3",
            detailText: "总量 300"
        )

        XCTAssertEqual(row.compactTrailingSummaryText, "05/01 · 300")
    }

    func testReplacingIncrementalCardUsesMatchingAccountIDInsteadOfCurrentIndex() {
        let currentCards = [
            QuotaCard(
                id: "copilot-loading-a",
                provider: .copilot,
                title: "Alpha",
                subtitle: "加载中...",
                planLabel: "—",
                windows: [],
                errorMessage: nil,
                accountId: "a",
                isActiveAccount: true
            ),
            QuotaCard(
                id: "copilot-loading-b",
                provider: .copilot,
                title: "Beta",
                subtitle: "加载中...",
                planLabel: "—",
                windows: [],
                errorMessage: nil,
                accountId: "b",
                isActiveAccount: false
            ),
        ]

        let replacement = QuotaCard(
            id: "copilot-oauth-b",
            provider: .copilot,
            title: "Beta",
            subtitle: nil,
            planLabel: "PRO",
            windows: [],
            errorMessage: nil,
            accountId: "b",
            isActiveAccount: false
        )

        let updated = QuotaMenuViewModel.replacingIncrementalCard(in: currentCards, with: replacement)
        XCTAssertEqual(updated[0].accountId, "a")
        XCTAssertEqual(updated[0].id, "copilot-loading-a")
        XCTAssertEqual(updated[1].accountId, "b")
        XCTAssertEqual(updated[1].id, "copilot-oauth-b")
    }

    @MainActor
    func testProviderHeaderVisibilityControlsStayMappedToTheirProviders() {
        let states = AccountsPane.providerHeaderVisibilityStates(
            providers: AccountsPaneViewModel.oauthProviders,
            hiddenProviders: [.claude]
        )

        XCTAssertEqual(states.map(\.provider), AccountsPaneViewModel.oauthProviders)
        XCTAssertEqual(states.map(\.title), AccountsPaneViewModel.oauthProviders.map(\.displayName))
        XCTAssertTrue(states.allSatisfy(\.showsInlineToggle))
        XCTAssertEqual(states.first(where: { $0.provider == .claude })?.isVisible, false)
        XCTAssertEqual(states.first(where: { $0.provider == .gemini })?.isToggleDisabled, false)
    }
}
