import SwiftUI
import AppKit

struct PDFCompareView: View {
    let availablePDFs: [DroppedFile]
    @Binding var password: String

    @State private var leftFileID: UUID? = nil
    @State private var rightFileID: UUID? = nil
    @State private var isComparing: Bool = false
    @State private var report: PDFComparisonReport? = nil
    @State private var errorMessage: String? = nil
    @State private var selectedPageNumber: Int = 1
    @State private var showVisualDiffOverlay: Bool = true

    private var selectedDiff: PDFPageComparisonDiff? {
        report?.pageDiffs.first(where: { $0.pageNumber == selectedPageNumber }) ?? report?.pageDiffs.first
    }

    @ViewBuilder
    private var pdfComparePickers: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            Text("Baseline (Original) PDF")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(.secondary)
            Picker("Original", selection: $leftFileID) {
                Text("Select PDF...").tag(Optional<UUID>.none)
                ForEach(availablePDFs) { file in
                    Text(file.fileName).tag(Optional(file.id))
                }
            }
        }

        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            Text("Revised PDF")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(.secondary)
            Picker("Revised", selection: $rightFileID) {
                Text("Select PDF...").tag(Optional<UUID>.none)
                ForEach(availablePDFs) { file in
                    Text(file.fileName).tag(Optional(file.id))
                }
            }
        }
    }

    @ViewBuilder
    private var pdfCompareButton: some View {
        Button {
            runComparison()
        } label: {
            Label(isComparing ? "Comparing..." : "Run Comparison", systemImage: "arrow.left.arrow.right")
        }
        .buttonStyle(.borderedProminent)
        .fixedSize()
        .disabled(leftFileID == nil || rightFileID == nil || isComparing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            AppCard(title: "Compare Two PDF Documents", icon: "doc.on.doc.fill") {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: AppTheme.Spacing.md) {
                        pdfComparePickers
                        Spacer()
                        pdfCompareButton
                    }
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                        HStack(spacing: AppTheme.Spacing.md) {
                            pdfComparePickers
                        }
                        HStack {
                            Spacer()
                            pdfCompareButton
                        }
                    }
                }
            }

            if let errorMessage {
                AppInfoBanner(style: .error, message: errorMessage)
            }

            if let report {
                // Summary Banner
                AppCard(padding: AppTheme.Spacing.sm) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: AppTheme.Spacing.lg) {
                            compareSummaryLabel(report)
                            Spacer()
                            Toggle("Visual Pixel Diff Overlay", isOn: $showVisualDiffOverlay)
                                .toggleStyle(.switch)
                        }
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                            compareSummaryLabel(report)
                            Toggle("Visual Pixel Diff Overlay", isOn: $showVisualDiffOverlay)
                                .toggleStyle(.switch)
                        }
                    }
                }

                // Page Slot Selector
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AppTheme.Spacing.xs) {
                        ForEach(report.pageDiffs) { pd in
                            Button {
                                selectedPageNumber = pd.pageNumber
                            } label: {
                                VStack(spacing: 2) {
                                    Text("Slot \(pd.pageNumber)")
                                        .font(AppTheme.Typography.caption)
                                        .fontWeight(.semibold)
                                    Text(pd.status.rawValue)
                                        .font(.caption2)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, AppTheme.Spacing.sm)
                                .padding(.vertical, AppTheme.Spacing.xs)
                                .background(selectedPageNumber == pd.pageNumber ? AppTheme.Colors.accent.opacity(0.18) : statusColor(pd.status).opacity(0.1))
                                .foregroundStyle(selectedPageNumber == pd.pageNumber ? AppTheme.Colors.accent : statusColor(pd.status))
                                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Side-by-Side Visual + Text Diff Details
                if let diff = selectedDiff {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                            compareVisualPanes(diff)
                            compareTextDiffCard(diff)
                        }

                        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                            compareVisualPanes(diff)
                            compareTextDiffCard(diff)
                        }
                    }
                }
            }
        }
        .onAppear {
            autoSelectDefaults()
        }
        .onChange(of: availablePDFs.map { $0.id }) { _, _ in
            autoSelectDefaults()
        }
    }

    @ViewBuilder
    private func compareSummaryLabel(_ report: PDFComparisonReport) -> some View {
        Label(
            report.summaryText,
            systemImage: report.modifiedPagesCount + report.addedPagesCount + report.removedPagesCount == 0
                ? "checkmark.circle.fill"
                : "exclamationmark.triangle.fill"
        )
        .font(AppTheme.Typography.subheadline)
        .foregroundStyle(
            report.modifiedPagesCount + report.addedPagesCount + report.removedPagesCount == 0
                ? AppTheme.Colors.success
                : AppTheme.Colors.warning
        )
    }

    @ViewBuilder
    private func compareVisualPanes(_ diff: PDFPageComparisonDiff) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(spacing: AppTheme.Spacing.sm) {
                visualCard(title: "Original", pngData: diff.leftThumbnailData, dims: diff.leftDimensions, rot: diff.leftRotation)
                if showVisualDiffOverlay, let overlay = diff.visualDiffImageData {
                    visualCard(title: diff.visualDifferenceRatio.map { String(format: "Visual Diff (%.2f%%)", $0 * 100.0) } ?? "Visual Diff", pngData: overlay, dims: nil, rot: nil)
                } else {
                    visualCard(title: "Revised", pngData: diff.rightThumbnailData, dims: diff.rightDimensions, rot: diff.rightRotation)
                }
            }
            if showVisualDiffOverlay {
                visualCard(title: "Revised Page", pngData: diff.rightThumbnailData, dims: diff.rightDimensions, rot: diff.rightRotation)
            }
        }
    }

    @ViewBuilder
    private func compareTextDiffCard(_ diff: PDFPageComparisonDiff) -> some View {
        AppCard(title: "Text & Structural Differences (Page Slot \(diff.pageNumber))", icon: "text.alignleft") {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    if diff.addedLines.isEmpty && diff.removedLines.isEmpty && diff.annotationChanges.isEmpty && diff.formFieldChanges.isEmpty && diff.leftImageCount == diff.rightImageCount {
                        Text("No extracted text, annotation, or form field differences on this page.")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(diff.removedLines, id: \.self) { line in
                            Text("− \(line)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(AppTheme.Colors.error)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(diff.addedLines, id: \.self) { line in
                            Text("+ \(line)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(AppTheme.Colors.success)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if !diff.annotationChanges.isEmpty {
                            Divider()
                            Text("Annotation Changes")
                                .font(.caption2)
                                .fontWeight(.semibold)
                            ForEach(diff.annotationChanges, id: \.self) { item in
                                Text(item)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(AppTheme.Colors.warning)
                            }
                        }
                        if !diff.formFieldChanges.isEmpty {
                            Divider()
                            Text("Form Field Changes")
                                .font(.caption2)
                                .fontWeight(.semibold)
                            ForEach(diff.formFieldChanges, id: \.self) { item in
                                Text(item)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.blue)
                            }
                        }
                        if diff.leftImageCount != diff.rightImageCount {
                            Text("Embedded Image XObjects: \(diff.leftImageCount) → \(diff.rightImageCount)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(minHeight: 180, maxHeight: 280)
        }
    }

    @ViewBuilder
    private func visualCard(title: String, pngData: Data?, dims: CGSize?, rot: Int?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
                Spacer()
                if let dims {
                    Text("\(Int(dims.width))×\(Int(dims.height))pt\(rot.map { $0 != 0 ? " \($0)°" : "" } ?? "")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let pngData, let img = NSImage(data: pngData) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
            } else {
                Text("(No Page)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 140, height: 140)
                    .background(Color.secondary.opacity(0.06))
            }
        }
    }

    private func statusColor(_ status: PDFPageComparisonDiff.PageDiffStatus) -> Color {
        switch status {
        case .identical: return .green
        case .added: return .blue
        case .removed: return .red
        default: return .orange
        }
    }

    private func autoSelectDefaults() {
        if leftFileID == nil, let first = availablePDFs.first {
            leftFileID = first.id
        }
        if rightFileID == nil, availablePDFs.count >= 2 {
            rightFileID = availablePDFs[1].id
        }
    }

    private func runComparison() {
        guard let l = availablePDFs.first(where: { $0.id == leftFileID }),
              let r = availablePDFs.first(where: { $0.id == rightFileID }) else { return }
        isComparing = true
        errorMessage = nil
        let pwd = password.isEmpty ? nil : password
        Task {
            do {
                let res = try await PDFComparisonService.compare(
                    leftURL: l.url,
                    rightURL: r.url,
                    leftPassword: pwd,
                    rightPassword: pwd
                )
                await MainActor.run {
                    report = res
                    selectedPageNumber = res.pageDiffs.first?.pageNumber ?? 1
                    isComparing = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isComparing = false
                }
            }
        }
    }
}
