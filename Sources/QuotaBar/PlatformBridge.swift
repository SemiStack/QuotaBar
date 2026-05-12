import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Cross-platform helpers shared by macOS (AppKit) and iOS (UIKit) targets.
enum PlatformBridge {
    static func copyToPasteboard(_ string: String) {
        #if canImport(AppKit)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = string
        #endif
    }

    static func openURL(_ url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #elseif canImport(UIKit)
        Task { @MainActor in
            UIApplication.shared.open(url)
        }
        #endif
    }
}
