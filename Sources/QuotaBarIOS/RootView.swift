import SwiftUI

struct RootView: View {
    @ObservedObject var viewModel: QuotaMenuViewModel
    @State private var selectedTab: Tab = .quotas

    enum Tab: Hashable {
        case quotas
        case settings
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                QuotaListView(viewModel: viewModel)
            }
            .tabItem {
                Label("额度", systemImage: "gauge.with.dots.needle.67percent")
            }
            .tag(Tab.quotas)

            NavigationStack {
                SettingsRootView(viewModel: viewModel)
            }
            .tabItem {
                Label("设置", systemImage: "gearshape.fill")
            }
            .tag(Tab.settings)
        }
        .tint(.blue)
    }
}
