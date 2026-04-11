import AppKit
import SwiftUI

struct ProviderHeaderVisibilityState: Equatable {
    let provider: QuotaProvider
    let title: String
    let showsInlineToggle: Bool
    let isVisible: Bool
    let isToggleDisabled: Bool
}

// MARK: - AccountsPaneViewModel

@MainActor
final class AccountsPaneViewModel: ObservableObject {
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

    /// Providers that support direct OAuth login.
    static let oauthProviders: [QuotaProvider] = [.gemini, .copilot, .codex, .claude]

    /// Providers shown but not yet supporting direct auth.
    static let unsupportedProviders: [QuotaProvider] = []

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
                    NSWorkspace.shared.open(url)
                }
                await loadAccounts()
            } catch is CancellationError {
                // Ignored
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

    // MARK: - Copilot Device Flow

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

    func cancelAllFlows() {
        cancelGeminiFlow()
        cancelCopilotFlow()
        cancelCodexFlow()
        cancelClaudeFlow()
    }

    // MARK: - Codex Auth Code Flow (Browser-based)

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
                // Ignored
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

    // MARK: - Claude Auth Code Flow

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
                // Ignored
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

    // MARK: - Account Management

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

// MARK: - AccountsPane View

struct AccountsPane: View {
    /// Retained for interface consistency with other panes; will be used to trigger quota refresh after account changes.
    @ObservedObject var viewModel: QuotaMenuViewModel
    @StateObject private var accountsVM = AccountsPaneViewModel()
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PaneHeader(
                    title: "账号管理",
                    summary: "通过官方认证添加账号，管理供应商显示与排序。"
                )

                // OAuth-supported providers
                ForEach(AccountsPaneViewModel.oauthProviders, id: \.rawValue) { provider in
                    providerSection(for: provider)
                }

                // Unsupported providers
                ForEach(AccountsPaneViewModel.unsupportedProviders, id: \.rawValue) { provider in
                    unsupportedSection(for: provider)
                }

                Text("关闭后该供应商会从主面板隐藏。显示顺序以主面板拖拽为准。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let error = accountsVM.errorMessage {
                    SettingsStatusMessage(
                        systemName: "exclamationmark.triangle.fill",
                        tint: .red,
                        text: error
                    )
                }
            }
            .frame(maxWidth: 660, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 30)
        }
        .task { await accountsVM.loadAccounts() }
        .onDisappear { accountsVM.cancelAllFlows() }
        .alert(
            "确认删除",
            isPresented: Binding(
                get: { accountsVM.accountToDelete != nil },
                set: { if !$0 { accountsVM.accountToDelete = nil } }
            ),
            presenting: accountsVM.accountToDelete
        ) { account in
            Button("删除", role: .destructive) {
                Task { await accountsVM.removeAccount(account) }
            }
            Button("取消", role: .cancel) {}
        } message: { account in
            Text("确定要删除账号 \(account.email ?? account.login ?? account.id) 吗？")
        }
    }

    // MARK: - Provider Section (with accounts)

    @ViewBuilder
    private func providerSection(for provider: QuotaProvider) -> some View {
        let providerAccounts = accountsVM.accounts(for: provider)
        let headerState = Self.providerHeaderVisibilityState(
            provider: provider,
            hiddenProviders: viewModel.hiddenProviders
        )

        SettingsGroup(
            title: provider.displayName,
            headerAccessory: {
                ProviderVisibilityToggle(viewModel: viewModel, state: headerState)
            }
        ) {
            if providerAccounts.isEmpty {
                emptyRow(for: provider)
            } else {
                ForEach(Array(providerAccounts.enumerated()), id: \.element.id) { index, account in
                    accountRow(account: account)
                    if index < providerAccounts.count - 1 {
                        SettingsRowDivider()
                    }
                }
            }

            // Copilot device flow inline card
            if provider == .copilot, accountsVM.isAddingCopilot, let deviceCode = accountsVM.copilotDeviceCode {
                SettingsRowDivider()
                copilotDeviceFlowCard(deviceCode: deviceCode)
            }

            SettingsRowDivider()
            addAccountButton(for: provider)
        }
    }

    // MARK: - Empty Row

    private func emptyRow(for provider: QuotaProvider) -> some View {
        Text("暂无 \(provider.displayName) 账号")
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
    }

    // MARK: - Account Row

    private func accountRow(account: OAuthAccount) -> some View {
        HStack(spacing: 10) {
            Image(systemName: account.email != nil ? "envelope.fill" : "person.fill")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            Text(account.email ?? account.login ?? account.id)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)

            if account.isActive {
                Text("活跃")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.12), in: Capsule())
            }

            Spacer(minLength: 4)

            Button {
                accountsVM.accountToDelete = account
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - Add Account Button

    @ViewBuilder
    private func addAccountButton(for provider: QuotaProvider) -> some View {
        switch provider {
        case .gemini:
            Button {
                accountsVM.addGeminiAccount()
            } label: {
                HStack(spacing: 6) {
                    if accountsVM.isAddingGemini {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 13))
                    }
                    Text("添加 Gemini 账号")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .disabled(accountsVM.isAddingGemini)

        case .copilot:
            Button {
                accountsVM.startCopilotDeviceFlow()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 13))
                    Text("添加 Copilot 账号")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .disabled(accountsVM.isAddingCopilot)

        case .codex:
            Button {
                accountsVM.startCodexAuthFlow()
            } label: {
                HStack(spacing: 6) {
                    if accountsVM.isAddingCodex {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 13))
                    }
                    Text("添加 Codex 账号")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .disabled(accountsVM.isAddingCodex)

        case .claude:
            Button {
                accountsVM.startClaudeAuthFlow()
            } label: {
                HStack(spacing: 6) {
                    if accountsVM.isAddingClaude {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 13))
                    }
                    Text("添加 Claude Code 账号")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .disabled(accountsVM.isAddingClaude)
        }
    }

    // MARK: - Copilot Device Flow Card

    private func copilotDeviceFlowCard(deviceCode: DeviceCodeResponse) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("登录 GitHub Copilot")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)

            Text("请在浏览器中输入以下验证码：")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Text(deviceCode.userCode)
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(colorScheme == .dark ? Color(nsColor: .controlBackgroundColor) : Color.white)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 1)
                    )

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(deviceCode.userCode, forType: .string)
                } label: {
                    Label("复制", systemImage: "doc.on.clipboard")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            HStack(spacing: 10) {
                Button {
                    if let url = URL(string: deviceCode.verificationUri) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("打开浏览器", systemImage: "globe")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if let status = accountsVM.copilotFlowStatus {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text(status)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button {
                    accountsVM.cancelCopilotFlow()
                } label: {
                    Text("取消")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.03) : Color.black.opacity(0.02))
        )
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    // MARK: - Unsupported Provider Section

    @ViewBuilder
    private func unsupportedSection(for provider: QuotaProvider) -> some View {
        let headerState = Self.providerHeaderVisibilityState(
            provider: provider,
            hiddenProviders: viewModel.hiddenProviders
        )

        SettingsGroup(
            title: provider.displayName,
            headerAccessory: {
                ProviderVisibilityToggle(viewModel: viewModel, state: headerState)
            }
        ) {
            Text("尚未支持直接认证")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
        }
    }

    nonisolated static func providerHeaderVisibilityStates(
        providers: [QuotaProvider],
        hiddenProviders: Set<QuotaProvider>
    ) -> [ProviderHeaderVisibilityState] {
        providers.map { providerHeaderVisibilityState(provider: $0, hiddenProviders: hiddenProviders) }
    }

    nonisolated static func providerHeaderVisibilityState(
        provider: QuotaProvider,
        hiddenProviders: Set<QuotaProvider>
    ) -> ProviderHeaderVisibilityState {
        let isHidden = hiddenProviders.contains(provider)
        let visibleCount = QuotaProvider.allCases.count - hiddenProviders.count
        let isLastVisible = !isHidden && visibleCount <= 1

        return ProviderHeaderVisibilityState(
            provider: provider,
            title: provider.displayName,
            showsInlineToggle: true,
            isVisible: !isHidden,
            isToggleDisabled: isLastVisible
        )
    }
}
