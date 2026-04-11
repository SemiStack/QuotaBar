import AppKit
import SwiftUI

@main
struct QuotaBarApp: App {
    @NSApplicationDelegateAdaptor(StatusBarAppDelegate.self) private var appDelegate

    init() {
        if ProcessInfo.processInfo.environment["QUOTABAR_DEBUG_CAPTURE_MODE"] == "offscreen" {
            NSApplication.shared.setActivationPolicy(.prohibited)
        } else {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
