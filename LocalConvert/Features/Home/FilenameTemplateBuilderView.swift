import SwiftUI

struct FilenameTemplateBuilderView: View {
    @AppStorage(OutputManager.filenameTemplateKey, store: AppStoragePaths.userDefaults)
    private var storedTemplate: String = OutputManager.defaultFilenameTemplate

    private let externalTemplateBinding: Binding<String>?

    init(template: Binding<String>? = nil) {
        self.externalTemplateBinding = template
    }

    private var templateBinding: Binding<String> {
        if let externalTemplateBinding {
            return externalTemplateBinding
        }
        return $storedTemplate
    }

    private var currentTemplate: String {
        templateBinding.wrappedValue
    }

    private var livePreviewFilename: String {
        OutputManager.previewFilename(for: currentTemplate)
    }

    private var isCustomTemplate: Bool {
        currentTemplate.trimmingCharacters(in: .whitespacesAndNewlines) != OutputManager.defaultFilenameTemplate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(alignment: .center, spacing: AppTheme.Spacing.sm) {
                Text("Filename Template")
                    .font(AppTheme.Typography.cardTitle)
                    .lineLimit(1)

                Spacer(minLength: AppTheme.Spacing.xs)

                if isCustomTemplate {
                    Button("Reset") {
                        templateBinding.wrappedValue = OutputManager.defaultFilenameTemplate
                    }
                    .controlSize(.small)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel("Reset filename template to default")
                    .accessibilityIdentifier("settings.filenameTemplate.resetButton")
                }
            }

            TextField(OutputManager.defaultFilenameTemplate, text: templateBinding)
                .font(AppTheme.Typography.monoCaption)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Output Filename Template")
                .accessibilityHint("Use tokens such as {name}, {date}, or {resolution} to customize output filenames.")
                .accessibilityIdentifier("settings.filenameTemplate.field")

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("Insert Token")
                    .font(AppTheme.Typography.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 132), spacing: AppTheme.Spacing.xs)],
                    alignment: .leading,
                    spacing: AppTheme.Spacing.xs
                ) {
                    ForEach(FilenameTemplateToken.allCases) { token in
                        FilenameTokenChipButton(token: token) {
                            templateBinding.wrappedValue = OutputManager.appendingToken(
                                token,
                                to: currentTemplate
                            )
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                HStack(alignment: .center, spacing: AppTheme.Spacing.xs) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.Colors.accent)

                    Text("Live Preview")
                        .font(AppTheme.Typography.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer(minLength: AppTheme.Spacing.xs)

                    AppStatusBadge(
                        text: "\(livePreviewFilename.utf8.count)/\(OutputManager.maxFilenameUTF8Bytes) B",
                        tint: livePreviewFilename.utf8.count >= OutputManager.maxFilenameUTF8Bytes
                            ? AppTheme.Colors.warning
                            : AppTheme.Colors.info,
                        style: .rounded
                    )
                }

                Text(livePreviewFilename)
                    .font(AppTheme.Typography.monoCaption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Live filename preview: \(livePreviewFilename)")
                    .accessibilityIdentifier("settings.filenameTemplate.preview")
            }
            .padding(AppTheme.Spacing.sm)
            .background(AppTheme.Colors.elevatedSurface)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
            )

            Text("Path separators (/ and :) are sanitized automatically and filenames are clamped to 240 UTF-8 bytes.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, AppTheme.Spacing.xxs)
    }
}

private struct FilenameTokenChipButton: View {
    let token: FilenameTemplateToken
    let action: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            Text(token.chipLabel)
                .font(AppTheme.Typography.monoCaption)
                .foregroundStyle(AppTheme.Colors.accent)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AppTheme.Spacing.sm)
                .padding(.vertical, AppTheme.Spacing.xs + 1)
                .background(AppTheme.Colors.accent.opacity(isHovered ? 0.22 : 0.14))
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .strokeBorder(AppTheme.Colors.accent.opacity(isHovered ? 0.45 : 0.25), lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .help(token.shortDescription)
        .accessibilityLabel("Insert \(token.rawValue) token")
        .accessibilityHint(token.shortDescription)
        .accessibilityIdentifier("settings.filenameTemplate.chip.\(token.accessibilityKey)")
    }
}
