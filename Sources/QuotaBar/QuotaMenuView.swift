import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct QuotaMenuView: View {
    @ObservedObject var viewModel: QuotaMenuViewModel
    let onQuit: () -> Void
    let onShowSettings: () -> Void

    @State private var draggingProvider: QuotaProvider?

    @Environment(\.colorScheme) private var colorScheme

    private var shellTopTint: Color {
        colorScheme == .dark ? Color.white.opacity(0.04) : Color.white.opacity(0.95)
    }
    private var shellBottomTint: Color {
        colorScheme == .dark ? Color.white.opacity(0.02) : Color.white.opacity(0.91)
    }
    private var listContainerBackground: Color {
        colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.84)
    }
    private var rowBackground: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.97)
    }
    private var separatorColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.035)
    }
    private var skeletonFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)
    }
    private var badgeBackground: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color.white.opacity(0.9)
    }
    private var cardStrokeColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.white.opacity(0.72)
    }
    private var prominentDividerColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
    }
    private var quotaBarTrack: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.075)
    }

    private var healthyAccent: Color {
        colorScheme == .dark ? Color(hex: 0x64D2FF) : Color(nsColor: .systemBlue)
    }
    private var warningAccent: Color {
        colorScheme == .dark ? Color(hex: 0xFFD60A) : Color(nsColor: .systemOrange)
    }
    private var criticalAccent: Color {
        colorScheme == .dark ? Color(hex: 0xFF6961) : Color(nsColor: .systemRed)
    }
    private let mutedAccent = Color(nsColor: .secondaryLabelColor)
    private var claudeAccent: Color {
        colorScheme == .dark ? Color(hex: 0xD4A0FF) : Color(nsColor: .systemPurple)
    }
    private var geminiAccent: Color {
        colorScheme == .dark ? Color(hex: 0xA5B4FC) : Color(nsColor: .systemIndigo)
    }
    private let copilotAccent = Color(nsColor: .labelColor)

    var body: some View {
        summaryScene
            .frame(width: QuotaPanelMetrics.width)
    }

    private var summaryScene: some View {
        panelShell {
            ZStack {
                ScrollView(showsIndicators: false) {
                    summaryContent
                        .padding(.horizontal, 10)
                        .padding(.top, 11)
                        .padding(.bottom, 8)
                        .readHeight { height in
                            viewModel.updateSummaryPreferredHeight(height)
                        }
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .allowsHitTesting(!viewModel.isSwitchingAccount)

                if viewModel.isSwitchingAccount {
                    Color.black.opacity(0.3)
                        .overlay(
                            VStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.regular)
                                Text("切换账号中...")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                        )
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: viewModel.isSwitchingAccount)
        }
    }

    private func panelShell<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            PanelMaterialView(material: .popover)

            RoundedRectangle(cornerRadius: QuotaPanelMetrics.cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [shellTopTint, shellBottomTint],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .overlay(
            RoundedRectangle(cornerRadius: QuotaPanelMetrics.cornerRadius, style: .continuous)
                .stroke(colorScheme == .dark ? Color.white.opacity(0.12) : Color.white.opacity(0.84), lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: QuotaPanelMetrics.cornerRadius, style: .continuous)
                .stroke(separatorColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: QuotaPanelMetrics.cornerRadius, style: .continuous))
    }

    private var summaryContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            if let errorMessage = viewModel.errorMessage {
                inlineStatus(text: errorMessage, tone: .error)
            }

            summarySection
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                Text("额度")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)

                HStack(spacing: 4) {
                    toolbarButton(
                        systemName: "arrow.clockwise",
                        tint: viewModel.isRefreshing ? warningAccent : healthyAccent,
                        action: viewModel.manualRefresh
                    )
                    .accessibilityLabel("刷新")

                    toolbarButton(
                        systemName: "gearshape",
                        tint: viewModel.isShowingConfiguration ? healthyAccent : mutedAccent,
                        action: onShowSettings
                    )
                    .accessibilityLabel("设置")

                    toolbarButton(
                        systemName: "power",
                        tint: mutedAccent,
                        action: onQuit
                    )
                    .accessibilityLabel("退出应用")
                }
            }

            HStack(spacing: 6) {
                toolbarPill(text: connectionText, tint: connectionTint)

                Text(accountCountText)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if let refreshed = viewModel.lastRefreshedAt {
                    Text(formattedHeader(date: refreshed))
                        .font(.system(size: 8, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var summarySection: some View {
        Group {
            if viewModel.isRefreshing && viewModel.sections.isEmpty && viewModel.isShowingConfiguration == false {
                loadingListSection
            } else if viewModel.sections.isEmpty {
                emptyStateSection
            } else {
                summaryListSection
            }
        }
    }

    private var loadingListSection: some View {
        VStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { _ in
                loadingCard
            }
        }
        .padding(5)
        .background(listContainerShape.fill(listContainerBackground))
        .overlay(listContainerShape.stroke(separatorColor.opacity(0.9), lineWidth: 1))
    }

    private var loadingCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(skeletonFill)
                .frame(width: 110, height: 11)

            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(skeletonFill)
                        .frame(width: 24, height: 7)
                    RoundedRectangle(cornerRadius: 999, style: .continuous)
                        .fill(skeletonFill)
                        .frame(height: 3.5)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(skeletonFill)
                        .frame(width: 34, height: 7)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(skeletonFill)
                        .frame(width: 72, height: 7)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(rowShape.fill(rowBackground))
    }

    private var emptyStateSection: some View {
        Group {
            if viewModel.hasAnyAvailableSource {
                inlineStatus(
                    text: "暂时没有可显示额度",
                    detail: "如果 Claude 官方 App 或 Codex 已登录，试试手动刷新一次。",
                    tone: .neutral
                )
            } else {
                onboardingCard
            }
        }
    }

    private var onboardingCard: some View {
        Button(action: onShowSettings) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(healthyAccent)

                    Text("添加 AI 账号")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }

                Text("点击进入设置，添加 Copilot / Claude / Codex / Gemini 账号，即可开始监控额度。")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(listContainerShape.fill(listContainerBackground))
            .overlay(
                listContainerShape.stroke(healthyAccent.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    private var summaryListSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(viewModel.sections) { section in
                providerSection(section)
                    .opacity(draggingProvider == section.provider ? 0.4 : 1.0)
                    .onDrag {
                        draggingProvider = section.provider
                        return NSItemProvider(object: section.provider.rawValue as NSString)
                    }
                    .onDrop(of: [.text], delegate: ProviderDropDelegate(
                        target: section.provider,
                        viewModel: viewModel,
                        draggingProvider: $draggingProvider
                    ))
            }
        }
        .padding(5)
        .background(listContainerShape.fill(listContainerBackground))
        .overlay(listContainerShape.stroke(separatorColor.opacity(0.9), lineWidth: 1))
    }

    @ViewBuilder
    private func providerSection(_ section: QuotaSection) -> some View {
        if viewModel.isExpanded(section.provider) {
            expandedProviderSection(section)
        } else {
            collapsedProviderSection(section)
        }
    }

    private func collapsedProviderSection(_ section: QuotaSection) -> some View {
        let accent = providerAccent(for: section.provider)

        return Button(action: {
            viewModel.toggleExpanded(section.provider)
        }) {
            HStack(spacing: 8) {
                Text(section.provider.displayName)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.3)
                    .foregroundStyle(accent)
                    .frame(width: 48, alignment: .leading)

                HStack(spacing: 3) {
                    ForEach(section.cards) { card in
                        Circle()
                            .fill(dotTint(for: card))
                            .frame(width: 6, height: 6)
                    }
                }

                Spacer(minLength: 8)

                Text("\(section.cards.count) 项")
                    .font(.system(size: 7.5, weight: .semibold))
                    .foregroundStyle(accent.opacity(0.92))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(badgeBackground, in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(accent.opacity(0.28), lineWidth: 0.8)
                    )

                providerStatusDot(section.provider)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(accent.opacity(0.7))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(providerSectionFill(for: section.provider))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(accent.opacity(0.18), lineWidth: 1)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func expandedProviderSection(_ section: QuotaSection) -> some View {
        let accent = providerAccent(for: section.provider)

        return VStack(alignment: .leading, spacing: 6) {
            Button(action: {
                viewModel.toggleExpanded(section.provider)
            }) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(section.provider.displayName)
                            .font(.system(size: 10, weight: .bold))
                            .tracking(0.3)
                            .foregroundStyle(accent)

                        Spacer(minLength: 8)

                        Text("\(section.cards.count) 项")
                            .font(.system(size: 7.5, weight: .semibold))
                            .foregroundStyle(accent.opacity(0.92))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(badgeBackground, in: Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(accent.opacity(0.28), lineWidth: 0.8)
                            )

                        Image(systemName: "chevron.up")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(accent.opacity(0.7))
                    }

                    HStack(spacing: 6) {
                        Capsule()
                            .fill(accent)
                            .frame(width: 18, height: 3)

                        Rectangle()
                            .fill(accent.opacity(0.22))
                            .frame(maxWidth: .infinity)
                            .frame(height: 1)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            providerRefreshInfoLine(section.provider)

            VStack(spacing: 4) {
                ForEach(section.cards) { card in
                    if let accountId = card.accountId, !card.isActiveAccount {
                        Button(action: { viewModel.switchToAccount(id: accountId, provider: card.provider) }) {
                            summaryCard(card)
                        }
                        .buttonStyle(.plain)
                    } else {
                        summaryCard(card)
                    }
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(providerSectionFill(for: section.provider))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(accent.opacity(0.18), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func providerRefreshInfoLine(_ provider: QuotaProvider) -> some View {
        let state = viewModel.providerState(for: provider)
        let accent = providerAccent(for: provider)

        HStack(spacing: 6) {
            if let lastRefreshed = state.lastRefreshedAt {
                Text(relativeTimeString(from: lastRefreshed))
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if case .failed(let message) = state.status {
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(criticalAccent)
                    Text(message)
                        .font(.system(size: 7.5, weight: .medium))
                        .foregroundStyle(criticalAccent)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if state.status.isRefreshing {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
                    .frame(width: 14, height: 14)
            } else {
                Button(action: { viewModel.refreshProvider(provider) }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(accent.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private func providerStatusDot(_ provider: QuotaProvider) -> some View {
        let state = viewModel.providerState(for: provider)

        switch state.status {
        case .refreshing:
            Circle()
                .fill(warningAccent)
                .frame(width: 5, height: 5)
                .opacity(0.8)
        case .failed:
            Circle()
                .fill(criticalAccent)
                .frame(width: 5, height: 5)
        default:
            EmptyView()
        }
    }


    private func relativeTimeString(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 5 { return "刚刚" }
        if interval < 60 { return "\(Int(interval)) 秒前" }
        if interval < 3600 {
            return "\(Int(interval / 60)) 分钟前"
        }
        return "\(Int(interval / 3600)) 小时前"
    }

    private func summaryCard(_ card: QuotaCard) -> some View {
        let hasAccountId = card.accountId != nil
        let isActive = card.isActiveAccount

        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if hasAccountId {
                    Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(isActive ? .green : .secondary.opacity(0.5))
                }

                VStack(alignment: .leading, spacing: 1.5) {
                    Text(card.title)
                        .font(.system(size: 10.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.primary)

                    if let subtitle = card.subtitle {
                        Text(subtitle)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                Text(card.planLabel.uppercased())
                    .font(.system(size: 7.5, weight: .semibold))
                    .foregroundStyle(planTint(for: card))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(planTint(for: card).opacity(0.12), in: Capsule())
            }

            if let errorMessage = card.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(criticalAccent)
                    .padding(.top, 1)
            } else {
                VStack(spacing: 4) {
                    ForEach(card.windows) { row in
                        metricLine(row, card: card)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(rowShape.fill(rowBackground))
        .overlay(
            rowShape.stroke(
                hasAccountId && isActive ? Color.green.opacity(0.35) : cardStrokeColor,
                lineWidth: hasAccountId && isActive ? 1.2 : 0.8
            )
        )
        .opacity(hasAccountId && !isActive ? 0.65 : 1.0)
    }

    private func metricLine(_ row: QuotaWindowRow, card: QuotaCard) -> some View {
        let tint = tint(for: row, card: card)

        if let metricSummary = row.metricSummary {
            return AnyView(prominentMetricLine(row, tint: tint, metricSummary: metricSummary))
        }

        return AnyView(standardMetricLine(row, tint: tint))
    }

    private func standardMetricLine(_ row: QuotaWindowRow, tint: Color) -> some View {
        let layout = QuotaMetricLineLayout.compact

        return VStack(alignment: .leading, spacing: row.detailText == nil ? 0 : 2) {
            HStack(spacing: layout.columnSpacing) {
                Text(row.compactLabel)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: layout.labelWidth, alignment: .leading)

                Group {
                    if row.showsProgressBar {
                        CompactQuotaBar(percent: row.remainingPercent, tint: tint)
                    } else {
                        Capsule()
                            .fill(tint.opacity(0.18))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: layout.barHeight)

                Text(row.remainingText)
                    .font(.system(size: 9.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(width: layout.valueWidth, alignment: .trailing)

                Text(row.resetLabel)
                    .font(.system(size: 8.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.94)
                    .frame(width: layout.resetWidth, alignment: .trailing)
            }

            if let detailText = row.detailText {
                Text(detailText)
                    .font(.system(size: 7.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.88)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private func prominentMetricLine(
        _ row: QuotaWindowRow,
        tint: Color,
        metricSummary: QuotaMetricSummary
    ) -> some View {
        let layout = QuotaMetricLineLayout.compact
        let usedTint = usedMetricTint

        return HStack(alignment: .center, spacing: layout.columnSpacing) {
            Text(row.compactLabel)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: layout.labelWidth, alignment: .leading)

            CompactQuotaBar(percent: row.remainingPercent, tint: tint)
                .frame(maxWidth: .infinity)
                .frame(height: layout.barHeight)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                inlineMetricReadout(
                    value: metricSummary.trailingValueText,
                    label: metricSummary.trailingLabel,
                    valueTint: tint,
                    labelTint: tint.opacity(0.78)
                )

                inlineMetricReadout(
                    value: metricSummary.leadingValueText,
                    label: metricSummary.leadingLabel,
                    valueTint: usedTint,
                    labelTint: usedTint.opacity(0.86)
                )
            }
            .frame(width: 106, alignment: .trailing)

            Text(row.compactTrailingSummaryText)
                .font(.system(size: 8, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .frame(width: layout.resetWidth, alignment: .trailing)
        }
    }

    private func inlineMetricReadout(
        value: String,
        label: String,
        valueTint: Color,
        labelTint: Color
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(value)
                .font(.system(size: 9.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(valueTint)
                .lineLimit(1)
                .minimumScaleFactor(0.9)

            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(labelTint)
                .lineLimit(1)
        }
    }

    private var usedMetricTint: Color {
        colorScheme == .dark ? Color.white.opacity(0.58) : Color.black.opacity(0.36)
    }

    private func inlineStatus(text: String, detail: String? = nil, tone: StatusTone) -> some View {
        VStack(alignment: .leading, spacing: detail == nil ? 0 : 4) {
            Text(text)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(tone.foreground)

            if let detail {
                Text(detail)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(listContainerShape.fill(listContainerBackground))
        .overlay(listContainerShape.stroke(tone.stroke(for: colorScheme), lineWidth: 1))
    }

    private func toolbarButton(systemName: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)
                .background(badgeBackground, in: Circle())
                .overlay(Circle().stroke(separatorColor.opacity(0.85), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
    }

    private func toolbarPill(text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(badgeBackground, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(separatorColor.opacity(0.85), lineWidth: 0.8)
            )
    }

    private var connectionText: String {
        if viewModel.hasAnyAvailableSource == false {
            return "待配置"
        }
        return viewModel.isRefreshing ? "刷新中" : "已就绪"
    }

    private var accountCountText: String {
        if viewModel.hasAnyAvailableSource == false {
            return "未配置"
        }
        if viewModel.isRefreshing && viewModel.sections.isEmpty {
            return "正在刷新"
        }
        if viewModel.totalAccountCount == 0 {
            return viewModel.connectedSourceCount > 1 ? "已连接 \(viewModel.connectedSourceCount) 个来源" : "已连接"
        }
        return "\(viewModel.totalAccountCount) 项额度"
    }

    private var connectionTint: Color {
        if viewModel.hasAnyAvailableSource == false {
            return warningAccent
        }
        if viewModel.isRefreshing {
            return warningAccent
        }
        return healthyAccent
    }

    private func planTint(for card: QuotaCard) -> Color {
        switch card.planLabel.lowercased() {
        case "plus", "pro", "pro +", "pro+", "max", "team", "business":
            return healthyAccent
        case "enterprise":
            return warningAccent
        case "cli":
            return providerAccent(for: card.provider)
        case "错误":
            return criticalAccent
        case "冷却":
            return warningAccent
        default:
            return card.provider == .gemini ? providerAccent(for: card.provider) : mutedAccent
        }
    }

    private func tint(for row: QuotaWindowRow, card: QuotaCard) -> Color {
        guard let remaining = row.remainingPercent else {
            return planTint(for: card)
        }

        switch remaining {
        case 65...:
            return healthyAccent
        case 35..<65:
            return warningAccent
        default:
            return criticalAccent
        }
    }

    private func formattedHeader(date: Date) -> String {
        date.formatted(Self.headerTimeStyle)
    }

    private func providerAccent(for provider: QuotaProvider) -> Color {
        switch provider {
        case .copilot:
            return copilotAccent
        case .codex:
            return healthyAccent
        case .claude:
            return claudeAccent
        case .gemini:
            return geminiAccent
        }
    }

    private func dotTint(for card: QuotaCard) -> Color {
        guard let row = card.primaryStatusRow, let percent = row.remainingPercent else {
            return mutedAccent.opacity(0.3)
        }
        switch percent {
        case 65...: return healthyAccent
        case 35..<65: return warningAccent
        default: return criticalAccent
        }
    }

    private func providerSectionFill(for provider: QuotaProvider) -> Color {
        let base = providerAccent(for: provider)
        if colorScheme == .dark {
            return base.opacity(provider == .codex ? 0.12 : 0.14)
        }
        return base.opacity(provider == .codex ? 0.075 : 0.085)
    }

    private var listContainerShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
    }

    private var rowShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
    }
}

@MainActor
private struct ProviderDropDelegate: DropDelegate {
    let target: QuotaProvider
    let viewModel: QuotaMenuViewModel
    @Binding var draggingProvider: QuotaProvider?

    func performDrop(info: DropInfo) -> Bool {
        draggingProvider = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let source = draggingProvider, source != target else { return }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            viewModel.moveProvider(from: source, to: target)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {}

    func validateDrop(info: DropInfo) -> Bool {
        true
    }
}

struct PanelMaterialView: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active
        view.material = material
        view.blendingMode = .behindWindow
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.state = .active
        nsView.material = material
        nsView.blendingMode = .behindWindow
        nsView.isEmphasized = false
    }
}

private struct CompactQuotaBar: View {
    let percent: Int?
    let tint: Color
    var segmented = false
    var leadingTint: Color? = nil

    @Environment(\.colorScheme) private var colorScheme

    private var trackColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.075)
    }
    private var segmentedUnfilledColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.15) : Color.black.opacity(0.12)
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = SegmentedQuotaBarLayout.forRemainingPercent(percent)
            let progress = layout.leadingFraction
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 999)
                    .fill(trackColor)

                if segmented {
                    let leadingFill = leadingTint ?? segmentedUnfilledColor
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(tint.opacity(percent == nil ? 0.28 : 0.95))
                            .frame(width: geometry.size.width * layout.leadingFraction)

                        Rectangle()
                            .fill(percent == nil ? leadingFill.opacity(0.28) : leadingFill)
                            .frame(width: geometry.size.width * layout.trailingFraction)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 999))
                } else {
                    RoundedRectangle(cornerRadius: 999)
                        .fill(tint)
                        .frame(width: max(6, geometry.size.width * progress))
                        .opacity(percent == nil ? 0.28 : 0.95)
                }
            }
        }
    }
}

private enum StatusTone {
    case neutral
    case error

    var foreground: Color {
        switch self {
        case .neutral:
            return .primary
        case .error:
            return Color(nsColor: .systemRed)
        }
    }

    func stroke(for colorScheme: ColorScheme) -> Color {
        switch self {
        case .neutral:
            return colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)
        case .error:
            return Color(nsColor: .systemRed).opacity(0.22)
        }
    }
}

private struct HeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private extension View {
    func readHeight(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: HeightPreferenceKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(HeightPreferenceKey.self, perform: onChange)
    }
}

private extension Color {
    init(hex: UInt, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

private extension QuotaMenuView {
    static let headerTimeStyle = Date.FormatStyle()
        .hour(.twoDigits(amPM: .omitted))
        .minute(.twoDigits)
        .second(.twoDigits)
        .locale(Locale(identifier: "zh_CN"))
}
