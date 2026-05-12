import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class AccountsIOSViewModel: ObservableObject {
    @Published var accounts: [OAuthAccount] = []
    @Published var isAddingGemini = false
    @Published var isAddingCopilot = false
    @Published var isAddingCodex = false
    @Published var isAddingClaude = false
    @Published var copilotDeviceCode: DeviceCodeResponse? = nil
    @Published var copilotFlowStatus: String? = nil
    @Published var errorMessage: String? = nil
    @Published var accountToDelete: OAuthAccount? = nil

    private var copilotFlowTask: Task<Void, Never>?
    private var geminiFlowTask: Task<Void, Never>?
    private var codexFlowTask: Task<Void, Never>?
    private var claudeFlowTask: Task<Void, Never>?

    static let oauthProviders: [QuotaProvider] = [.gemini, .copilot, .codex, .claude]

    func loadAccounts() async {
        accounts = await AccountStore.shared.allAccounts()
    }

    func accounts(for provider: QuotaProvider) -> [OAuthAccount] {
        accounts.filter { $0.provider == provider }
    }

    // MARK: - Gemini

    func addGeminiAccount() {
        guard !isAddingGemini else { return }
        isAddingGemini = true
        errorMessage = nil

        geminiFlowTask = Task {
            do {
                let client = GeminiOAuthClient()
                _ = try await client.startLogin { url in
                    PlatformBridge.openURL(url)
                }
                await loadAccounts()
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
                Log.error("Gemini 添加账号失败：\(error.localizedDescription)")
            }
            isAddingGemini = false
        }
    }

    func cancelGeminiFlow() {
        geminiFlowTask?.cancel()
        geminiFlowTask = nil
        isAddingGemini = false
    }

    // MARK: - Copilot device flow

    func startCopilotDeviceFlow() {
        guard !isAddingCopilot else { return }
        isAddingCopilot = true
        errorMessage = nil
        copilotDeviceCode = nil
        copilotFlowStatus = nil

        copilotFlowTask = Task {
            do {
                let client = CopilotOAuthClient()
                _ = try await client.startLogin { [weak self] deviceCode in
                    Task { @MainActor in
                        self?.copilotDeviceCode = deviceCode
                        self?.copilotFlowStatus = "等待授权中..."
                    }
                }
                copilotFlowStatus = nil
                copilotDeviceCode = nil
                await loadAccounts()
            } catch is CancellationError {
                copilotFlowStatus = nil
            } catch {
                errorMessage = error.localizedDescription
                Log.error("Copilot 添加账号失败：\(error.localizedDescription)")
            }
            isAddingCopilot = false
            copilotDeviceCode = nil
        }
    }

    func cancelCopilotFlow() {
        copilotFlowTask?.cancel()
        copilotFlowTask = nil
        isAddingCopilot = false
        copilotDeviceCode = nil
        copilotFlowStatus = nil
    }

    // MARK: - Codex / Claude

    func startCodexAuthFlow() {
        guard !isAddingCodex else { return }
        isAddingCodex = true
        errorMessage = nil
        codexFlowTask = Task {
            do {
                let client = CodexOAuthClient()
                _ = try await client.startLogin()
                await loadAccounts()
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
                Log.error("Codex 添加账号失败：\(error.localizedDescription)")
            }
            isAddingCodex = false
        }
    }

    func cancelCodexFlow() {
        codexFlowTask?.cancel()
        codexFlowTask = nil
        isAddingCodex = false
    }

    func startClaudeAuthFlow() {
        guard !isAddingClaude else { return }
        isAddingClaude = true
        errorMessage = nil
        claudeFlowTask = Task {
            do {
                let client = ClaudeOAuthClient()
                _ = try await client.startLogin()
                await loadAccounts()
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
                Log.error("Claude 添加账号失败：\(error.localizedDescription)")
            }
            isAddingClaude = false
        }
    }

    func cancelClaudeFlow() {
        claudeFlowTask?.cancel()
        claudeFlowTask = nil
        isAddingClaude = false
    }

    func cancelAllFlows() {
        cancelGeminiFlow()
        cancelCopilotFlow()
        cancelCodexFlow()
        cancelClaudeFlow()
    }

    func removeAccount(_ account: OAuthAccount) async {
        errorMessage = nil
        do {
            try await AccountStore.shared.removeAccount(id: account.id)
            await loadAccounts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct AccountsView: View {
    @ObservedObject var viewModel: QuotaMenuViewModel
    @StateObject private var vm = AccountsIOSViewModel()

    var body: some View {
        List {
            ForEach(AccountsIOSViewModel.oauthProviders, id: \.rawValue) { provider in
                providerSection(provider: provider)
            }

            if let err = vm.errorMessage {
                Section {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("账号管理")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { vm.cancelAllFlows() }
        .onChange(of: viewModel.oauthAccounts.count) { _, _ in
            Task { await refreshQuotaState() }
        }
        .alert(
            "确认删除",
            isPresented: Binding(
                get: { vm.accountToDelete != nil },
                set: { if !$0 { vm.accountToDelete = nil } }
            ),
            presenting: vm.accountToDelete
        ) { account in
            Button("删除", role: .destructive) {
                Task { await vm.removeAccount(account) }
            }
            Button("取消", role: .cancel) {}
        } message: { account in
            Text("确定要删除账号 \(account.email ?? account.login ?? account.id) 吗？")
        }
    }

    @ViewBuilder
    private func providerSection(provider: QuotaProvider) -> some View {
        let providerAccounts = viewModel.oauthAccounts(for: provider)

        Section {
            if providerAccounts.isEmpty {
                Text("暂无 \(provider.displayName) 账号")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                ForEach(providerAccounts) { account in
                    accountRow(account: account)
                }
            }

            if provider == .copilot, vm.isAddingCopilot, let code = vm.copilotDeviceCode {
                copilotDeviceFlowView(code: code)
            }

            addButton(for: provider)
        } header: {
            Text(provider.displayName)
        }
    }

    private func accountRow(account: OAuthAccount) -> some View {
        HStack(spacing: 10) {
            Image(systemName: account.email != nil ? "envelope.fill" : "person.fill")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.email ?? account.login ?? account.id)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if let login = account.login, account.email != nil, login != account.email {
                    Text(login)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if account.isActive {
                Text("活跃")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.12), in: Capsule())
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                vm.accountToDelete = account
            } label: {
                Label("删除", systemImage: "trash")
            }
            if !account.isActive {
                Button {
                    viewModel.switchToAccount(id: account.id, provider: account.provider)
                    Task {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        await vm.loadAccounts()
                    }
                } label: {
                    Label("激活", systemImage: "checkmark.circle")
                }
                .tint(.blue)
            }
        }
    }

    @ViewBuilder
    private func addButton(for provider: QuotaProvider) -> some View {
        switch provider {
        case .gemini:
            actionButton(
                title: "添加 Gemini 账号",
                isBusy: vm.isAddingGemini,
                action: vm.addGeminiAccount
            )
        case .copilot:
            actionButton(
                title: "添加 Copilot 账号",
                isBusy: vm.isAddingCopilot && vm.copilotDeviceCode == nil,
                action: vm.startCopilotDeviceFlow
            )
        case .codex:
            actionButton(
                title: "添加 Codex 账号",
                isBusy: vm.isAddingCodex,
                action: vm.startCodexAuthFlow
            )
        case .claude:
            actionButton(
                title: "添加 Claude 账号",
                isBusy: vm.isAddingClaude,
                action: vm.startClaudeAuthFlow
            )
        }
    }

    private func actionButton(title: String, isBusy: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "plus.circle.fill")
                }
                Text(title)
            }
        }
        .disabled(isBusy)
    }

    private func copilotDeviceFlowView(code: DeviceCodeResponse) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("登录 GitHub Copilot")
                .font(.subheadline.weight(.semibold))
            Text("在浏览器中输入下方验证码，授权完成后会自动返回：")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Text(code.userCode)
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

                Button {
                    PlatformBridge.copyToPasteboard(code.userCode)
                } label: {
                    Label("复制", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            HStack {
                Button {
                    if let url = URL(string: code.verificationUri) {
                        PlatformBridge.openURL(url)
                    }
                } label: {
                    Label("打开浏览器", systemImage: "globe")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                if let status = vm.copilotFlowStatus {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button(role: .cancel) {
                    vm.cancelCopilotFlow()
                } label: {
                    Text("取消")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 6)
    }

    @MainActor
    private func refreshQuotaState() async {
        // Trigger a fresh quota refresh after account changes.
        viewModel.manualRefresh()
    }
}
