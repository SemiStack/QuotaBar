import AppKit
import Combine
import CoreGraphics
import SwiftUI

@MainActor
final class StatusBarAppDelegate: NSObject, NSApplicationDelegate {
    private enum DebugCaptureMode: String {
        case none
        case preview
        case offscreen
    }

    private let viewModel = QuotaMenuViewModel()
    private let panel = StatusBarPanel(
        contentRect: NSRect(x: 0, y: 0, width: QuotaPanelMetrics.width, height: QuotaPanelMetrics.summaryMinHeight),
        styleMask: [.borderless, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var cancellables = Set<AnyCancellable>()
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var isTerminating = false
    private var debugPreviewWindow: NSWindow?
    private var debugCaptureWorkItem: DispatchWorkItem?
    private var hasCapturedDebugPreview = false
    private var pendingSettingsAnchorFrame: NSRect?
    private lazy var settingsController = SettingsWindowController(viewModel: viewModel)

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("应用启动，日志文件：\(AppLogger.logFilePath)")

        if shouldEnforceSingleInstance, focusExistingInstanceIfNeeded() {
            Log.info("检测到已有实例，当前实例直接退出")
            NSApp.terminate(nil)
            return
        }

        BrandIcon.installAsApplicationIcon()
        bindViewModel()

        if debugCaptureMode == .offscreen {
            startOffscreenCaptureFlow()
            return
        }

        configureStatusItem()
        configurePanel()
        updateStatusItem(isRefreshing: false, sections: [])
        updatePanelLayout(
            preferredSummaryHeight: viewModel.preferredSummaryHeight
        )

        if debugCaptureMode == .preview {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.showDebugPreviewPanel()
                self?.viewModel.refreshOnOpen()
            }
        } else if ProcessInfo.processInfo.environment["QUOTABAR_OPEN_PANEL_ON_LAUNCH"] == "1" {
            scheduleDebugPreviewOpen(attempt: 0)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.info("应用即将退出")
        debugCaptureWorkItem?.cancel()
        removeEventMonitors()
    }

    private var shouldEnforceSingleInstance: Bool {
        debugCaptureMode != .offscreen
    }

    private var debugCaptureMode: DebugCaptureMode {
        if let rawValue = ProcessInfo.processInfo.environment["QUOTABAR_DEBUG_CAPTURE_MODE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           let mode = DebugCaptureMode(rawValue: rawValue) {
            return mode
        }

        if ProcessInfo.processInfo.environment["QUOTABAR_DEBUG_WINDOW"] == "1" {
            return .preview
        }

        return .none
    }

    private var shouldActivateDebugPreview: Bool {
        ProcessInfo.processInfo.environment["QUOTABAR_DEBUG_ACTIVATE"] == "1"
    }

    private var debugCapturePath: String? {
        guard let rawPath = ProcessInfo.processInfo.environment["QUOTABAR_DEBUG_CAPTURE_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              rawPath.isEmpty == false else {
            return nil
        }
        return rawPath
    }

    private var shouldQuitAfterDebugCapture: Bool {
        (ProcessInfo.processInfo.environment["QUOTABAR_DEBUG_QUIT_AFTER_CAPTURE"] ?? "1") != "0"
    }

    private var debugCaptureDelay: TimeInterval {
        TimeInterval(ProcessInfo.processInfo.environment["QUOTABAR_DEBUG_CAPTURE_DELAY"] ?? "0.45") ?? 0.45
    }

    private func focusExistingInstanceIfNeeded() -> Bool {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let currentName = ProcessInfo.processInfo.processName
        let duplicates = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != currentPID && $0.localizedName == currentName
        }

        guard let existing = duplicates.first else {
            return false
        }

        _ = existing.activate()
        return true
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = BrandIcon.menuBarImage
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(togglePanel(_:))
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        button.setAccessibilityLabel("QuotaBar")
    }

    private func configurePanel() {
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .none
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentViewController = NSHostingController(
            rootView: QuotaMenuView(
                viewModel: viewModel,
                onQuit: { [weak self] in self?.requestTermination() },
                onShowSettings: { [weak self] in self?.toggleSettings() }
            )
            .frame(width: QuotaPanelMetrics.width)
        )
    }

    private func bindViewModel() {
        viewModel.$isRefreshing
            .combineLatest(viewModel.$sections)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRefreshing, sections in
                self?.updateStatusItem(isRefreshing: isRefreshing, sections: sections)
            }
            .store(in: &cancellables)

        viewModel.$isRefreshing
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.queueDebugPreviewCaptureIfReady()
            }
            .store(in: &cancellables)

        viewModel.$preferredSummaryHeight
            .receive(on: DispatchQueue.main)
            .sink { [weak self] preferredSummaryHeight in
                self?.updatePanelLayout(preferredSummaryHeight: preferredSummaryHeight)
            }
            .store(in: &cancellables)

        viewModel.$isShowingConfiguration
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.syncSettingsPresentation()
            }
            .store(in: &cancellables)
    }

    private func updateStatusItem(isRefreshing: Bool, sections: [QuotaSection]) {
        guard let button = statusItem.button else { return }
        button.image = BrandIcon.menuBarImage
        button.title = ""
        button.imagePosition = .imageOnly
        button.alphaValue = isRefreshing ? 0.82 : 1
        button.toolTip = statusTooltip(isRefreshing: isRefreshing, sections: sections)
    }

    private func updatePanelLayout(preferredSummaryHeight: CGFloat) {
        let targetHeight = min(max(preferredSummaryHeight, QuotaPanelMetrics.summaryMinHeight), QuotaPanelMetrics.summaryMaxHeight)
        resizePanel(height: targetHeight)
        resizeDebugPreviewWindow(height: targetHeight)
    }

    private func resizePanel(height: CGFloat) {
        let roundedHeight = ceil(height)
        let currentSize = panel.frame.size
        guard abs(currentSize.width - QuotaPanelMetrics.width) > 0.5 || abs(currentSize.height - roundedHeight) > 0.5 else {
            return
        }

        var frame = panel.frame
        frame.size = NSSize(width: QuotaPanelMetrics.width, height: roundedHeight)
        panel.setFrame(frame, display: panel.isVisible)

        if let button = statusItem.button {
            positionPanel(relativeTo: button)
        }
    }

    private func resizeDebugPreviewWindow(height: CGFloat) {
        guard let debugPreviewWindow else { return }
        let roundedHeight = ceil(max(height, QuotaPanelMetrics.summaryMinHeight))
        let currentSize = debugPreviewWindow.frame.size
        guard abs(currentSize.width - QuotaPanelMetrics.width) > 0.5 || abs(currentSize.height - roundedHeight) > 0.5 else {
            return
        }

        var frame = debugPreviewWindow.frame
        frame.size = NSSize(width: QuotaPanelMetrics.width, height: roundedHeight)
        debugPreviewWindow.setFrame(frame, display: debugPreviewWindow.isVisible)
        positionDebugPreviewWindow(debugPreviewWindow)
        queueDebugPreviewCaptureIfReady()
    }

    private func statusTooltip(isRefreshing: Bool, sections: [QuotaSection]) -> String {
        var parts = ["QuotaBar"]

        if let match = sections.lazy.compactMap({ section in
            section.cards.compactMap { card in
                card.primaryStatusRow.map { row in
                    (section.provider, card, row)
                }
            }.first
        }).first {
            let (provider, card, row) = match
            parts.append("\(provider.displayName) · \(card.title) · \(row.label) \(row.remainingText)")
            if row.resetLabel != "-" {
                parts.append("重置：\(row.resetLabel)")
            }
        }

        if isRefreshing {
            parts.append("刷新中")
        }

        return parts.joined(separator: "\n")
    }

    @objc
    private func togglePanel(_ sender: AnyObject?) {
        guard !isTerminating else {
            Log.debug("忽略状态栏点击：应用正在退出")
            return
        }

        guard let button = statusItem.button else { return }

        if panel.isVisible {
            Log.debug("关闭面板")
            closePanel(reason: "status-item-toggle")
            return
        }

        Log.debug("展示面板")
        showPanel(relativeTo: button)
        viewModel.refreshOnOpen()
    }

    private func showPanel(relativeTo button: NSStatusBarButton) {
        updatePanelLayout(
            preferredSummaryHeight: viewModel.preferredSummaryHeight
        )
        positionPanel(relativeTo: button)
        installEventMonitors()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func closePanel(reason: String = "unspecified") {
        removeEventMonitors()
        panel.orderOut(nil)
        viewModel.handlePanelClosed()
    }

    private func toggleSettings() {
        pendingSettingsAnchorFrame = currentSettingsAnchorFrame()
        // Always dismiss menu panel when toggling settings to avoid z-order issues
        closePanel(reason: "settings-toggle")
        viewModel.isShowingConfiguration.toggle()
    }

    private func positionPanel(relativeTo button: NSStatusBarButton) {
        guard let window = button.window else { return }
        let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let panelSize = panel.frame.size

        var originX = buttonFrame.midX - panelSize.width / 2
        originX = min(max(originX, visibleFrame.minX + 10), visibleFrame.maxX - panelSize.width - 10)

        let preferredY = buttonFrame.minY - panelSize.height - 8
        let originY = max(visibleFrame.minY + 10, preferredY)

        panel.setFrameOrigin(NSPoint(x: originX, y: originY))
    }

    private func installEventMonitors() {
        guard localEventMonitor == nil, globalEventMonitor == nil else { return }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                self.closePanel(reason: "escape-key")
                return nil
            }

            guard event.type != .keyDown else { return event }
            self.closePanelIfNeeded(at: NSEvent.mouseLocation)
            return event
        }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            guard let self else { return }
            self.closePanelIfNeeded(at: NSEvent.mouseLocation)
        }
    }

    private func scheduleDebugPreviewOpen(attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            if attempt < 4, let button = self.statusItem.button, button.window != nil {
                self.showPanel(relativeTo: button)
            } else {
                self.showDebugPreviewPanel()
            }
            self.viewModel.refreshOnOpen()
        }
    }

    private func showDebugPreviewPanel() {
        updatePanelLayout(
            preferredSummaryHeight: viewModel.preferredSummaryHeight
        )

        if debugPreviewWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: QuotaPanelMetrics.width, height: QuotaPanelMetrics.summaryMaxHeight),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.title = "QuotaBar Preview"
            window.titlebarAppearsTransparent = true
            window.backgroundColor = .windowBackgroundColor
            window.isMovableByWindowBackground = true
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.contentViewController = NSHostingController(
                rootView: QuotaMenuView(
                    viewModel: viewModel,
                    onQuit: { [weak self] in self?.requestTermination() },
                    onShowSettings: { [weak self] in self?.toggleSettings() }
                )
                .frame(width: QuotaPanelMetrics.width)
            )
            debugPreviewWindow = window
        }

        guard let debugPreviewWindow else { return }
        debugPreviewWindow.setContentSize(NSSize(width: QuotaPanelMetrics.width, height: max(panel.frame.height, QuotaPanelMetrics.summaryMinHeight)))
        positionDebugPreviewWindow(debugPreviewWindow)

        if shouldActivateDebugPreview {
            NSApp.activate(ignoringOtherApps: true)
            debugPreviewWindow.makeKeyAndOrderFront(nil)
        } else {
            debugPreviewWindow.orderFrontRegardless()
        }

        queueDebugPreviewCaptureIfReady()
    }

    private func positionDebugPreviewWindow(_ window: NSWindow) {
        guard let screen = preferredDebugPreviewScreen() else { return }
        let visibleFrame = screen.visibleFrame
        let padding: CGFloat = 18
        let originX = max(visibleFrame.minX + padding, visibleFrame.maxX - window.frame.width - padding)
        let originY = max(visibleFrame.minY + padding, visibleFrame.maxY - window.frame.height - padding)
        window.setFrameOrigin(NSPoint(x: originX, y: originY))
        Log.debug("调试预览窗口定位到屏幕：\(screen.localizedName)")
    }

    private func preferredDebugPreviewScreen() -> NSScreen? {
        let screens = NSScreen.screens
        guard screens.isEmpty == false else { return NSScreen.main }

        let requested = ProcessInfo.processInfo.environment["QUOTABAR_DEBUG_SCREEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let requested, requested.isEmpty == false else {
            return firstExternalScreen(in: screens) ?? mainScreen(in: screens) ?? screens.first
        }

        let normalized = requested.lowercased()
        if normalized == "external" || normalized == "secondary" {
            return firstExternalScreen(in: screens) ?? mainScreen(in: screens) ?? screens.first
        }

        if normalized == "main" || normalized == "primary" {
            return mainScreen(in: screens) ?? screens.first
        }

        if let index = Int(normalized) {
            let zeroBased = max(index - 1, 0)
            if screens.indices.contains(zeroBased) {
                return screens[zeroBased]
            }
        }

        if let matched = screens.first(where: { $0.localizedName.localizedCaseInsensitiveContains(requested) }) {
            return matched
        }

        return firstExternalScreen(in: screens) ?? mainScreen(in: screens) ?? screens.first
    }

    private func mainScreen(in screens: [NSScreen]) -> NSScreen? {
        let mainDisplayID = CGMainDisplayID()
        return screens.first { displayID(for: $0) == mainDisplayID }
    }

    private func firstExternalScreen(in screens: [NSScreen]) -> NSScreen? {
        guard let primaryScreen = mainScreen(in: screens) else {
            return screens.dropFirst().first ?? screens.first
        }
        return screens.first { displayID(for: $0) != displayID(for: primaryScreen) }
    }

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }

    private func queueDebugPreviewCaptureIfReady() {
        guard debugCaptureMode == .preview,
              let capturePath = debugCapturePath,
              let debugPreviewWindow,
              debugPreviewWindow.isVisible,
              hasCapturedDebugPreview == false,
              viewModel.isRefreshing == false else {
            return
        }

        debugCaptureWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.captureDebugPreview(to: capturePath)
        }
        debugCaptureWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + debugCaptureDelay, execute: workItem)
    }

    private func captureDebugPreview(to capturePath: String) {
        guard viewModel.isRefreshing == false else {
            queueDebugPreviewCaptureIfReady()
            return
        }

        guard let debugPreviewWindow,
              let contentView = debugPreviewWindow.contentView else {
            Log.error("调试截图失败：预览窗口不存在")
            return
        }

        let bounds = contentView.bounds
        guard let bitmap = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
            Log.error("调试截图失败：无法创建位图缓存")
            return
        }

        contentView.cacheDisplay(in: bounds, to: bitmap)

        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            Log.error("调试截图失败：无法导出 PNG")
            return
        }

        let outputURL = URL(fileURLWithPath: capturePath)

        do {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try pngData.write(to: outputURL)
            hasCapturedDebugPreview = true
            Log.info("调试预览截图已保存：\(outputURL.path)")

            if shouldQuitAfterDebugCapture {
                requestTermination()
            }
        } catch {
            Log.error("调试截图写入失败：\(error.localizedDescription)")
        }
    }

    private func startOffscreenCaptureFlow() {
        Task { [weak self] in
            await self?.runOffscreenCaptureFlow()
        }
    }

    private func runOffscreenCaptureFlow() async {
        guard let capturePath = debugCapturePath else {
            Log.error("离屏截图失败：未提供输出路径")
            requestTermination()
            return
        }

        await waitForInitialConfigurationLoad()

        if viewModel.hasAnyAvailableSource {
            Log.info("离屏截图开始刷新数据")
            viewModel.refreshOnOpen()
            await waitForRefreshCompletion()
        } else {
            Log.info("未检测到可用来源，离屏截图将输出当前配置界面")
        }

        do {
            let outputURL = URL(fileURLWithPath: capturePath)
            let imageSize = try await QuotaMenuSnapshotRenderer.capture(viewModel: viewModel, outputURL: outputURL)
            Log.info("离屏截图已保存：\(outputURL.path) (\(Int(imageSize.width))x\(Int(imageSize.height)))")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            Log.error("离屏截图失败：\(message)")
        }

        if shouldQuitAfterDebugCapture {
            requestTermination()
        }
    }

    private func waitForInitialConfigurationLoad(timeout: TimeInterval = 8.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while viewModel.didLoadInitialConfiguration == false, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func waitForRefreshCompletion(timeout: TimeInterval = 20.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        var sawRefreshStart = false

        while Date() < deadline {
            if viewModel.isRefreshing {
                sawRefreshStart = true
            }

            if sawRefreshStart == false,
               viewModel.isRefreshing == false,
               (viewModel.lastRefreshedAt != nil || viewModel.errorMessage != nil || viewModel.sections.isEmpty == false) {
                return
            }

            if sawRefreshStart, viewModel.isRefreshing == false {
                return
            }

            try? await Task.sleep(for: .milliseconds(80))
        }
    }

    private func removeEventMonitors() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
    }

    private func closePanelIfNeeded(at screenPoint: NSPoint) {
        guard panel.isVisible else { return }
        let buttonFrame = statusButtonFrame()
        let settingsFrame = settingsController.windowFrame
        if panel.frame.contains(screenPoint) { return }
        if let buttonFrame, buttonFrame.contains(screenPoint) { return }
        if let settingsFrame, settingsFrame.contains(screenPoint) {
            closePanel(reason: "settings-click")
            return
        }
        closePanel(reason: "outside-click")
    }

    private func statusButtonFrame() -> NSRect? {
        guard let button = statusItem.button,
              let window = button.window else {
            return nil
        }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func currentSettingsAnchorFrame() -> NSRect? {
        if panel.isVisible {
            return panel.frame
        }
        if debugPreviewWindow?.isVisible == true {
            return debugPreviewWindow?.frame
        }
        return statusButtonFrame()
    }

    private func requestTermination() {
        guard !isTerminating else { return }
        isTerminating = true

        Log.info("收到退出请求")
        debugCaptureWorkItem?.cancel()
        viewModel.cancelRefresh()
        closePanel(reason: "request-termination")

        if let button = statusItem.button {
            button.target = nil
            button.action = nil
        }

        NSStatusBar.system.removeStatusItem(statusItem)

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            NSApplication.shared.terminate(nil)
        }
    }

    private func syncSettingsPresentation() {
        if viewModel.isShowingConfiguration {
            let anchorFrame = pendingSettingsAnchorFrame ?? currentSettingsAnchorFrame()
            settingsController.show(anchorFrame: anchorFrame) { [weak self] in
                self?.viewModel.isShowingConfiguration = false
            }
            pendingSettingsAnchorFrame = nil
        } else {
            settingsController.close()
        }
    }
}

private final class StatusBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
