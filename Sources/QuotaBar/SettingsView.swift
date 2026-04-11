import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: QuotaMenuViewModel
    @Environment(\.colorScheme) private var colorScheme

    private var detailBackground: Color {
        colorScheme == .dark ? Color(nsColor: .underPageBackgroundColor) : Color.white
    }

    var body: some View {
        AccountsPane(viewModel: viewModel)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(detailBackground)
    }
}

struct PaneHeader: View {
    let title: String
    let summary: String
    var badgeText: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.primary)

                if let badgeText {
                    Text(badgeText)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.10), in: Capsule())
                }
            }

            Text(summary)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }
}

struct SettingsGroup<Content: View, HeaderAccessory: View>: View {
    let title: String
    let footer: String?
    let content: Content
    let headerAccessory: HeaderAccessory
    @Environment(\.colorScheme) private var colorScheme

    init(
        title: String,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) where HeaderAccessory == EmptyView {
        self.title = title
        self.footer = footer
        self.content = content()
        self.headerAccessory = EmptyView()
    }

    init(
        title: String,
        footer: String? = nil,
        @ViewBuilder headerAccessory: () -> HeaderAccessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.footer = footer
        self.content = content()
        self.headerAccessory = headerAccessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 12)

                headerAccessory
            }

            VStack(spacing: 0) {
                content
            }
            .background(
                colorScheme == .dark ? Color(nsColor: .controlBackgroundColor) : Color.white,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.28), lineWidth: 1)
            )

            if let footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SettingsFormRow<Content: View>: View {
    let label: String
    let content: Content

    init(label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

struct SettingsRowDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 18)
    }
}

struct SettingsStatusMessage: View {
    let systemName: String
    let tint: Color
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: systemName)
                .foregroundStyle(tint)

            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            colorScheme == .dark ? Color(nsColor: .controlBackgroundColor) : Color.white,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.28), lineWidth: 1)
        )
    }
}

struct ProviderVisibilityRow: View {
    @ObservedObject var viewModel: QuotaMenuViewModel
    let provider: QuotaProvider

    var body: some View {
        let isHidden = viewModel.isProviderHidden(provider)
        let visibleCount = QuotaProvider.allCases.count - viewModel.hiddenProviders.count
        let isLastVisible = !isHidden && visibleCount <= 1

        HStack(spacing: 12) {
            Circle()
                .fill(providerColor)
                .frame(width: 10, height: 10)

            Text(provider.displayName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)

            Spacer(minLength: 12)

            Toggle(
                "",
                isOn: Binding(
                    get: { !isHidden },
                    set: { viewModel.setProviderHidden(provider, hidden: !$0) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(isLastVisible)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var providerColor: Color {
        switch provider {
        case .copilot:
            return Color(nsColor: .labelColor)
        case .codex:
            return Color(nsColor: .systemBlue)
        case .claude:
            return Color(nsColor: .systemPurple)
        case .gemini:
            return Color(nsColor: .systemIndigo)
        }
    }
}

struct ProviderVisibilityToggle: View {
    @ObservedObject var viewModel: QuotaMenuViewModel
    let state: ProviderHeaderVisibilityState

    var body: some View {
        Toggle(
            "",
            isOn: Binding(
                get: { state.isVisible },
                set: { viewModel.setProviderHidden(state.provider, hidden: !$0) }
            )
        )
        .labelsHidden()
        .toggleStyle(.switch)
        .disabled(state.isToggleDisabled)
    }
}
