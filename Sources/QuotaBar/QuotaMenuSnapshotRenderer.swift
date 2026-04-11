import AppKit
import SwiftUI

@MainActor
enum QuotaMenuSnapshotRenderer {
    static func capture(viewModel: QuotaMenuViewModel, outputURL: URL) async throws -> NSSize {
        let rootView = QuotaMenuView(viewModel: viewModel, onQuit: {}, onShowSettings: {})
            .frame(width: QuotaPanelMetrics.width)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.appearance = nil
        hostingView.frame = NSRect(x: 0, y: 0, width: QuotaPanelMetrics.width, height: QuotaPanelMetrics.summaryMaxHeight)

        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.contentView = hostingView
        window.displayIfNeeded()

        hostingView.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        hostingView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let measuredHeight = min(
            max(viewModel.preferredSummaryHeight, QuotaPanelMetrics.summaryMinHeight),
            QuotaPanelMetrics.summaryMaxHeight
        )
        let finalSize = NSSize(width: QuotaPanelMetrics.width, height: ceil(measuredHeight))
        hostingView.setFrameSize(finalSize)
        window.setContentSize(finalSize)
        hostingView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(30))

        let bounds = NSRect(origin: .zero, size: finalSize)
        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw SnapshotError.bitmapCreationFailed
        }

        hostingView.cacheDisplay(in: bounds, to: bitmap)

        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw SnapshotError.pngEncodingFailed
        }

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try pngData.write(to: outputURL)
        return finalSize
    }
}

enum SnapshotError: LocalizedError {
    case bitmapCreationFailed
    case pngEncodingFailed

    var errorDescription: String? {
        switch self {
        case .bitmapCreationFailed:
            return "离屏截图失败：无法创建位图缓存。"
        case .pngEncodingFailed:
            return "离屏截图失败：无法导出 PNG。"
        }
    }
}
