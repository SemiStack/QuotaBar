import SwiftUI

struct QuotaListView: View {
    @ObservedObject var viewModel: QuotaMenuViewModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if viewModel.sections.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("QuotaBar")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    viewModel.manualRefresh()
                } label: {
                    if viewModel.isRefreshing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(viewModel.isRefreshing)
                .accessibilityLabel("刷新")
            }

            ToolbarItem(placement: .topBarLeading) {
                if let last = viewModel.lastRefreshedAt {
                    Text(Self.relativeFormatter.localizedString(for: last, relativeTo: Date()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .refreshable {
            viewModel.manualRefresh()
            // Yield to let UI reflect refreshing state
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        .overlay(alignment: .top) {
            if let notice = viewModel.noticeMessage {
                Text(notice)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.green.opacity(0.35), lineWidth: 1))
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.default, value: viewModel.noticeMessage)
    }

    static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        f.locale = Locale(identifier: "zh-CN")
        return f
    }()

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "gauge.with.dots.needle.0percent")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tertiary)
            Text("还没有可显示的额度")
                .font(.headline)
            Text("前往「设置」标签添加 Copilot / Claude / Codex / Gemini 账号。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if let err = viewModel.errorMessage {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 32)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var list: some View {
        List {
            if let err = viewModel.errorMessage {
                Section {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }

            ForEach(viewModel.sections) { section in
                Section {
                    ForEach(section.cards) { card in
                        QuotaCardRow(card: card, viewModel: viewModel)
                    }
                } header: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(ProviderTint.color(for: section.provider, colorScheme: colorScheme))
                            .frame(width: 8, height: 8)
                        Text(section.provider.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        let state = viewModel.providerState(for: section.provider)
                        if state.status.isRefreshing {
                            ProgressView().controlSize(.mini)
                        } else if case .failed = state.status {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                        }
                        Spacer()
                        Button {
                            viewModel.refreshProvider(section.provider)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .disabled(state.status.isRefreshing)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

private struct QuotaCardRow: View {
    let card: QuotaCard
    @ObservedObject var viewModel: QuotaMenuViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(card.title)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        if card.isActiveAccount && hasMultipleAccounts {
                            Text("活跃")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.12), in: Capsule())
                        }
                    }
                    if let subtitle = card.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 8)

                Text(card.planLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }

            if let err = card.errorMessage {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if card.windows.isEmpty {
                HStack {
                    ProgressView().controlSize(.mini)
                    Text("加载中...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(card.windows) { window in
                    QuotaWindowRowView(window: window)
                }
            }

            if hasMultipleAccounts, let accountId = card.accountId, !card.isActiveAccount {
                Button {
                    viewModel.switchToAccount(id: accountId, provider: card.provider)
                } label: {
                    HStack(spacing: 6) {
                        if viewModel.isSwitchingAccount {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.left.arrow.right.circle")
                                .font(.caption)
                        }
                        Text("切换到该账号")
                            .font(.caption.weight(.medium))
                    }
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.isSwitchingAccount)
            }
        }
        .padding(.vertical, 4)
    }

    private var hasMultipleAccounts: Bool {
        viewModel.oauthAccounts(for: card.provider).count > 1
    }
}

private struct QuotaWindowRowView: View {
    let window: QuotaWindowRow
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(window.label)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(window.remainingText)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(accent)
                    .monospacedDigit()
                if !window.resetLabel.isEmpty {
                    Text(window.resetLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if window.showsProgressBar, let pct = window.progressBarPercent {
                ProgressView(value: Double(pct), total: 100)
                    .progressViewStyle(.linear)
                    .tint(accent)
            }
            if let detail = window.detailText, !detail.isEmpty {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var accent: Color {
        ProviderTint.healthAccent(remainingPercent: window.remainingPercent, colorScheme: colorScheme)
    }
}
