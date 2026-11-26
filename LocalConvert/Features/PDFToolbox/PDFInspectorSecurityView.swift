import SwiftUI

struct PDFInspectorSecurityView: View {
    let selectedFiles: [DroppedFile]
    @Binding var password: String
    let onApplySecurity: (PDFSecurityOptions) -> Void

    @State private var report: PDFDocumentInspectionReport? = nil
    @State private var inspectionError: String? = nil
    @State private var isInspecting: Bool = false
    @State private var inspectorTab: Int = 0

    // Security controls
    @State private var securityMode: PDFSecurityOptions.Mode = .encrypt
    @State private var newUserPassword: String = ""
    @State private var newOwnerPassword: String = ""
    @State private var allowPrinting: Bool = true
    @State private var allowHighQualityPrinting: Bool = true
    @State private var allowCopying: Bool = true
    @State private var allowAccessibility: Bool = true
    @State private var allowCommenting: Bool = true
    @State private var allowFormEntry: Bool = true
    @State private var allowDocumentChanges: Bool = false
    @State private var allowDocumentAssembly: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            if selectedFiles.count != 1 {
                AppInfoBanner(style: .info, message: "Select a single PDF file to inspect internals and configure encryption/permissions.")
            } else if let file = selectedFiles.first {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Picker("", selection: $inspectorTab) {
                        Text("Overview").tag(0)
                        Text("Fonts (\(report?.fonts.count ?? 0))").tag(1)
                        Text("Images (\(report?.images.count ?? 0))").tag(2)
                        Text("Security").tag(3)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    Button {
                        refreshInspection(url: file.url)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isInspecting)
                    .help("Re-inspect PDF")
                    .accessibilityLabel("Re-inspect PDF")
                }

                if let inspectionError {
                    AppInfoBanner(style: .error, message: inspectionError)
                }

                if let report {
                    if !report.warnings.isEmpty && inspectorTab == 0 {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                            ForEach(report.warnings) { warn in
                                AppInfoBanner(
                                    style: warn.severity == .critical ? .error : .warning,
                                    message: warn.message
                                )
                            }
                        }
                    }

                    switch inspectorTab {
                    case 0:
                        overviewPanel(report)
                    case 1:
                        fontsPanel(report)
                    case 2:
                        imagesPanel(report)
                    default:
                        securityPanel(report)
                    }
                }
            }
        }
        .onAppear {
            if let file = selectedFiles.first { refreshInspection(url: file.url) }
        }
        .onChange(of: selectedFiles.map { $0.id }) { _, _ in
            if let file = selectedFiles.first { refreshInspection(url: file.url) }
        }
        .onChange(of: password) { _, _ in
            if let file = selectedFiles.first { refreshInspection(url: file.url) }
        }
    }

    @ViewBuilder
    private func overviewPanel(_ r: PDFDocumentInspectionReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                AppCard(title: "Document Structure", icon: "doc.text.magnifyingglass") {
                    Grid(alignment: .leading, horizontalSpacing: AppTheme.Spacing.lg, verticalSpacing: AppTheme.Spacing.xs) {
                        infoRow("PDF Version", r.pdfVersion)
                        infoRow("Pages", "\(r.pageCount) (\(r.orientationsSummary))")
                        infoRow("Page Dimensions", r.pageDimensionsSummary)
                        infoRow("File Size", ByteCountFormatter.string(fromByteCount: r.fileSizeBytes, countStyle: .file))
                        infoRow("Annotations / Forms", "\(r.annotationCount) annotation(s), \(r.formFieldCount) form field(s)\(r.hasAcroForm ? " [AcroForm]" : "")\(r.hasXFA ? " [XFA]" : "")")
                        infoRow("Digital Signatures", r.hasDigitalSignatures ? r.signatureFieldNames.joined(separator: ", ") : "None")
                        infoRow("Transparency", r.hasTransparency ? "Present (/Group or /SMask)" : "None Detected")
                    }
                }

                AppCard(title: "Metadata & XMP", icon: "info.circle") {
                    Grid(alignment: .leading, horizontalSpacing: AppTheme.Spacing.lg, verticalSpacing: AppTheme.Spacing.xs) {
                        infoRow("Title", r.title ?? "—")
                        infoRow("Author", r.author ?? "—")
                        infoRow("Subject", r.subject ?? "—")
                        infoRow("Creator", r.creator ?? "—")
                        infoRow("Producer", r.producer ?? "—")
                        infoRow("Created", r.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                        infoRow("Modified", r.modificationDate?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                        infoRow("XMP Stream", r.xmpSummary ?? "None")
                    }
                }
            }
        }
        .frame(maxHeight: 340)
    }

    @ViewBuilder
    private func fontsPanel(_ r: PDFDocumentInspectionReport) -> some View {
        AppCard(title: "Embedded & Referenced Fonts (\(r.unembeddedFontsCount) unembedded)", icon: "textformat") {
            ScrollView {
                if r.fonts.isEmpty {
                    Text("No font dictionaries referenced (document may be raster or outlined vector paths).")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .padding(AppTheme.Spacing.sm)
                } else {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        ForEach(r.fonts) { font in
                            HStack {
                                Image(systemName: font.isEmbedded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(font.isEmbedded ? AppTheme.Colors.success : AppTheme.Colors.warning)
                                Text(font.name)
                                    .font(AppTheme.Typography.subheadline)
                                    .fontWeight(.medium)
                                Spacer()
                                Text(font.subtype)
                                    .font(AppTheme.Typography.caption)
                                    .foregroundStyle(.secondary)
                                AppStatusBadge(
                                    text: font.isEmbedded ? "Embedded" : "Not Embedded",
                                    tint: font.isEmbedded ? AppTheme.Colors.success : AppTheme.Colors.warning
                                )
                            }
                            Divider()
                        }
                    }
                }
            }
            .frame(minHeight: 160, maxHeight: 280)
        }
    }

    @ViewBuilder
    private func imagesPanel(_ r: PDFDocumentInspectionReport) -> some View {
        AppCard(title: "Embedded Image Assets & Color Management", icon: "photo") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                HStack(spacing: AppTheme.Spacing.lg) {
                    Text("Color Spaces: \(r.colorSpaces.isEmpty ? "None" : r.colorSpaces.joined(separator: ", "))")
                        .font(AppTheme.Typography.caption)
                    AppStatusBadge(
                        text: "OutputIntent: \(r.hasOutputIntent ? "Present" : "Absent")",
                        tint: r.hasOutputIntent ? AppTheme.Colors.success : .secondary
                    )
                }

                ScrollView {
                    if r.images.isEmpty {
                        Text("No embedded XObject image streams detected.")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                            .padding(AppTheme.Spacing.sm)
                    } else {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                            ForEach(r.images) { img in
                                HStack {
                                    Text("Page \(img.pageNumber)")
                                        .font(AppTheme.Typography.caption)
                                        .fontWeight(.semibold)
                                    Text("\(img.width)×\(img.height)px")
                                        .font(AppTheme.Typography.caption)
                                        .monospacedDigit()
                                    Text("• \(img.colorSpace)")
                                        .font(AppTheme.Typography.caption)
                                    Text("• \(img.compressionFilter)")
                                        .font(AppTheme.Typography.caption)
                                        .foregroundStyle(.secondary)
                                    if img.hasSoftMask {
                                        AppStatusBadge(text: "Alpha SMask", tint: AppTheme.Colors.warning)
                                    }
                                    Spacer()
                                }
                                Divider()
                            }
                        }
                    }
                }
                .frame(minHeight: 140, maxHeight: 240)
            }
        }
    }

    @ViewBuilder
    private func securityPanel(_ r: PDFDocumentInspectionReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                AppCard(title: "Current Security Inspection", icon: "shield.checkerboard") {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                        Text("Status: \(r.encryptionCipherSummary)")
                            .font(AppTheme.Typography.subheadline)
                            .fontWeight(.medium)
                        Text("Printing: \(r.allowsHighQualityPrinting ? "High-DPI" : (r.allowsPrinting ? "Low-DPI Only" : "Restricted")) • Copying: \(r.allowsCopying ? "Allowed" : "Restricted") • Editing: \(r.allowsDocumentChanges ? "Allowed" : "Restricted")")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                        Text("Linearized: \(r.isLinearized ? "Yes" : "No") • Structure Tree: \(r.hasStructureTree ? "Tagged" : "Untagged") • Embedded Files: \(r.embeddedFileNames.count) • JS Triggers: \(r.hasJavaScriptActions ? "Detected" : "None")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if !r.digitalSignatures.isEmpty {
                    AppCard(title: "Digital Signatures (\(r.digitalSignatures.count))", icon: "signature") {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                            ForEach(r.digitalSignatures) { sig in
                                signatureRow(sig)
                                Divider()
                            }
                        }
                    }
                }

                if r.hasDigitalSignatures {
                    AppInfoBanner(
                        style: .warning,
                        message: "Digital Signature Warning: Applying encryption or removing passwords writes a new PDF and invalidates existing digital signatures."
                    )
                }

                AppCard(title: "Encrypt or Unlock to New PDF", icon: "lock.shield") {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                        Picker("Action", selection: $securityMode) {
                            Text("Encrypt & Set Permissions").tag(PDFSecurityOptions.Mode.encrypt)
                            Text("Remove Password Protection").tag(PDFSecurityOptions.Mode.decrypt)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        if securityMode == .encrypt {
                            HStack(spacing: AppTheme.Spacing.md) {
                                SecureField("Open / User Password (Optional)", text: $newUserPassword)
                                    .textFieldStyle(.roundedBorder)
                                SecureField("Permissions / Owner Password", text: $newOwnerPassword)
                                    .textFieldStyle(.roundedBorder)
                            }
                            Grid(alignment: .leading, horizontalSpacing: AppTheme.Spacing.lg, verticalSpacing: AppTheme.Spacing.xxs) {
                                GridRow {
                                    Toggle("Allow Printing", isOn: $allowPrinting)
                                    Toggle("High-Quality Print", isOn: $allowHighQualityPrinting)
                                }
                                GridRow {
                                    Toggle("Allow Content Copying", isOn: $allowCopying)
                                    Toggle("Allow Accessibility", isOn: $allowAccessibility)
                                }
                                GridRow {
                                    Toggle("Allow Comments", isOn: $allowCommenting)
                                    Toggle("Allow Form Entry", isOn: $allowFormEntry)
                                }
                                GridRow {
                                    Toggle("Allow Document Editing", isOn: $allowDocumentChanges)
                                    Toggle("Allow Page Assembly", isOn: $allowDocumentAssembly)
                                }
                            }
                            .font(AppTheme.Typography.caption)

                            Text("Disclaimer: PDF permission flags are honored by standard viewers, but cannot mathematically prevent all third-party extraction once opened.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Removes encryption using the current unlock password above (requires owner password if restrictions were set).")
                                .font(AppTheme.Typography.caption)
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Spacer()
                            Button {
                                let opts = PDFSecurityOptions(
                                    mode: securityMode,
                                    currentPassword: password,
                                    userPassword: newUserPassword,
                                    ownerPassword: newOwnerPassword,
                                    allowPrinting: allowPrinting,
                                    allowHighQualityPrinting: allowHighQualityPrinting,
                                    allowCopying: allowCopying,
                                    allowAccessibility: allowAccessibility,
                                    allowCommenting: allowCommenting,
                                    allowFormEntry: allowFormEntry,
                                    allowDocumentChanges: allowDocumentChanges,
                                    allowDocumentAssembly: allowDocumentAssembly
                                )
                                _ = opts.makeCGPermissions()
                                newUserPassword = ""
                                newOwnerPassword = ""
                                onApplySecurity(opts)
                            } label: {
                                Label(securityMode == .encrypt ? "Save Encrypted PDF" : "Save Unlocked PDF", systemImage: "lock.shield")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(securityMode == .encrypt && newUserPassword.isEmpty && newOwnerPassword.isEmpty)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: 320)
    }

    @ViewBuilder
    private func signatureRow(_ sig: PDFDigitalSignatureInfo) -> some View {
        let metaDetails = [
            sig.reason.map { "Reason: \($0)" },
            sig.location.map { "Location: \($0)" }
        ].compactMap { $0 }.joined(separator: " • ")

        let cryptoTint: Color = {
            switch sig.cryptoStatus {
            case .validDigest: return AppTheme.Colors.success
            case .invalidDigest, .malformedCMS: return AppTheme.Colors.error
            case .unsupportedSubFilter: return AppTheme.Colors.warning
            case .unsigned: return .secondary
            }
        }()

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(sig.fieldName)
                    .font(AppTheme.Typography.subheadline)
                    .fontWeight(.semibold)
                if let p = sig.pageNumber {
                    Text("Page \(p)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                AppStatusBadge(text: sig.cryptoStatus.rawValue, tint: cryptoTint)
                if let fullCover = sig.coversEntireFile {
                    AppStatusBadge(
                        text: fullCover ? "Full ByteRange" : "Partial ByteRange",
                        tint: fullCover ? AppTheme.Colors.success : AppTheme.Colors.warning
                    )
                }
            }
            if let signer = sig.signerName {
                let sf = sig.subFilter.map { " • \($0)" } ?? ""
                Text("Signer: \(signer)\(sf)")
                    .font(AppTheme.Typography.caption)
            }
            Text("1. Parsing: \(sig.cmsParsed ? "Valid CMS DER (\(sig.cmsCertificateCount) cert)" : "Unparsed / Unsigned")  •  2. Digest: \(sig.cryptoStatus.rawValue)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("3. Certificate & Chain: \(sig.trustChainStatus)\(sig.isCertificateExpired == true ? " (Expired)" : "")  •  4. Revocation: \(sig.revocationStatus)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if !sig.certificateSubjects.isEmpty {
                Text("CMS Certificate(s): \(sig.certificateSubjects.joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !metaDetails.isEmpty {
                Text(metaDetails)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
        }
    }

    private func refreshInspection(url: URL) {
        isInspecting = true
        inspectionError = nil
        let pwd = password.isEmpty ? nil : password
        Task.detached {
            do {
                let res = try PDFDocumentInspector.inspect(url: url, password: pwd)
                await MainActor.run {
                    report = res
                    isInspecting = false
                }
            } catch {
                await MainActor.run {
                    inspectionError = error.localizedDescription
                    isInspecting = false
                }
            }
        }
    }
}
