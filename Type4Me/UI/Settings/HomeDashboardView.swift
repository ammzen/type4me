import SwiftUI

/// The lightweight landing page for Settings. It intentionally keeps mode
/// configuration out of the overview: the gear takes users to the full editor.
struct HomeDashboardView: View {
    let isActive: Bool
    let openModesEditor: () -> Void

    @Environment(AppState.self) private var appState
    @State private var statistics: HistoryStore.Statistics?
    @State private var hoveredMetric: Metric?
    @State private var isModesButtonHovered = false

    private let historyStore = HistoryStore.shared
    private let assumedTypingSpeed = 40.0

    /// Drive the list from the same live, observable source the menu bar reads
    /// (`appState.availableModes`), so reordering in the Modes editor is
    /// reflected here immediately without depending on notification/disk timing.
    private var modes: [ProcessingMode] { appState.availableModes }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("说出想法，即刻成文", "Say it. Shape it."))
                    .font(.system(size: 42, weight: .bold))
                    .tracking(-1.2)
                    .foregroundStyle(TF.settingsText)

                Text(L("用你的声音完成写作，把时间留给更重要的事。",
                       "Turn your voice into polished text and save time for what matters."))
                    .font(.system(size: 14))
                    .foregroundStyle(TF.settingsTextTertiary)
            }
            .padding(.bottom, 30)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    modesCard
                        .frame(minWidth: 520, maxWidth: .infinity, alignment: .top)

                    statisticsCard
                        .frame(width: 244, alignment: .top)
                }

                modesCard
                    .frame(minWidth: 520, maxWidth: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            if isActive {
                refreshDashboard()
            }
        }
        .onChange(of: isActive) { _, isNowActive in
            if isNowActive {
                refreshDashboard()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectMode)) { _ in
            refreshDashboard()
        }
        .onReceive(NotificationCenter.default.publisher(for: .modesDidChange)) { _ in
            refreshDashboard()
        }
    }

    private var modesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("我的模式", "My Modes"))
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(TF.settingsText)
                    Text(L("在任何地方使用快捷键开始口述",
                           "Use a shortcut anywhere to start dictating"))
                        .font(.system(size: 11))
                        .foregroundStyle(TF.settingsTextTertiary)
                }

                Spacer()

                Button(action: openModesEditor) {
                    HStack(spacing: 6) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 13, weight: .semibold))
                        Text(L("管理", "Manage"))
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(isModesButtonHovered ? Color.white : TF.settingsTextSecondary)
                    .padding(.horizontal, 11)
                    .frame(height: 32)
                    .background(
                        Capsule()
                            .fill(isModesButtonHovered ? TF.settingsText : TF.settingsCardAlt)
                    )
                    .contentShape(Capsule())
                    .scaleEffect(isModesButtonHovered ? 1.035 : 1)
                    .shadow(
                        color: Color.black.opacity(isModesButtonHovered ? 0.16 : 0),
                        radius: 6,
                        y: 2
                    )
                }
                .buttonStyle(.plain)
                .help(L("编辑 Modes", "Edit Modes"))
                .onHover { isHovering in
                    withAnimation(.easeOut(duration: 0.14)) {
                        isModesButtonHovered = isHovering
                    }
                    if isHovering {
                        NSCursor.pointingHand.set()
                    } else {
                        NSCursor.arrow.set()
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)

            Divider()
                .padding(.horizontal, 22)

            if modes.isEmpty {
                Text(L("还没有 Mode", "No modes yet"))
                    .font(.system(size: 13))
                    .foregroundStyle(TF.settingsTextTertiary)
                    .frame(maxWidth: .infinity, minHeight: 92)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(modes.enumerated()), id: \.element.id) { index, mode in
                        modeOverviewRow(mode)
                        if index < modes.count - 1 {
                            Divider().padding(.leading, 22)
                        }
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(TF.settingsCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(TF.settingsBorder, lineWidth: 1)
        )
    }

    private func modeOverviewRow(_ mode: ProcessingMode) -> some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(mode.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(TF.settingsText)

                    if mode.isBuiltin {
                        Text(L("内置", "BUILT-IN"))
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(TF.settingsTextTertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(TF.settingsCardAlt))
                    }
                }

                Text(modeSummary(mode))
                    .font(.system(size: 11))
                    .foregroundStyle(TF.settingsTextTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            hotkeyBadge(mode)
        }
        .padding(.horizontal, 22)
        .frame(minHeight: 66)
    }

    private static let hotkeyBadgeVisibleLimit = 2

    private func hotkeyBadge(_ mode: ProcessingMode) -> some View {
        let bindings = mode.hotkeyBindings
        let visible = Array(bindings.prefix(Self.hotkeyBadgeVisibleLimit))
        let overflow = bindings.count - visible.count

        return HStack(spacing: 6) {
            if bindings.isEmpty {
                Text(L("未设置", "Not set"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(TF.settingsTextTertiary)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(TF.settingsBg)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(TF.settingsBorder, lineWidth: 1)
                    )
            } else {
                ForEach(visible) { binding in
                    hotkeyChip(binding)
                }

                if overflow > 0 {
                    Text("+\(overflow)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(TF.settingsTextSecondary)
                        .padding(.horizontal, 7)
                        .frame(height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(TF.settingsBg)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(TF.settingsBorder, lineWidth: 1)
                        )
                        .help(bindings
                            .map { hotkeyChipTooltip($0) }
                            .joined(separator: "\n"))
                }
            }
        }
        .fixedSize()
    }

    /// Compact, visually distinct chip for a single hotkey binding.
    /// Hold vs. Toggle are differentiated by a leading colored glyph rather than a
    /// space-consuming text label.
    private func hotkeyChip(_ binding: HotkeyBinding) -> some View {
        let accent = hotkeyStyleColor(binding.style)
        return HStack(spacing: 5) {
            Image(systemName: hotkeyStyleIcon(binding.style))
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(accent)

            Text(HotkeyRecorderView.keyDisplayName(
                keyCode: binding.keyCode,
                modifiers: binding.modifiers
            ))
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(TF.settingsText)
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(accent.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(accent.opacity(0.35), lineWidth: 1)
        )
        .help(hotkeyChipTooltip(binding))
    }

    private func hotkeyChipTooltip(_ binding: HotkeyBinding) -> String {
        let key = HotkeyRecorderView.keyDisplayName(
            keyCode: binding.keyCode, modifiers: binding.modifiers)
        return "\(key) · \(hotkeyStyleLabel(binding.style))"
    }

    private func hotkeyStyleIcon(_ style: ProcessingMode.HotkeyStyle) -> String {
        switch style {
        case .hold:
            return "hand.tap.fill"
        case .toggle:
            return "arrow.triangle.2.circlepath"
        }
    }

    private func hotkeyStyleColor(_ style: ProcessingMode.HotkeyStyle) -> Color {
        switch style {
        case .hold:
            return Color(red: 0.20, green: 0.60, blue: 0.86)
        case .toggle:
            return Color(red: 0.36, green: 0.56, blue: 0.32)
        }
    }

    private func hotkeyStyleLabel(_ style: ProcessingMode.HotkeyStyle) -> String {
        switch style {
        case .hold:
            return L("按住录制", "Hold")
        case .toggle:
            return L("按下切换", "Toggle")
        }
    }

    private var statisticsCard: some View {
        let stats = statistics
        return VStack(alignment: .leading, spacing: 0) {
            statRow(
                metric: .inputTime,
                icon: "clock",
                title: L("输入总时间", "Total input time"),
                value: formatDuration(stats?.totalDuration ?? 0)
            )
            statRow(
                metric: .characters,
                icon: "mic",
                title: L("总字数", "Total characters"),
                value: formatNumber(stats?.totalCharacters ?? 0)
            )
            statRow(
                metric: .speed,
                icon: "bolt",
                title: L("输入速度", "Input speed"),
                value: String(format: L("%.0f 字/分", "%.0f chars/min"), stats?.averageSpeed ?? 0)
            )
            statRow(
                metric: .saved,
                icon: "hourglass",
                title: L("估算节约", "Estimated saved"),
                value: formatDuration(estimatedSavedTime(stats))
            )
        }
        .padding(.vertical, 12)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(TF.settingsBg)
        )
    }

    private func statRow(
        metric: Metric,
        icon: String,
        title: String,
        value: String
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .regular))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(TF.settingsText)
                .frame(width: 20, height: 20)

            Text(value)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(TF.settingsText)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .frame(height: 52)
        .contentShape(Rectangle())
        .overlay {
            GeometryReader { geometry in
                if hoveredMetric == metric {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .frame(width: 112, height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.black.opacity(0.92))
                        )
                        .position(x: -48, y: geometry.size.height / 2)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
        }
        .zIndex(hoveredMetric == metric ? 2 : 0)
        .onHover { isHovering in
            withAnimation(.easeOut(duration: 0.14)) {
                hoveredMetric = isHovering ? metric : nil
            }
        }
    }

    private func refreshDashboard() {
        Task {
            statistics = await historyStore.getStatistics()
        }
    }

    private func modeSummary(_ mode: ProcessingMode) -> String {
        if mode.id == ProcessingMode.translationModeId,
           let code = mode.translationTargetLanguageCode,
           let target = TranslationLanguage(rawValue: code) {
            return L(
                "目标：\(target.displayName) · 自动识别口述语言",
                "Target: \(target.displayName) · Auto-detect spoken language"
            )
        }
        let summary = mode.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty ? L("自定义处理模式", "Custom processing mode") : summary
    }

    private func estimatedSavedTime(_ stats: HistoryStore.Statistics?) -> Double {
        guard let stats else { return 0 }
        let estimatedTypingSeconds = Double(stats.totalCharacters) / assumedTypingSpeed * 60
        return max(0, estimatedTypingSeconds - stats.totalDuration)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let totalMinutes = Int((seconds / 60).rounded())
        if totalMinutes < 1 {
            return L("少于 1 分钟", "< 1 min")
        }
        if totalMinutes < 60 {
            return L("\(totalMinutes) 分钟", "\(totalMinutes) min")
        }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return minutes == 0
            ? L("\(hours) 小时", "\(hours) hr")
            : L("\(hours) 小时 \(minutes) 分", "\(hours) hr \(minutes) min")
    }

    private func formatNumber(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    private enum Metric: Hashable {
        case inputTime
        case characters
        case speed
        case saved
    }
}

/// A very light perspective dot field used only behind the Home dashboard.
/// The dots form a low-amplitude wave so the page gains depth without adding
/// another card or competing with the dashboard content.
struct HomeDottedWaveBackground: View {
    var body: some View {
        Canvas { context, size in
            // A square lattice projected into screen space. Its two axes run
            // diagonally left/right, which reads as a surface viewed at 45°.
            let projectedX: CGFloat = 7.8
            let projectedY: CGFloat = 7.2
            let originX = size.width * 0.50
            let originY = size.height * 0.48
            let indexRadius = Int(ceil(
                size.width / (projectedX * 2) + size.height / (projectedY * 2)
            )) + 8
            let waveCenterX = size.width * 0.68
            let waveCenterY = size.height * 0.63
            let scaleX = max(size.width * 0.58, 1)
            let scaleY = max(size.height * 0.64, 1)

            for u in -indexRadius...indexRadius {
                for v in -indexRadius...indexRadius {
                    let baseX = originX + CGFloat(u - v) * projectedX
                    let baseY = originY + CGFloat(u + v) * projectedY
                    guard baseX > -12, baseX < size.width + 12,
                          baseY > -44, baseY < size.height + 18 else { continue }

                    let nx = (baseX - waveCenterX) / scaleX
                    let ny = (baseY - waveCenterY) / scaleY
                    let envelope = exp(-(nx * nx * 0.82 + ny * ny * 1.05))
                    let wave = sin(nx * 6.2 + ny * 1.4)
                        * cos(ny * 2.3 - nx * 0.55)
                        * envelope

                    // Height is projected upward with a slight leftward drift,
                    // so crests visibly rise from the receding diamond plane.
                    let x = baseX - wave * 5.5
                    let y = baseY - wave * 46
                    let nearFactor = 0.72
                        + min(max(baseY / max(size.height, 1), 0), 1) * 0.28
                    let crest = (wave + envelope + 1) / 3
                    let radius = (0.78 + crest * 0.52) * nearFactor
                    let opacity = (0.075 + envelope * (0.025 + crest * 0.055)) * nearFactor
                    let dot = CGRect(
                        x: x - radius,
                        y: y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                    context.fill(
                        Path(ellipseIn: dot),
                        with: .color(Color.black.opacity(opacity))
                    )
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
