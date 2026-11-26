import SwiftUI
import AppKit

// MARK: - 6. Metadata & Privacy Cleaner Section

struct ImageMetadataPrivacyView: View {
    @Binding var config: ImageToolboxConfig
    let sourceURL: URL?
    let summary: ImageMetadataPrivacySummary?
    let detailedMeta: ImageDetailedMetadataSnapshot?
    let onReload: () -> Void
    let onSaveMetadataNow: (URL?) -> Void

    @State private var selectedCategory: ImageMetadataCategory? = nil
    @State private var showInPlaceConfirmation: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            AppCard(title: "Privacy Audit & Container Inspection", icon: "shield.lefthalf.filled") {
                if let info = summary {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: AppTheme.Spacing.sm) {
                                auditBadgesRow(info)
                                Spacer(minLength: 0)
                                Button("Re-inspect", action: onReload)
                                    .controlSize(.small)
                            }
                            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                                HStack(spacing: AppTheme.Spacing.sm) {
                                    auditBadgesRow(info)
                                }
                                Button("Re-inspect", action: onReload)
                                    .controlSize(.small)
                            }
                        }

                        if let detail = detailedMeta {
                            if let gpsStr = detail.gpsSummary {
                                AppInfoBanner(
                                    style: .warning,
                                    message: "GPS Coordinates Embedded: \(gpsStr) — Strip GPS before sharing."
                                )
                            }

                            let cameraLabel = [detail.cameraMake, detail.cameraModel].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: AppTheme.Spacing.sm)], alignment: .leading, spacing: AppTheme.Spacing.xs) {
                                metaFact("Camera", cameraLabel.isEmpty ? "None" : cameraLabel)
                                metaFact("Lens", detail.lensModel ?? "None")
                                metaFact("Captured", detail.dateTaken ?? "—")
                                metaFact("Software", detail.software ?? "—")
                                metaFact("DPI / Print", detail.dpiWidth.map { "\(Int($0.rounded())) DPI" } ?? "Default (72 DPI)")
                                metaFact("XMP Packet", detail.hasXMPData ? "\(detail.xmpByteCount) B" : "None")
                            }

                            AppInfoBanner(
                                style: detail.supportsLosslessMetadataRewrite ? .success : .info,
                                message: detail.formatLimitationNote
                            )
                        }
                    }
                } else {
                    Text("Inspecting image metadata...")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let detail = detailedMeta, !detail.entries.isEmpty {
                let diff = ImageMetadataInspectorService.previewDiff(snapshot: detail, payload: config.metadataEdit)
                AppCard(title: "EXIF, IPTC, XMP & TIFF Tags (\(detail.entries.count) found)", icon: "list.bullet.rectangle") {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                        HStack(spacing: AppTheme.Spacing.xs) {
                            Button("All (\(detail.entries.count))") { selectedCategory = nil }
                                .controlSize(.small)
                                .buttonStyle(.bordered)
                                .tint(selectedCategory == nil ? AppTheme.Colors.accent : .secondary)
                            ForEach(ImageMetadataCategory.allCases) { cat in
                                let cnt = detail.entries.filter { $0.category == cat }.count
                                if cnt > 0 {
                                    Button("\(cat.rawValue) (\(cnt))") { selectedCategory = cat }
                                        .controlSize(.small)
                                        .buttonStyle(.bordered)
                                        .tint(selectedCategory == cat ? AppTheme.Colors.accent : .secondary)
                                }
                            }
                        }

                        let filtered = detail.entries.filter { selectedCategory == nil || $0.category == selectedCategory }
                        ForEach(filtered.prefix(20)) { entry in
                            let willStrip = diff.removedEntries.contains(where: { $0.id == entry.id })
                            HStack(spacing: AppTheme.Spacing.sm) {
                                Text(entry.category.rawValue)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 110, alignment: .leading)
                                Text(entry.key)
                                    .font(AppTheme.Typography.monoCaption)
                                    .frame(width: 110, alignment: .leading)
                                Text(entry.value)
                                    .font(AppTheme.Typography.caption)
                                    .strikethrough(willStrip)
                                    .foregroundStyle(willStrip ? AppTheme.Colors.error : .primary)
                                    .lineLimit(1)
                                Spacer()
                                AppStatusBadge(text: willStrip ? "Strip" : "Keep", tint: willStrip ? AppTheme.Colors.error : AppTheme.Colors.success)
                            }
                            .padding(.vertical, 2)
                        }

                        AppDivider()

                        HStack {
                            Text("Before → After Tag Diff:")
                                .font(AppTheme.Typography.caption.weight(.medium))
                            Text("\(diff.beforeCount) tags → \(diff.afterCount) kept (\(diff.removedEntries.count) removed)")
                                .font(AppTheme.Typography.monoCaption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            AppCard(title: "Selective Privacy Sanitizer & Non-Destructive Copy", icon: "hand.raised") {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    Picker("Policy", selection: $config.metadataEdit.policy) {
                        ForEach(ImageMetadataPrivacyPolicy.allCases) { policy in
                            Text(policy.rawValue).tag(policy)
                        }
                    }
                    .pickerStyle(.menu)

                    HStack(spacing: 8) {
                        Button("1-Click Strip All Metadata") {
                            config.metadataEdit.policy = .stripAll
                            config.metadataEdit.stripGPS = true
                            config.metadataEdit.stripCamera = true
                            config.metadataEdit.stripRights = true
                            config.metadataEdit.stripEXIF = true
                            config.metadataEdit.stripIPTC = true
                            config.metadataEdit.stripXMP = true
                        }
                        .controlSize(.small)

                        Button("1-Click Remove GPS Only") {
                            config.metadataEdit.policy = .stripGPSOnly
                            config.metadataEdit.stripGPS = true
                        }
                        .controlSize(.small)
                    }

                    if config.metadataEdit.policy == .preserveAll || config.metadataEdit.policy == .applyEditedMetadata {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: AppTheme.Spacing.sm)], alignment: .leading, spacing: AppTheme.Spacing.xs) {
                            Toggle("Strip GPS", isOn: $config.metadataEdit.stripGPS)
                            Toggle("Strip EXIF Camera", isOn: $config.metadataEdit.stripEXIF)
                            Toggle("Strip IPTC Rights", isOn: $config.metadataEdit.stripIPTC)
                            Toggle("Strip XMP Packet", isOn: $config.metadataEdit.stripXMP)
                            Toggle("Strip Software Tag", isOn: $config.metadataEdit.stripSoftware)
                        }
                        .font(.caption)
                    }

                    if config.metadataEdit.policy == .applyEditedMetadata {
                        Divider()
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                            GridRow {
                                Text("Title").font(.caption).foregroundStyle(.secondary)
                                TextField("Image Title", text: optionalBinding(\.title))
                                    .textFieldStyle(.roundedBorder)
                            }
                            GridRow {
                                Text("Author / Artist").font(.caption).foregroundStyle(.secondary)
                                TextField("Author", text: optionalBinding(\.author))
                                    .textFieldStyle(.roundedBorder)
                            }
                            GridRow {
                                Text("Copyright").font(.caption).foregroundStyle(.secondary)
                                TextField("© Copyright", text: optionalBinding(\.copyright))
                                    .textFieldStyle(.roundedBorder)
                            }
                            GridRow {
                                Text("Description").font(.caption).foregroundStyle(.secondary)
                                TextField("Caption / Description", text: optionalBinding(\.description))
                                    .textFieldStyle(.roundedBorder)
                            }
                            GridRow {
                                Text("Keywords").font(.caption).foregroundStyle(.secondary)
                                TextField("tag1, tag2", text: optionalBinding(\.keywordsCSV))
                                    .textFieldStyle(.roundedBorder)
                            }
                            GridRow {
                                Text("Camera Make").font(.caption).foregroundStyle(.secondary)
                                TextField("Make", text: optionalBinding(\.cameraMake))
                                    .textFieldStyle(.roundedBorder)
                            }
                            GridRow {
                                Text("Camera Model").font(.caption).foregroundStyle(.secondary)
                                TextField("Model", text: optionalBinding(\.cameraModel))
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                    }

                    Divider()

                    HStack {
                        Button("Save Privacy-Cleaned Copy...") {
                            guard let src = sourceURL else { return }
                            let panel = NSSavePanel()
                            panel.nameFieldStringValue = "\(src.deletingPathExtension().lastPathComponent)_clean.\(src.pathExtension)"
                            if panel.runModal() == .OK, let dest = panel.url {
                                onSaveMetadataNow(dest)
                            }
                        }
                        .disabled(sourceURL == nil)

                        Button("Apply In-Place to Source File", role: .destructive) {
                            showInPlaceConfirmation = true
                        }
                        .disabled(sourceURL == nil)
                        .alert("Overwrite Source File Metadata?", isPresented: $showInPlaceConfirmation) {
                            Button("Cancel", role: .cancel) {}
                            Button("Apply In-Place", role: .destructive) {
                                onSaveMetadataNow(nil)
                            }
                        } message: {
                            Text("This modifies the original image file directly. Use \"Save Privacy-Cleaned Copy...\" if you want to keep the original untouched.")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func auditBadgesRow(_ info: ImageMetadataPrivacySummary) -> some View {
        auditBadge("GPS Location", active: info.hasGPS, activeColor: .red)
        auditBadge("Camera Hardware EXIF", active: info.hasCameraHardwareInfo, activeColor: .orange)
        auditBadge("Author / Copyright", active: info.hasAuthorOrCopyright, activeColor: .blue)
        auditBadge("ICC Profile (\(info.iccProfileName))", active: info.hasICCProfile, activeColor: .teal)
        if info.isJXLContainer {
            auditBadge("JXL Boxes (Exif/xml)", active: true, activeColor: .purple)
        }
    }

    private func optionalBinding(_ keyPath: WritableKeyPath<ImageMetadataEditPayload, String?>) -> Binding<String> {
        Binding(
            get: { config.metadataEdit[keyPath: keyPath] ?? "" },
            set: { newVal in
                let trimmed = newVal.trimmingCharacters(in: .whitespacesAndNewlines)
                config.metadataEdit[keyPath: keyPath] = trimmed.isEmpty ? nil : newVal
            }
        )
    }

    private func metaFact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.medium)).lineLimit(1)
        }
    }

    @ViewBuilder
    private func auditBadge(_ label: String, active: Bool, activeColor: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(active ? activeColor : Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background((active ? activeColor : Color.secondary).opacity(0.12))
        .clipShape(Capsule())
    }
}
