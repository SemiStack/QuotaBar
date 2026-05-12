import XCTest
@testable import QuotaBar

@MainActor
final class LocalUISnapshotTests: XCTestCase {
    func testCaptureExpandedCopilotCardOffscreen() async throws {
        let processInfo = ProcessInfo.processInfo
        guard let outputPath = processInfo.environment["QUOTABAR_LOCAL_UI_SNAPSHOT_PATH"],
              outputPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw XCTSkip("Set QUOTABAR_LOCAL_UI_SNAPSHOT_PATH to enable local UI snapshot capture.")
        }

        let outputURL = URL(fileURLWithPath: outputPath)
        let viewModel = QuotaMenuViewModel()

        try await wait(
            timeout: 8,
            intervalMilliseconds: 50
        ) {
            viewModel.didLoadInitialConfiguration
        }

        guard viewModel.hasAnyAvailableSource else {
            throw XCTSkip("No local quota sources are configured on this machine.")
        }

        viewModel.refreshOnOpen()
        try await wait(
            timeout: 20,
            intervalMilliseconds: 100
        ) {
            viewModel.isRefreshing == false && viewModel.sections.isEmpty == false
        }

        guard viewModel.sections.contains(where: { $0.provider == .copilot }) else {
            throw XCTSkip("No active Copilot account is available for local UI snapshot capture.")
        }

        viewModel.toggleExpanded(.copilot)
        try await Task.sleep(for: .milliseconds(150))

        _ = try await QuotaMenuSnapshotRenderer.capture(viewModel: viewModel, outputURL: outputURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
    }

    private func wait(
        timeout: TimeInterval,
        intervalMilliseconds: UInt64,
        until condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(intervalMilliseconds))
        }

        XCTFail("Timed out after \(timeout)s waiting for local UI snapshot condition.")
    }
}
