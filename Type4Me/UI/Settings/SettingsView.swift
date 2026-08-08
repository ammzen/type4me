import SwiftUI

// MARK: - Navigation Item

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case models
    case vocabulary
    case modes
    case history
    case preferences
    case about
    #if HAS_CLOUD_SUBSCRIPTION
    case account
    #endif
    #if HAS_CLOUD_SUBSCRIPTION
    case debug
    #endif

    var id: String { rawValue }

    #if HAS_CLOUD_SUBSCRIPTION
    static func tabs(for edition: AppEdition?) -> [SettingsTab] {
        switch edition {
        case .member:
            return [.general, .modes, .vocabulary, .history, .preferences, .about]
        case .byoKey, .none:
            return [.general, .models, .vocabulary, .modes, .history, .preferences, .about]
        }
    }
    #endif

    var displayName: String {
        switch self {
        case .general:     return L("首页", "Home")
        case .models:      return L("模型", "Models")
        case .vocabulary:  return L("词汇", "Vocabulary")
        case .modes:       return L("模式", "Modes")
        case .history:     return L("历史", "History")
        case .preferences: return L("设置", "Settings")
        case .about:       return L("关于", "About")
        #if HAS_CLOUD_SUBSCRIPTION
        case .account:     return L("账户", "Account")
        case .debug:       return L("调试", "Debug")
        #endif
        }
    }

    var subtitle: String {
        switch self {
        case .general:    return L("模式与使用概览", "Modes & usage overview")
        case .models:      return L("语音识别与 LLM 引擎", "ASR & LLM engines")
        case .vocabulary:  return L("热词与片段替换", "Hotwords & snippets")
        case .modes:       return L("推理与默认行为", "Processing & defaults")
        case .history:     return L("会话与日志保留", "Sessions & logs")
        case .preferences: return L("偏好与系统权限", "Preferences & permissions")
        case .about:       return L("版本、许可证与支持", "Version, license & support")
        #if HAS_CLOUD_SUBSCRIPTION
        case .account:     return L("登录与订阅管理", "Login & subscription")
        case .debug:       return L("区域、端点与诊断", "Region, endpoints & diagnostics")
        #endif
        }
    }

    var icon: String {
        switch self {
        case .general:     return "house"
        case .models:      return "cpu"
        case .vocabulary:  return "book.closed"
        case .modes:       return "slider.horizontal.3"
        case .history:     return "clock.arrow.circlepath"
        case .preferences: return "gearshape"
        case .about:       return "questionmark.circle"
        #if HAS_CLOUD_SUBSCRIPTION
        case .account:     return "person.crop.circle"
        case .debug:       return "ladybug"
        #endif
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {

    @Environment(AppState.self) private var appState
    @State private var selectedTab: SettingsTab = .general
    @State private var hoveredTab: SettingsTab?
    @State private var hoveredSettingsTab: SettingsTab?
    @AppStorage("tf_language") private var language = AppLanguage.systemDefault
    #if HAS_CLOUD_SUBSCRIPTION
    @State private var showDeviceConflict = false
    @AppStorage("tf_app_edition") private var editionRaw: String?
    private var edition: AppEdition? { editionRaw.flatMap { AppEdition(rawValue: $0) } }
    #endif

    var body: some View {
        ZStack {
            TF.settingsWindowBackground
                .ignoresSafeArea()

            HStack(spacing: 0) {
                sidebar
                    .overlay(alignment: .topLeading) {
                        // Fresh standard window buttons placed exactly 25pt from
                        // the window's top/left (15pt inside the 10pt-inset card),
                        // wired to performClose/Miniaturize/Zoom. Living in the
                        // content layer keeps clicks/hover reliable; the native
                        // traffic lights are hidden by the cluster.
                        WindowControlsCluster()
                            .frame(width: 54, height: 14)
                            .padding(.leading, 15)
                            .padding(.top, 15)
                    }
                    .padding(.leading, 10)
                    .padding(.vertical, 10)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                content
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .id(language)
        .frame(minWidth: 900, minHeight: 600)
        .background(SettingsWindowConfigurator())
        .preferredColorScheme(.light)
        #if HAS_CLOUD_SUBSCRIPTION
        .onAppear {
            if (selectedTab == .models && edition == .member) ||
               (selectedTab == .account && edition != .member) {
                selectedTab = .preferences
            }
        }
        .onChange(of: editionRaw) { _, _ in
            if (selectedTab == .models && edition == .member) ||
               (selectedTab == .account && edition != .member) {
                selectedTab = .preferences
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cloudDeviceConflict)) { _ in
            showDeviceConflict = true
        }
        .alert(L("设备冲突", "Device Conflict"), isPresented: $showDeviceConflict) {
            Button(L("确定", "OK")) { if edition == .member { selectedTab = .account } }
        } message: {
            Text(L("你的账户已在其他设备登录，当前设备已自动登出。",
                    "Your account has been logged in on another device. This device has been signed out."))
        }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .navigateToMode)) { note in
            selectedTab = .modes
            if let modeId = note.object as? UUID {
                NotificationCenter.default.post(name: .selectMode, object: modeId)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToHistory)) { _ in
            selectedTab = .history
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToVocabulary)) { _ in
            selectedTab = .vocabulary
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Reserve the title-bar area for the native macOS window controls.
            Color.clear.frame(height: 54)

            // Brand
            HStack(spacing: 9) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(TF.settingsText)
                Text("Type4Me")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(TF.settingsText)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 30)

            // Nav items
            VStack(spacing: 4) {
                ForEach([SettingsTab.general, .vocabulary, .history]) { tab in
                    navItem(tab)
                }
            }
            .padding(.horizontal, 12)

            Spacer()

            #if HAS_CLOUD_SUBSCRIPTION
            if DebugTab.isEnabled && edition == .member {
                navItem(.debug)
                    .padding(.horizontal, 10)
            }
            #endif
            #if HAS_CLOUD_SUBSCRIPTION
            if edition == .member {
                navItem(.account)
                    .padding(.horizontal, 10)
            }
            EditionSwitchLink()
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            #endif

            navItem(.preferences)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .frame(width: 224)
        .background(
            // Floating card with a 10pt margin on top/left/bottom; rounded to
            // read like the window's own corner curvature (Apple Reminders).
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(TF.settingsSidebar)
        )
    }

    private func navItem(_ tab: SettingsTab) -> some View {
        let isActive = tab == .preferences
            ? settingsSubtabs.contains(selectedTab)
            : selectedTab == tab
        let showBadge = tab == .preferences && appState.hasUnseenUpdate
        return Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 13) {
                Image(systemName: tab.icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isActive ? TF.settingsText : TF.settingsTextSecondary)
                    .frame(width: 20)
                Text(tab.displayName)
                    .font(.system(size: 14, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(TF.settingsText)
                Spacer()
                if showBadge {
                    Circle()
                        .fill(.red)
                        .frame(width: 7, height: 7)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        isActive
                            ? TF.settingsSidebarActive
                            : (hoveredTab == tab ? TF.settingsSidebarHover : .clear)
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            withAnimation(.easeOut(duration: 0.12)) {
                hoveredTab = isHovering ? tab : nil
            }
        }
    }

    // MARK: - Content

    private var settingsSubtabs: [SettingsTab] {
        #if HAS_CLOUD_SUBSCRIPTION
        if edition == .member {
            return [.preferences, .modes, .about]
        }
        #endif
        return [.preferences, .models, .modes, .about]
    }

    private var settingsSectionPicker: some View {
        HStack(spacing: 2) {
            ForEach(settingsSubtabs) { tab in
                settingsSectionButton(tab)
            }
        }
        .padding(4)
        .background(
            Capsule()
                .fill(TF.settingsControl)
        )
        .fixedSize()
        .padding(.bottom, 24)
    }

    private func settingsSectionButton(_ tab: SettingsTab) -> some View {
        let isSelected = selectedTab == tab
        let isHovered = hoveredSettingsTab == tab

        return Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                selectedTab = tab
            }
            if tab == .about {
                UpdateChecker.shared.markAsSeen(appState: appState)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tab.icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(tab == .preferences ? L("通用", "Generals") : tab.displayName)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                if tab == .about && appState.hasUnseenUpdate {
                    Circle()
                        .fill(.red)
                        .frame(width: 6, height: 6)
                }
            }
            .foregroundStyle(isSelected ? TF.settingsText : TF.settingsTextSecondary)
            .padding(.horizontal, 16)
            .frame(height: 32)
            .background(
                Capsule().fill(
                    isSelected
                        ? Color.white
                        : (isHovered
                           ? TF.settingsControlHover
                           : Color.clear)
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                hoveredSettingsTab = hovering ? tab : nil
            }
            if hovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }

    private var settingsHubHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(
                label: "SETTINGS",
                title: L("设置", "Settings"),
                description: L("集中管理偏好、模型、处理模式与应用信息。", "Manage preferences, models, processing modes, and app information.")
            )
            settingsSectionPicker
        }
    }

    private var content: some View {
        ZStack {
            HomeDottedWaveBackground()
                .opacity(selectedTab == .general ? 1 : 0)

            tabPage(.general) {
                HomeDashboardView(isActive: selectedTab == .general) {
                    selectedTab = .modes
                }
            }
            fixedPage(.vocabulary) { VocabularyTab() }
            fixedPage(.history)  { HistoryTab(isActive: selectedTab == .history) }

            settingsTabPage(.preferences) { GeneralSettingsTab(showsHeader: false) }
            #if HAS_CLOUD_SUBSCRIPTION
            if edition != .member {
                settingsTabPage(.models) { ModelSettingsTab(showsHeader: false) }
            }
            #else
            settingsTabPage(.models) { ModelSettingsTab(showsHeader: false) }
            #endif
            settingsFixedPage(.modes) { ModesSettingsTab(showsHeader: false) }
            settingsTabPage(.about) { AboutTab(showsHeader: false) }
            #if HAS_CLOUD_SUBSCRIPTION
            if edition == .member {
                tabPage(.account) { AccountTab() }
            }
            #endif
            #if HAS_CLOUD_SUBSCRIPTION
            if DebugTab.isEnabled && edition == .member {
                tabPage(.debug) { DebugTab() }
            }
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TF.settingsWindowBackground)
    }

    private func settingsTabPage<V: View>(
        _ tab: SettingsTab,
        @ViewBuilder content: () -> V
    ) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                settingsHubHeader
                content()
            }
            .padding(.horizontal, 38)
            .padding(.vertical, 34)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .opacity(selectedTab == tab ? 1 : 0)
        .allowsHitTesting(selectedTab == tab)
    }

    private func settingsFixedPage<V: View>(
        _ tab: SettingsTab,
        @ViewBuilder content: () -> V
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            settingsHubHeader
            content()
        }
        .padding(.horizontal, 38)
        .padding(.vertical, 34)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(selectedTab == tab ? 1 : 0)
        .allowsHitTesting(selectedTab == tab)
    }

    /// Scrollable tab page (most tabs).
    private func tabPage<V: View>(_ tab: SettingsTab, @ViewBuilder content: () -> V) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.horizontal, 38)
            .padding(.vertical, 34)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .opacity(selectedTab == tab ? 1 : 0)
        .allowsHitTesting(selectedTab == tab)
    }

    /// Fixed-height tab page (no outer scroll, content manages its own scroll).
    private func fixedPage<V: View>(_ tab: SettingsTab, @ViewBuilder content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(.horizontal, 38)
        .padding(.vertical, 34)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(selectedTab == tab ? 1 : 0)
        .allowsHitTesting(selectedTab == tab)
    }
}

// MARK: - Window Chrome

/// Makes the title-bar area use the exact same solid canvas color as the page
/// and positions the real macOS controls within the inset sidebar card. Keeping
/// the native zoom button preserves macOS's hover tiling/full-screen menu.
private struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        configureWhenAttached(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configureWhenAttached(nsView)
    }

    private func configureWhenAttached(_ view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isOpaque = true
            window.backgroundColor = NSColor(
                srgbRed: 1,
                green: 1,
                blue: 1,
                alpha: 1
            )
            window.titlebarAppearsTransparent = true
            // Only the native (transparent) title bar strip should move the window;
            // dragging elsewhere is reserved for in-content interactions like
            // reordering the mode list.
            window.isMovableByWindowBackground = false
            window.contentMinSize = NSSize(width: 900, height: 600)
            // The native traffic lights are hidden by `WindowControlsCluster`,
            // which draws fresh standard buttons at the desired inset inside
            // the sidebar card (see SettingsView body).
        }
    }

}

/// Draws fresh standard macOS window buttons (close/miniaturize/zoom) at an
/// arbitrary position inside the content layer and hides the window's native
/// traffic lights, per Apple's documented approach for custom placement.
///
/// The buttons are created via `NSWindow.standardWindowButton(_:for:)` and wired
/// to `performClose(_:)` / `performMiniaturize(_:)` / `performZoom(_:)` through
/// the responder chain, so they behave exactly like the originals. Living in the
/// SwiftUI content hierarchy (not the fragile titlebar layer) keeps clicks and
/// hover glyphs reliable.
private struct WindowControlsCluster: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowControlsClusterView {
        WindowControlsClusterView()
    }

    func updateNSView(_ nsView: WindowControlsClusterView, context: Context) {
        nsView.hideNativeButtons()
    }
}

private final class WindowControlsClusterView: NSView {
    private static let style: NSWindow.StyleMask =
        [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    private static let spacing: CGFloat = 20
    private static let diameter: CGFloat = 14

    private let close: NSButton
    private let mini: NSButton
    private let zoom: NSButton
    private let glyphs: [WindowControlGlyphView]
    private var mouseInside = false {
        didSet {
            guard mouseInside != oldValue else { return }
            glyphs.forEach { $0.isHovered = mouseInside }
        }
    }

    override init(frame frameRect: NSRect) {
        close = NSWindow.standardWindowButton(.closeButton, for: Self.style) ?? NSButton()
        mini = NSWindow.standardWindowButton(.miniaturizeButton, for: Self.style) ?? NSButton()
        zoom = NSWindow.standardWindowButton(.zoomButton, for: Self.style) ?? NSButton()
        glyphs = [
            WindowControlGlyphView(symbolName: "xmark"),
            WindowControlGlyphView(symbolName: "minus"),
            WindowControlGlyphView(symbolName: "arrow.up.left.and.arrow.down.right")
        ]
        super.init(frame: frameRect)

        for button in [close, mini, zoom] {
            button.target = nil  // routed up the responder chain to the window
            addSubview(button)
        }
        glyphs.forEach(addSubview)
        close.action = #selector(NSWindow.performClose(_:))
        mini.action = #selector(NSWindow.performMiniaturize(_:))
        zoom.action = #selector(NSWindow.performZoom(_:))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Flipped so button origins are measured from the top edge.
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hideNativeButtons()
    }

    /// Hide the window's real traffic lights so only our cluster is visible.
    func hideNativeButtons() {
        guard let window else { return }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.isHidden = true
        }
    }

    override func layout() {
        super.layout()
        for (index, button) in [close, mini, zoom].enumerated() {
            let frame = NSRect(
                x: CGFloat(index) * Self.spacing,
                y: 0,
                width: Self.diameter,
                height: Self.diameter
            )
            button.frame = frame
            glyphs[index].frame = frame
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // Pad the tracking region so the glyphs light up as the cursor
        // approaches the cluster, matching native traffic-light behavior.
        let region = bounds.insetBy(dx: -4, dy: -4)
        addTrackingArea(
            NSTrackingArea(
                rect: region,
                options: [.mouseEnteredAndExited, .activeAlways],
                owner: self,
                userInfo: nil
            )
        )
        // Handle the case where the cursor is already inside when the tracking
        // area is (re)created — mouseEntered won't fire on its own then.
        if let window, window.isVisible {
            let pointInWindow = window.mouseLocationOutsideOfEventStream
            let pointInView = convert(pointInWindow, from: nil)
            mouseInside = region.contains(pointInView)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        mouseInside = true
    }

    override func mouseExited(with event: NSEvent) {
        mouseInside = false
    }
}

/// A visual-only overlay. Returning `nil` from hit-testing lets the native
/// window button underneath retain clicks, accessibility, and the zoom menu.
private final class WindowControlGlyphView: NSImageView {
    var isHovered = false {
        didSet { isHidden = !isHovered }
    }

    init(symbolName: String) {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 7, weight: .bold))
        imageScaling = .scaleProportionallyDown
        contentTintColor = NSColor(calibratedWhite: 0.12, alpha: 0.78)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Reusable Components

struct SettingsSectionHeader: View {
    let label: String
    let title: String
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(TF.settingsText)
            Text(description)
                .font(.system(size: 13))
                .foregroundStyle(TF.settingsTextTertiary)
                .lineSpacing(2)
        }
        .padding(.bottom, 24)
    }
}

struct SettingsRow: View {
    let label: String
    let value: String
    var statusColor: Color? = nil

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(TF.settingsText)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(statusColor ?? TF.settingsTextSecondary)
        }
        .padding(.vertical, 10)
    }
}

struct SettingsDivider: View {
    var body: some View {
        Divider().padding(.vertical, 2)
    }
}
