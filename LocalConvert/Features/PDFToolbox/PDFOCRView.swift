import SwiftUI
import PDFKit

struct PDFOCRView: View {
    @EnvironmentObject private var appState: AppState
    let selectedFiles: [DroppedFile]
    @Binding var password: String
    let onRunOCR: (PDFOCROptions) -> Void

    @State private var supportedLanguages: [String] = []
    @State private var previewStatus: String? = nil
    @State private var isAnalyzingPreview: Bool = false

    private var ocrConfigKey: String {
        PDFToolboxStore.configKey(for: selectedFiles.map(\.url))
    }

    private var options: PDFOCROptions {
        appState.pdfToolboxStore.ocrConfig(for: ocrConfigKey)
    }

    private func ocrBinding<Value: Equatable>(
        title: String,
        coalesceKey: String? = nil,
        get: @escaping (PDFOCROptions) -> Value,
        set: @escaping (inout PDFOCROptions, Value) -> Void
    ) -> Binding<Value> {
        let key = ocrConfigKey
        let urls = selectedFiles.map(\.url)
        return Binding(
            get: { get(appState.pdfToolboxStore.ocrConfig(for: key)) },
            set: { newValue in
                appState.pdfToolboxStore.updateOCRConfig(
                    for: key,
                    affectedURLs: urls,
                    title: title,
                    coalesceKey: coalesceKey
                ) { cfg in
                    set(&cfg, newValue)
                }
            }
        )
    }

    private var primaryLanguageBinding: Binding<String> {
        ocrBinding(title: "Change OCR Primary Language", get: { $0.languageCodes.first ?? "en-US" }) { cfg, newPrimary in
            let currentSecondary = cfg.languageCodes.dropFirst().first
            var nextLangs = [newPrimary]
            if let currentSecondary, currentSecondary != newPrimary {
                nextLangs.append(currentSecondary)
            }
            cfg.languageCodes = nextLangs
        }
    }

    private var secondaryLanguageBinding: Binding<String> {
        ocrBinding(title: "Change OCR Secondary Language", get: { $0.languageCodes.dropFirst().first ?? "None" }) { cfg, newSecondary in
            let primary = cfg.languageCodes.first ?? "en-US"
            var nextLangs = [primary]
            if newSecondary != "None" && newSecondary != primary {
                nextLangs.append(newSecondary)
            }
            cfg.languageCodes = nextLangs
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            AppCard(title: "Vision OCR Settings", icon: "text.viewfinder") {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: AppTheme.Spacing.md) {
                            ocrLanguageRowFields
                        }
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                            ocrLanguageRowFields
                        }
                    }

                    HStack(spacing: AppTheme.Spacing.lg) {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                            Text("Page Ranges (Optional)")
                                .font(AppTheme.Typography.caption)
                                .foregroundStyle(.secondary)
                            TextField("All pages (e.g. 1-3, 5)", text: ocrBinding(title: "Edit OCR Page Range", coalesceKey: "ocr_ranges", get: \.pageRanges, set: { $0.pageRanges = $1 }))
                                .textFieldStyle(.roundedBorder)
                                .frame(minWidth: 160, maxWidth: 210)
                        }

                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                            Text("Rasterization DPI: \(Int(options.renderDPI))")
                                .font(AppTheme.Typography.caption)
                                .foregroundStyle(.secondary)
                            Slider(value: ocrBinding(title: "Change OCR Resolution", coalesceKey: "ocr_dpi", get: \.renderDPI, set: { $0.renderDPI = $1 }), in: 120...300, step: 20)
                                .frame(minWidth: 130, maxWidth: 160)
                                .accessibilityLabel("OCR rasterization resolution")
                                .accessibilityValue("\(Int(options.renderDPI)) DPI")
                        }
                    }

                    Toggle("Skip pages that already contain searchable text", isOn: ocrBinding(title: "Toggle Skip Searchable Pages", get: \.skipExistingTextPages, set: { $0.skipExistingTextPages = $1 }))
                    Toggle("Use Vision language correction", isOn: ocrBinding(title: "Toggle OCR Language Correction", get: \.usesLanguageCorrection, set: { $0.usesLanguageCorrection = $1 }))
                    Toggle("Auto-detect document languages (multi-script)", isOn: ocrBinding(title: "Toggle OCR Language Detection", get: \.automaticallyDetectsLanguage, set: { $0.automaticallyDetectsLanguage = $1 }))
                    Toggle("Sort multi-column reading order (left column then right)", isOn: ocrBinding(title: "Toggle Multi-Column OCR", get: \.multiColumnReadingOrder, set: { $0.multiColumnReadingOrder = $1 }))
                    Toggle("Auto-deskew tilted scanned pages", isOn: ocrBinding(title: "Toggle OCR Deskew", get: \.deskewPages, set: { $0.deskewPages = $1 }))
                    Toggle("Also export extracted text as a separate .txt file", isOn: ocrBinding(title: "Toggle OCR Text Sidecar", get: \.exportExtractedTextSidecar, set: { $0.exportExtractedTextSidecar = $1 }))
                }
            }

            if selectedFiles.count == 1, let file = selectedFiles.first {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Button {
                            inspectExistingText(url: file.url)
                        } label: {
                            Label(isAnalyzingPreview ? "Inspecting..." : "Preview / Check Searchable Text", systemImage: "doc.text.magnifyingglass")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isAnalyzingPreview)
                    }

                    if let previewStatus {
                        AppInfoBanner(style: .info, message: previewStatus)
                    }
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppTheme.Spacing.md) {
                    Text("Generates a new PDF embedding an invisible CoreText layer over each OCR'd page, leaving your source PDF untouched. Batch selection supported.")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    runOCRButton
                }

                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    Text("Generates a new PDF embedding an invisible CoreText layer over each OCR'd page, leaving your source PDF untouched. Batch selection supported.")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer(minLength: 0)
                        runOCRButton
                    }
                }
            }
        }
        .onAppear {
            loadLanguages()
        }
        .onChange(of: options.recognitionLevel) {
            loadLanguages()
        }
    }

    private var runOCRButton: some View {
        Button {
            onRunOCR(resolvedOptions())
        } label: {
            Label(selectedFiles.count > 1 ? "Batch OCR (\(selectedFiles.count) PDFs)" : "Create Searchable PDF", systemImage: "text.viewfinder")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(selectedFiles.isEmpty)
    }

    @ViewBuilder
    private var ocrLanguageRowFields: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            Text("Recognition Level")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(.secondary)
            Picker("Recognition Level", selection: ocrBinding(title: "Change OCR Recognition Level", get: \.recognitionLevel, set: { $0.recognitionLevel = $1 })) {
                ForEach(PDFOCRRecognitionLevel.allCases) { level in
                    Text(level.displayName).tag(level)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 180)
        }

        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            Text("Primary Language")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(.secondary)
            Picker("Primary Language", selection: primaryLanguageBinding) {
                ForEach(supportedLanguages, id: \.self) { code in
                    Text(PDFOCRService.humanLanguageName(for: code)).tag(code)
                }
            }
            .labelsHidden()
            .frame(minWidth: 150, maxWidth: 230)
        }

        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            Text("Secondary Language")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(.secondary)
            Picker("Secondary Language", selection: secondaryLanguageBinding) {
                Text("None").tag("None")
                ForEach(supportedLanguages, id: \.self) { code in
                    Text(PDFOCRService.humanLanguageName(for: code)).tag(code)
                }
            }
            .labelsHidden()
            .frame(minWidth: 140, maxWidth: 200)
        }
    }

    private func loadLanguages() {
        supportedLanguages = PDFOCRService.supportedLanguages(for: options.recognitionLevel)
    }

    private func resolvedOptions() -> PDFOCROptions {
        var copy = options
        if copy.languageCodes.isEmpty {
            copy.languageCodes = ["en-US"]
        }
        copy.password = password.isEmpty ? nil : password
        return copy
    }

    private func inspectExistingText(url: URL) {
        isAnalyzingPreview = true
        previewStatus = nil
        let pwd = password.isEmpty ? nil : password
        Task.detached {
            do {
                let sample = try PDFRedactionService.findSearchRegions(in: url, searchTerms: [], password: pwd)
                _ = sample
                let report = try PDFDocumentInspector.inspect(url: url, password: pwd)
                let summary: String
                if let doc = PDFDocument(url: url) {
                    if doc.isLocked, let pwd { _ = doc.unlock(withPassword: pwd) }
                    let charCount = (doc.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).count
                    summary = charCount >= 12
                        ? "\(report.pageCount) page(s), already has ~\(charCount) selectable text characters."
                        : "\(report.pageCount) page(s), scanned/image-heavy (no searchable text layer detected)."
                } else {
                    summary = "Unable to inspect text."
                }
                await MainActor.run {
                    previewStatus = summary
                    isAnalyzingPreview = false
                }
            } catch {
                await MainActor.run {
                    previewStatus = error.localizedDescription
                    isAnalyzingPreview = false
                }
            }
        }
    }
}
