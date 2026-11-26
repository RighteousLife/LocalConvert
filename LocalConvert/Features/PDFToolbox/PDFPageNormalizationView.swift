import SwiftUI

struct PDFPageNormalizationView: View {
    private enum TargetMode: String, CaseIterable, Identifiable {
        case firstPage
        case specificPage
        case largestPage
        case standard
        case custom

        var id: String { rawValue }

        var title: String {
            switch self {
            case .firstPage: "First page dimensions"
            case .specificPage: "Specific source page"
            case .largestPage: "Largest visible page"
            case .standard: "Standard paper size"
            case .custom: "Custom dimensions"
            }
        }
    }

    private struct Review: Identifiable {
        let id = UUID()
        let sourceURL: URL
        let request: PDFPageNormalizationRequest
        let resolvedSize: PDFResolvedPageSize
        let pageCount: Int
        let preflight: PDFNormalizationPreflight
    }

    let selectedFiles: [DroppedFile]
    @Binding var password: String
    let onSubmit: (PDFPageNormalizationRequest, String?) -> Void

    @State private var targetMode: TargetMode = .firstPage
    @State private var orientation: PDFPageTargetOrientation = .reference
    @State private var selectedCatalog: PDFPageSizeCatalog = .isoA
    @State private var selectedPaperID = "iso-a4"
    @State private var specificPageText = "1"
    @State private var customWidth = "210"
    @State private var customHeight = "297"
    @State private var customUnit: PDFMeasurementUnit = .millimeters
    @State private var isInspecting = false
    @State private var activeRequestID = UUID()
    @State private var review: Review?
    @State private var errorMessage: String?

    private var sourceURL: URL? { selectedFiles.count == 1 ? selectedFiles.first?.url : nil }
    private var paperSizes: [PDFStandardPaperSize] { PDFPageSizeCatalogData.sizes(in: selectedCatalog) }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            AppCard(title: "Normalize Page Sizes", icon: "doc.text.magnifyingglass") {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    if let sourceURL {
                        Label(sourceURL.lastPathComponent, systemImage: "doc.fill")
                            .font(AppTheme.Typography.body)
                            .lineLimit(1)
                    } else {
                        AppInfoBanner(style: .warning, message: "Select exactly one source PDF to normalize.")
                    }

                    Picker("Target size", selection: $targetMode) {
                        ForEach(TargetMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .frame(maxWidth: 360)

                    targetControls

                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        Text("Each page is fitted proportionally and centered on a white page. Content is not cropped or stretched.")
                        Text("Review the resolved target size and source PDF inspection before adding the job to the queue.")
                    }
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(.secondary)

                    HStack {
                        Spacer()
                        Button(action: inspectAndReview) {
                            if isInspecting {
                                ProgressView().controlSize(.small)
                                Text("Inspecting PDF…")
                            } else {
                                Label("Review Target & Normalize", systemImage: "arrow.up.doc")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(sourceURL == nil || isInspecting)
                    }
                }
            }
        }
        .onChange(of: selectedCatalog) { _, catalog in
            selectedPaperID = PDFPageSizeCatalogData.sizes(in: catalog).first?.id ?? ""
        }
        .onChange(of: targetMode) { _, mode in
            if mode == .standard, orientation == .reference {
                orientation = .portrait
            }
        }
        .onChange(of: selectedFiles.map(\.url)) { _, _ in
            activeRequestID = UUID()
            review = nil
            isInspecting = false
        }
        .sheet(item: $review) { item in
            reviewSheet(item)
        }
        .alert("Could Not Prepare Normalization", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "The source PDF could not be inspected.")
        }
    }

    @ViewBuilder
    private var targetControls: some View {
        switch targetMode {
        case .firstPage, .specificPage, .largestPage:
            if targetMode == .specificPage {
                TextField("Source page number (1-based)", text: $specificPageText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .accessibilityLabel("Specific source page number")
            }
            Picker("Orientation", selection: $orientation) {
                Text("Match reference page").tag(PDFPageTargetOrientation.reference)
                Text("Portrait").tag(PDFPageTargetOrientation.portrait)
                Text("Landscape").tag(PDFPageTargetOrientation.landscape)
            }
            .frame(maxWidth: 300)
        case .standard:
            Picker("Paper family", selection: $selectedCatalog) {
                Text("ISO A").tag(PDFPageSizeCatalog.isoA)
                Text("ISO B").tag(PDFPageSizeCatalog.isoB)
                Text("JIS B").tag(PDFPageSizeCatalog.jisB)
                Text("North American").tag(PDFPageSizeCatalog.northAmerican)
            }
            .frame(maxWidth: 300)
            Picker("Paper format", selection: $selectedPaperID) {
                ForEach(paperSizes) { paper in
                    Text(paper.name).tag(paper.id)
                }
            }
            .frame(maxWidth: 300)
            Picker("Orientation", selection: $orientation) {
                Text("Portrait").tag(PDFPageTargetOrientation.portrait)
                Text("Landscape").tag(PDFPageTargetOrientation.landscape)
            }
            .frame(maxWidth: 300)
        case .custom:
            HStack(spacing: AppTheme.Spacing.sm) {
                TextField("Width", text: $customWidth)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 120)
                    .accessibilityLabel("Custom page width")
                Text("×")
                TextField("Height", text: $customHeight)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 120)
                    .accessibilityLabel("Custom page height")
                Picker("Unit", selection: $customUnit) {
                    ForEach(PDFMeasurementUnit.allCases) { unit in
                        Text(unit.rawValue).tag(unit)
                    }
                }
                .frame(maxWidth: 100)
            }
        }
    }

    private func reviewSheet(_ item: Review) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("Review Normalized PDF")
                .font(AppTheme.Typography.pageTitle)
            Text(item.sourceURL.lastPathComponent)
                .font(AppTheme.Typography.body)
                .foregroundStyle(.secondary)
            Text("Target: \(formatPoints(item.resolvedSize.widthPoints)) × \(formatPoints(item.resolvedSize.heightPoints)) pt")
            if let dimensions = formatMillimeters(item.resolvedSize) {
                Text("\(dimensions.width) × \(dimensions.height) mm")
                    .foregroundStyle(.secondary)
            }
            Text("\(item.pageCount) source page(s) will be processed in their original order.")

            if item.preflight.requiresConfirmation {
                Label("Detected structures may not survive this rewrite", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppTheme.Colors.warning)
                    .font(AppTheme.Typography.body)
                ForEach(item.preflight.detectedFeatures) { feature in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(feature.title).fontWeight(.semibold)
                        Text(feature.detail).foregroundStyle(.secondary)
                    }
                    .font(AppTheme.Typography.caption)
                }
            } else {
                Text("No listed interactive or structural features were detected by this inspection.")
                    .foregroundStyle(.secondary)
            }

            Text("Normalization rewrites page appearance. Inspection is not exhaustive, and other PDF features may not be preserved.")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Cancel", role: .cancel) { review = nil }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Continue to Queue") { submit(item) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AppTheme.Spacing.xl)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 360)
    }

    private func inspectAndReview() {
        guard let sourceURL, selectedFiles.count == 1 else { return }
        let request: PDFPageNormalizationRequest
        do {
            request = PDFPageNormalizationRequest(target: try makeTarget())
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        let requestID = UUID()
        activeRequestID = requestID
        isInspecting = true
        let suppliedPassword = password.isEmpty ? nil : password

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let size = try PDFPageNormalizationService.resolveTargetSize(
                        sourceURL: sourceURL,
                        target: request.target,
                        password: suppliedPassword
                    )
                    let report = try PDFDocumentInspector.inspect(url: sourceURL, password: suppliedPassword)
                    return (size, report.pageCount, PDFNormalizationPreflight.assess(report))
                }.value

                guard activeRequestID == requestID, self.sourceURL == sourceURL else { return }
                review = Review(
                    sourceURL: sourceURL,
                    request: request,
                    resolvedSize: result.0,
                    pageCount: result.1,
                    preflight: result.2
                )
                isInspecting = false
            } catch {
                guard activeRequestID == requestID else { return }
                errorMessage = error.localizedDescription
                isInspecting = false
            }
        }
    }

    private func submit(_ item: Review) {
        guard sourceURL == item.sourceURL,
              selectedFiles.count == 1 else {
            review = nil
            return
        }
        let suppliedPassword = password.isEmpty ? nil : password
        review = nil
        _ = item.preflight.submit(afterExplicitConfirmation: true) {
            onSubmit(item.request, suppliedPassword)
        }
    }

    private func makeTarget() throws -> PDFPageSizeTarget {
        switch targetMode {
        case .firstPage:
            return .firstPage(orientation: orientation)
        case .specificPage:
            guard let page = Int(specificPageText), page > 0 else {
                throw ConversionError.invalidInput("Enter a valid 1-based source page number.")
            }
            return .specificPage(pageNumber: page, orientation: orientation)
        case .largestPage:
            return .largestPage(orientation: orientation)
        case .standard:
            guard !selectedPaperID.isEmpty else {
                throw ConversionError.invalidInput("Choose a standard paper format.")
            }
            return .standard(paperID: selectedPaperID, orientation: orientation)
        case .custom:
            guard let width = parseMeasurement(customWidth), let height = parseMeasurement(customHeight) else {
                throw ConversionError.invalidInput("Enter valid custom width and height values.")
            }
            return .custom(width: width, height: height, unit: customUnit)
        }
    }

    private func parseMeasurement(_ text: String) -> Double? {
        let formatter = NumberFormatter()
        formatter.locale = .current
        formatter.numberStyle = .decimal
        return formatter.number(from: text)?.doubleValue
    }

    private func formatPoints(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2)))
    }

    private func formatMillimeters(_ size: PDFResolvedPageSize) -> (width: String, height: String)? {
        guard let width = try? PDFMeasurementUnit.millimeters.value(fromPoints: size.widthPoints),
              let height = try? PDFMeasurementUnit.millimeters.value(fromPoints: size.heightPoints) else {
            return nil
        }
        return (
            width.formatted(.number.precision(.fractionLength(2))),
            height.formatted(.number.precision(.fractionLength(2)))
        )
    }
}
