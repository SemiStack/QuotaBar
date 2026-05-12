import SwiftUI

@main
struct QuotaBarIOSApp: App {
    @StateObject private var viewModel = QuotaMenuViewModel()

    init() {
        Log.info("QuotaBar iOS 启动")
    }

    var body: some Scene {
        WindowGroup {
            RootView(viewModel: viewModel)
                .onAppear {
                    viewModel.refreshOnOpen()
                }
        }
    }
}
