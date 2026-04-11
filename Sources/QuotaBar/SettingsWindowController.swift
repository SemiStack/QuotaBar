import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private static let defaultSize = NSSize(width: 560, height: 520)
    private static let minSize = NSSize(width: 460, height: 420)

    private var window: NSWindow?
    private let viewModel: QuotaMenuViewModel
    private var onClose: (() -> Void)?
    private var windowDelegate: SettingsWindowDelegateHandler?

    init(viewModel: QuotaMenuViewModel) {
        self.viewModel = viewModel
    }

    var isVisible: Bool {
        window?.isVisible ?? false
    }

    var windowFrame: NSRect? {
        guard let window, window.isVisible else { return nil }
        return window.frame
    }

    func show(anchorFrame: NSRect?, onClose: @escaping () -> Void) {
        self.onClose = onClose

        if window == nil {
            window = createWindow()
        }

        guard let window else { return }

        if !window.isVisible,
           let visibleFrame = SettingsWindowPlacement.visibleFrame(for: anchorFrame) {
            let frame = SettingsWindowPlacement.frame(
                windowSize: window.frame.size == .zero ? Self.defaultSize : window.frame.size,
                anchorFrame: anchorFrame,
                visibleFrame: visibleFrame
            )
            window.setFrame(frame, display: false)
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        guard isVisible else { return }
        window?.close()
    }

    private func handleWindowClosed() {
        restoreAccessoryPolicyIfNeeded()
        let handler = onClose
        onClose = nil
        handler?()
    }

    private func restoreAccessoryPolicyIfNeeded() {
        let hasVisibleWindows = NSApp.windows.contains { window in
            window.isVisible && window !== self.window
                && !(window is NSPanel)
                && window.level == .normal
        }

        if !hasVisibleWindows {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func createWindow() -> NSWindow {
        let settingsView = SettingsView(viewModel: viewModel)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.title = "QuotaBar"
        window.titleVisibility = .hidden
        window.toolbarStyle = .unifiedCompact
        window.titlebarSeparatorStyle = .none
        window.titlebarAppearsTransparent = true
        window.contentViewController = NSHostingController(rootView: settingsView)
        window.setContentSize(Self.defaultSize)
        window.minSize = Self.minSize
        window.isReleasedWhenClosed = false
        window.appearance = nil

        let delegate = SettingsWindowDelegateHandler { [weak self] in
            self?.handleWindowClosed()
        }
        self.windowDelegate = delegate
        window.delegate = delegate

        return window
    }
}

private final class SettingsWindowDelegateHandler: NSObject, NSWindowDelegate {
    let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
