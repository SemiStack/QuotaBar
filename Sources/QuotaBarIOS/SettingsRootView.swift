import SwiftUI

struct SettingsRootView: View {
    @ObservedObject var viewModel: QuotaMenuViewModel

    var body: some View {
        List {
            NavigationLink {
                AccountsView(viewModel: viewModel)
            } label: {
                Label("账号管理", systemImage: "person.crop.circle")
            }

            NavigationLink {
                ProviderVisibilityView(viewModel: viewModel)
            } label: {
                Label("显示与排序", systemImage: "rectangle.3.group")
            }

            Section("关于") {
                LabeledContent("已连接账号", value: "\(viewModel.oauthAccounts.count)")
                LabeledContent("应用版本", value: "iOS 1.0")
                Link(destination: URL(string: "https://github.com/SemiStack/QuotaBar")!) {
                    Label("项目主页", systemImage: "globe")
                }
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ProviderVisibilityView: View {
    @ObservedObject var viewModel: QuotaMenuViewModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        List {
            Section {
                ForEach(viewModel.providerOrder, id: \.self) { provider in
                    HStack(spacing: 12) {
                        Circle()
                            .fill(ProviderTint.color(for: provider, colorScheme: colorScheme))
                            .frame(width: 10, height: 10)
                        Text(provider.displayName)
                        Spacer()
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { !viewModel.isProviderHidden(provider) },
                                set: { viewModel.setProviderHidden(provider, hidden: !$0) }
                            )
                        )
                        .labelsHidden()
                        .disabled(!viewModel.isProviderHidden(provider)
                                  && (QuotaProvider.allCases.count - viewModel.hiddenProviders.count) <= 1)
                    }
                }
                .onMove(perform: move)
            } header: {
                Text("拖动右侧手柄可调整顺序")
            } footer: {
                Text("至少保留一个可见供应商。隐藏后该供应商不会出现在主面板。")
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("显示与排序")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func move(from source: IndexSet, to destination: Int) {
        guard let src = source.first else { return }
        let order = viewModel.providerOrder
        guard src < order.count else { return }
        let item = order[src]
        let dstIndex = destination > src ? destination - 1 : destination
        let clamped = min(max(dstIndex, 0), order.count - 1)
        guard clamped != src else { return }
        let target = order[clamped]
        viewModel.moveProvider(from: item, to: target)
    }
}
