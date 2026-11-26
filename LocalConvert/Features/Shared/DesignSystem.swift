import SwiftUI
import AppKit

private extension Color {
    static func adaptiveOpaque(dark: UInt32, light: UInt32) -> Color {
        Color(nsColor: NSColor.adaptiveOpaque(dark: dark, light: light))
    }
}

private extension NSColor {
    static func adaptiveOpaque(dark: UInt32, light: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            let r = CGFloat((hex >> 16) & 0xFF) / 255.0
            let g = CGFloat((hex >> 8) & 0xFF) / 255.0
            let b = CGFloat(hex & 0xFF) / 255.0
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
        }
    }
}

// MARK: - Design System Tokens

enum AppTheme {
    enum Colors {
        // Core opaque architecture surfaces
        static let mainSidebarBackground = Color.adaptiveOpaque(dark: 0x292B2E, light: 0xEAEDF0)
        static let secondarySidebarBackground = Color.adaptiveOpaque(dark: 0x303337, light: 0xF2F4F7)
        static let workspaceBackground = Color.adaptiveOpaque(dark: 0x202225, light: 0xF7F8FA)
        static let surfaceBackground = workspaceBackground
        static let subtleSurface = Color.adaptiveOpaque(dark: 0x25282C, light: 0xEFF1F5)
        static let cardBackground = Color.adaptiveOpaque(dark: 0x282B2F, light: 0xFFFFFF)
        static let elevatedSurface = Color.adaptiveOpaque(dark: 0x1D1F22, light: 0xF3F5F8)

        // Opaque low-contrast neutral borders & separators
        static let cardBorder = Color.adaptiveOpaque(dark: 0x383B40, light: 0xD5DAE1)
        static let divider = Color.adaptiveOpaque(dark: 0x33363B, light: 0xDFE3E9)

        static let accent = Color.accentColor
        static let accentTint = Color.accentColor.opacity(0.14)
        static let success = Color.green
        static let successTint = Color.green.opacity(0.14)
        static let warning = Color.orange
        static let warningTint = Color.orange.opacity(0.14)
        static let error = Color.red
        static let errorTint = Color.red.opacity(0.14)
        static let info = Color.blue
        static let infoTint = Color.blue.opacity(0.12)
        static let neutralTint = Color.adaptiveOpaque(dark: 0x32353A, light: 0xE6E9EE)

        static var workspaceNSColor: NSColor {
            NSColor.adaptiveOpaque(dark: 0x202225, light: 0xF7F8FA)
        }
    }

    enum Typography {
        static let pageTitle: Font = .title3.weight(.semibold)
        static let sectionTitle: Font = .headline
        static let cardTitle: Font = .subheadline.weight(.semibold)
        static let body: Font = .body
        static let subheadline: Font = .subheadline
        static let caption: Font = .caption
        static let monoCaption: Font = .caption.monospacedDigit()
        static let badge: Font = .caption2.weight(.semibold)
        static let sidebarHeader: Font = .system(size: 11, weight: .semibold)
        static let emptyTitle: Font = .title3.weight(.semibold)
        static let emptySubtitle: Font = .subheadline
    }

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
    }

    enum Radius {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 10
        static let xl: CGFloat = 12
    }

    enum Layout {
        static let mainSidebarMin: CGFloat = 165
        static let mainSidebarIdeal: CGFloat = 185
        static let mainSidebarMax: CGFloat = 220

        static let toolboxSidebarMin: CGFloat = 208
        static let toolboxSidebarIdeal: CGFloat = 215
        static let toolboxSidebarMax: CGFloat = 235

        static let minWindowWidth: CGFloat = 820
        static let minWindowHeight: CGFloat = 580
        static let defaultWindowWidth: CGFloat = 1080
        static let defaultWindowHeight: CGFloat = 740

        static let emptyIconSize: CGFloat = 44
        static let actionBarHorizontalPadding: CGFloat = 14
        static let actionBarVerticalPadding: CGFloat = 10
    }
}

// MARK: - Reusable Design System Components

struct AppCard<Content: View>: View {
    private let title: String?
    private let icon: String?
    private let padding: CGFloat
    @ViewBuilder private let content: Content

    init(
        title: String? = nil,
        icon: String? = nil,
        padding: CGFloat = AppTheme.Spacing.md,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            if let title {
                HStack(spacing: AppTheme.Spacing.xs + 2) {
                    if let icon {
                        Image(systemName: icon)
                            .font(AppTheme.Typography.cardTitle)
                            .foregroundStyle(AppTheme.Colors.accent)
                    }
                    Text(title)
                        .font(AppTheme.Typography.cardTitle)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                Divider()
                    .overlay(AppTheme.Colors.divider)
            }

            content
        }
        .padding(padding)
        .background(AppTheme.Colors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
        )
    }
}

struct AppDivider: View {
    var body: some View {
        Rectangle()
            .fill(AppTheme.Colors.divider)
            .frame(height: 1)
    }
}

struct AppStatusBadge: View {
    enum ShapeStyle {
        case capsule
        case rounded
    }

    let text: String
    var tint: Color = AppTheme.Colors.accent
    var style: ShapeStyle = .capsule

    var body: some View {
        Text(text)
            .font(AppTheme.Typography.badge)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14))
            .foregroundStyle(tint)
            .clipShape(
                style == .capsule
                    ? AnyShape(Capsule())
                    : AnyShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
            )
    }
}

struct AppInfoBanner: View {
    enum BannerStyle {
        case info
        case warning
        case error
        case success

        var color: Color {
            switch self {
            case .info: return AppTheme.Colors.info
            case .warning: return AppTheme.Colors.warning
            case .error: return AppTheme.Colors.error
            case .success: return AppTheme.Colors.success
            }
        }

        var defaultIcon: String {
            switch self {
            case .info: return "info.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.octagon.fill"
            case .success: return "checkmark.circle.fill"
            }
        }
    }

    let style: BannerStyle
    let message: String
    var icon: String? = nil
    var actionTitle: String? = nil
    var onAction: (() -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: icon ?? style.defaultIcon)
                .foregroundStyle(style.color)
                .font(.subheadline)

            Text(message)
                .font(AppTheme.Typography.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            if let actionTitle, let onAction {
                Button(actionTitle, action: onAction)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .fixedSize(horizontal: true, vertical: false)
            }

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss notice")
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(style.color.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .strokeBorder(style.color.opacity(0.28), lineWidth: 1)
        )
    }
}

struct AppEmptyStateView<ExtraContent: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    var isDropTargeted: Bool = false
    var primaryButtonTitle: String? = nil
    var primaryButtonIcon: String? = nil
    var onPrimaryAction: (() -> Void)? = nil
    @ViewBuilder var extraContent: ExtraContent

    init(
        icon: String,
        title: String,
        subtitle: String,
        isDropTargeted: Bool = false,
        primaryButtonTitle: String? = nil,
        primaryButtonIcon: String? = nil,
        onPrimaryAction: (() -> Void)? = nil,
        @ViewBuilder extraContent: () -> ExtraContent = { EmptyView() }
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.isDropTargeted = isDropTargeted
        self.primaryButtonTitle = primaryButtonTitle
        self.primaryButtonIcon = primaryButtonIcon
        self.onPrimaryAction = onPrimaryAction
        self.extraContent = extraContent()
    }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.lg) {
            Image(systemName: icon)
                .font(.system(size: AppTheme.Layout.emptyIconSize, weight: .light))
                .foregroundStyle(isDropTargeted ? AppTheme.Colors.accent : .secondary)

            VStack(spacing: AppTheme.Spacing.xs) {
                Text(title)
                    .font(AppTheme.Typography.emptyTitle)
                    .foregroundStyle(isDropTargeted ? AppTheme.Colors.accent : .primary)

                Text(subtitle)
                    .font(AppTheme.Typography.emptySubtitle)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }

            if let primaryButtonTitle, let onPrimaryAction {
                Button(action: onPrimaryAction) {
                    if let primaryButtonIcon {
                        Label(primaryButtonTitle, systemImage: primaryButtonIcon)
                    } else {
                        Text(primaryButtonTitle)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            extraContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(AppTheme.Spacing.xxl)
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.xl)
                .strokeBorder(
                    isDropTargeted ? AppTheme.Colors.accent : Color.clear,
                    style: StrokeStyle(lineWidth: 2, dash: [8, 4])
                )
                .padding(AppTheme.Spacing.lg)
        )
    }
}

struct AppSidebarSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(AppTheme.Typography.sidebarHeader)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}

struct AppToolboxSidebarRow<Trailing: View>: View {
    let title: String
    let systemImage: String
    var isSelected: Bool = false
    @ViewBuilder var trailing: () -> Trailing

    @Environment(\.backgroundProminence) private var backgroundProminence

    init(
        _ title: String,
        systemImage: String,
        isSelected: Bool = false,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 13.5, weight: .medium))
                .imageScale(.medium)
                .frame(width: 22, alignment: .center)
                .foregroundStyle(backgroundProminence == .increased ? Color.white : AppTheme.Colors.accent)

            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            trailing()
        }
        .contentShape(Rectangle())
    }
}

extension AppToolboxSidebarRow where Trailing == EmptyView {
    init(
        _ title: String,
        systemImage: String,
        isSelected: Bool = false
    ) {
        self.init(title, systemImage: systemImage, isSelected: isSelected) {
            EmptyView()
        }
    }
}

struct AppSidebarIndicatorDot: View {
    @Environment(\.backgroundProminence) private var backgroundProminence

    var body: some View {
        Circle()
            .fill(backgroundProminence == .increased ? Color.white.opacity(0.9) : AppTheme.Colors.accent)
            .frame(width: 6, height: 6)
    }
}

struct AppToolboxSidebarHeader: View {
    let title: String
    var badgeText: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppTheme.Spacing.xs + 2) {
                Text(title)
                    .font(AppTheme.Typography.sectionTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if let badgeText {
                    AppStatusBadge(text: badgeText, tint: AppTheme.Colors.accent)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.md + 2)
            .padding(.vertical, AppTheme.Spacing.md)

            AppDivider()
        }
    }
}

struct AppHeaderPill: View {
    let text: String
    var systemImage: String? = nil
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(AppTheme.Typography.badge)
            }
            Text(text)
                .font(AppTheme.Typography.monoCaption)
                .lineLimit(1)
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, 3)
        .background(tint == .secondary ? AppTheme.Colors.neutralTint : tint.opacity(0.14))
        .foregroundStyle(tint == .secondary ? Color.primary : tint)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct AppLoadingStateView: View {
    let message: String

    var body: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            ProgressView()
            Text(message)
                .font(AppTheme.Typography.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(AppTheme.Spacing.xxl)
    }
}

struct AppToolboxHeader<Accessory: View>: View {
    let title: String
    let subtitle: String
    var metadataText: String? = nil
    @ViewBuilder var accessory: Accessory

    init(
        title: String,
        subtitle: String,
        metadataText: String? = nil,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.metadataText = metadataText
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: AppTheme.Spacing.sm) {
                    Text(title)
                        .font(AppTheme.Typography.pageTitle)
                        .lineLimit(1)

                    Spacer(minLength: AppTheme.Spacing.sm)

                    accessory

                    if let metadataText, !metadataText.isEmpty {
                        AppHeaderPill(text: metadataText)
                    }
                }

                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    HStack(alignment: .center, spacing: AppTheme.Spacing.sm) {
                        Text(title)
                            .font(AppTheme.Typography.pageTitle)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer(minLength: AppTheme.Spacing.xs)

                        accessory
                    }

                    if let metadataText, !metadataText.isEmpty {
                        AppHeaderPill(text: metadataText)
                    }
                }
            }

            Text(subtitle)
                .font(AppTheme.Typography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, AppTheme.Spacing.xl)
        .padding(.top, AppTheme.Spacing.md + 2)
        .padding(.bottom, AppTheme.Spacing.sm + 2)
    }
}

struct AppFileSelectionStripItem: Identifiable {
    let id: UUID
    let title: String
    let formatLabel: String
    let isSelected: Bool
}

struct AppFileSelectionStrip<Trailing: View>: View {
    let title: String
    let items: [AppFileSelectionStripItem]
    let onToggleItem: (UUID) -> Void
    @ViewBuilder var trailingControls: Trailing

    init(
        title: String,
        items: [AppFileSelectionStripItem],
        onToggleItem: @escaping (UUID) -> Void,
        @ViewBuilder trailingControls: () -> Trailing
    ) {
        self.title = title
        self.items = items
        self.onToggleItem = onToggleItem
        self.trailingControls = trailingControls()
    }

    var body: some View {
        VStack(spacing: 0) {
            AppDivider()
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs + 2) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Text(title)
                            .font(AppTheme.Typography.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: AppTheme.Spacing.sm)
                        trailingControls
                            .fixedSize(horizontal: true, vertical: false)
                    }

                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        Text(title)
                            .font(AppTheme.Typography.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        HStack(spacing: AppTheme.Spacing.sm) {
                            Spacer(minLength: 0)
                            trailingControls
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AppTheme.Spacing.xs + 2) {
                        ForEach(items) { item in
                            Button {
                                onToggleItem(item.id)
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: item.isSelected ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(item.isSelected ? AppTheme.Colors.accent : .secondary)
                                    Text(item.title)
                                        .lineLimit(1)
                                    if !item.formatLabel.isEmpty {
                                        Text(item.formatLabel)
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .font(AppTheme.Typography.caption)
                                .padding(.horizontal, AppTheme.Spacing.sm)
                                .padding(.vertical, AppTheme.Spacing.xs)
                                .background(
                                    item.isSelected
                                        ? AppTheme.Colors.accentTint
                                        : AppTheme.Colors.cardBackground
                                )
                                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                                .overlay(
                                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                                        .strokeBorder(
                                            item.isSelected ? AppTheme.Colors.accent.opacity(0.35) : AppTheme.Colors.cardBorder,
                                            lineWidth: 1
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(item.formatLabel.isEmpty ? item.title : "\(item.title), \(item.formatLabel)")
                            .accessibilityValue(item.isSelected ? "Selected" : "Not selected")
                        }
                    }
                }
            }
            .padding(.horizontal, AppTheme.Spacing.xl)
            .padding(.vertical, AppTheme.Spacing.sm)
            .background(AppTheme.Colors.subtleSurface)
            AppDivider()
        }
    }
}

struct AppBottomActionBar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            AppDivider()
            content
                .padding(.horizontal, AppTheme.Layout.actionBarHorizontalPadding)
                .padding(.vertical, AppTheme.Layout.actionBarVerticalPadding)
                .background(AppTheme.Colors.subtleSurface)
        }
    }
}

// MARK: - System Appearance Monitor

@MainActor
final class SystemAppearanceMonitor: ObservableObject {
    static let shared = SystemAppearanceMonitor()

    @Published private(set) var colorScheme: ColorScheme

    private var appearanceObservation: NSKeyValueObservation?
    private var themeChangeObserver: NSObjectProtocol?

    init() {
        self.colorScheme = Self.detectSystemColorScheme()
        if let app = NSApp {
            appearanceObservation = app.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.refresh()
                }
            }
        }
        themeChangeObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    func refresh() {
        let resolved = Self.detectSystemColorScheme()
        if colorScheme != resolved {
            colorScheme = resolved
        }
    }

    static func detectSystemColorScheme() -> ColorScheme {
        if let app = NSApp {
            return app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        }
        let style = UserDefaults.standard.string(forKey: "AppleInterfaceStyle")
        return style == "Dark" ? .dark : .light
    }
}

// MARK: - Opaque Window & Surface Helpers

struct OpaqueWindowChromeHost: NSViewRepresentable {
    let preferredColorScheme: ColorScheme?

    func makeNSView(context: Context) -> OpaqueChromeSentinelView {
        OpaqueChromeSentinelView(preferredColorScheme: preferredColorScheme)
    }

    func updateNSView(_ nsView: OpaqueChromeSentinelView, context: Context) {
        nsView.preferredColorScheme = preferredColorScheme
        nsView.applyOpaqueWindowChrome()
    }

    static func neutralizeBehindWindowVibrancy(in rootView: NSView) {
        for subview in rootView.subviews {
            if let vev = subview as? NSVisualEffectView {
                if vev.blendingMode != .withinWindow {
                    vev.blendingMode = .withinWindow
                }
                if vev.state != .inactive {
                    vev.state = .inactive
                }
            }
            neutralizeBehindWindowVibrancy(in: subview)
        }
    }

    final class OpaqueChromeSentinelView: NSView {
        var preferredColorScheme: ColorScheme?
        private(set) var appliedWindowID: ObjectIdentifier?
        private(set) var lastAppliedScheme: ColorScheme?
        private(set) var lastEffectiveAppearanceName: NSAppearance.Name?
        private(set) var hasAppliedInitialChrome: Bool = false
        private(set) var applyCount: Int = 0
        private(set) var vibrancyNeutralizationCount: Int = 0
        private var isApplyingChrome: Bool = false

        init(preferredColorScheme: ColorScheme?) {
            self.preferredColorScheme = preferredColorScheme
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let win = window else {
                appliedWindowID = nil
                hasAppliedInitialChrome = false
                lastEffectiveAppearanceName = nil
                return
            }
            applyOpaqueWindowChrome(force: appliedWindowID != ObjectIdentifier(win))
            Task { @MainActor in
                AppLifecycleManager.shared.registerWindow(win)
            }
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            if preferredColorScheme == nil {
                applyOpaqueWindowChrome()
            }
        }

        private func resolvedEffectiveAppearanceName(for window: NSWindow) -> NSAppearance.Name {
            switch preferredColorScheme {
            case .light:
                return .aqua
            case .dark:
                return .darkAqua
            case nil:
                let source = NSApp?.effectiveAppearance ?? window.effectiveAppearance
                return source.bestMatch(from: [.darkAqua, .aqua]) ?? .aqua
            @unknown default:
                return .aqua
            }
        }

        func applyOpaqueWindowChrome(force: Bool = false) {
            guard !isApplyingChrome else { return }
            guard let window else {
                appliedWindowID = nil
                hasAppliedInitialChrome = false
                lastEffectiveAppearanceName = nil
                return
            }

            let windowID = ObjectIdentifier(window)
            let effectiveName = resolvedEffectiveAppearanceName(for: window)
            let windowChanged = (appliedWindowID != windowID)
            let schemeChanged = !hasAppliedInitialChrome || (lastAppliedScheme != preferredColorScheme)
            let effectiveChanged = (lastEffectiveAppearanceName != effectiveName)

            guard force || windowChanged || schemeChanged || effectiveChanged else {
                return
            }

            isApplyingChrome = true
            defer { isApplyingChrome = false }

            // Commit cache state before mutating window.appearance so synchronous
            // viewDidChangeEffectiveAppearance() callbacks cannot re-enter with stale state.
            appliedWindowID = windowID
            lastAppliedScheme = preferredColorScheme
            lastEffectiveAppearanceName = effectiveName
            hasAppliedInitialChrome = true
            applyCount += 1

            let targetAppearance: NSAppearance?
            switch preferredColorScheme {
            case .light:
                targetAppearance = NSAppearance(named: .aqua)
            case .dark:
                targetAppearance = NSAppearance(named: .darkAqua)
            case nil:
                targetAppearance = nil
            @unknown default:
                targetAppearance = nil
            }

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if window.appearance?.name != targetAppearance?.name {
                window.appearance = targetAppearance
            }
            if !window.isOpaque {
                window.isOpaque = true
            }
            window.backgroundColor = AppTheme.Colors.workspaceNSColor
            if let themeFrame = window.contentView?.superview {
                OpaqueWindowChromeHost.neutralizeBehindWindowVibrancy(in: themeFrame)
                vibrancyNeutralizationCount += 1
            }
            window.contentView?.needsDisplay = true
            CATransaction.commit()
        }
    }
}

extension View {
    func appMainSidebarSurface() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(AppTheme.Colors.mainSidebarBackground.ignoresSafeArea())
    }

    func appSecondarySidebarSurface() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(AppTheme.Colors.secondarySidebarBackground.ignoresSafeArea())
    }

    func appWorkspaceSurface() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(AppTheme.Colors.workspaceBackground.ignoresSafeArea())
    }

    func appOpaqueWindowChrome(preferredColorScheme: ColorScheme?) -> some View {
        self
            .background(OpaqueWindowChromeHost(preferredColorScheme: preferredColorScheme).frame(width: 0, height: 0))
            .toolbarBackground(AppTheme.Colors.workspaceBackground, for: .windowToolbar)
            .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
    }
}
