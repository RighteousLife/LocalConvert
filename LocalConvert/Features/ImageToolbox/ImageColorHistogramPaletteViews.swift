import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Histogram & Dominant Color Palette Views

struct ImageHistogramAnalysisCardView: View {
    let previewImage: NSImage?
    let colorInfo: ImageColorProfileInfo?

    @State private var histogram: ImageHistogramData?
    @State private var showLuminance: Bool = true
    @State private var showRed: Bool = true
    @State private var showGreen: Bool = true
    @State private var showBlue: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            AppCard(title: "Real Pixel Histogram & Clipping Analysis", icon: "waveform.path.ecg") {
                if let hist = histogram {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                        HStack(spacing: AppTheme.Spacing.sm) {
                            channelToggle("Luma", isOn: $showLuminance, tint: .primary)
                            channelToggle("R", isOn: $showRed, tint: .red)
                            channelToggle("G", isOn: $showGreen, tint: .green)
                            channelToggle("B", isOn: $showBlue, tint: .blue)
                            Spacer()
                            Button("Recompute") { computeHistogram() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }

                        histogramCanvas(hist)
                            .frame(height: 150)
                            .background(Color.black.opacity(0.84))
                            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
                            .overlay(
                                RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                            )

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 125), spacing: AppTheme.Spacing.md)], alignment: .leading, spacing: AppTheme.Spacing.sm) {
                            metric("Min Luma", "\(hist.minLuminance) / 255")
                            metric("Max Luma", "\(hist.maxLuminance) / 255")
                            metric("Mean Luma", String(format: "%.1f", hist.meanLuminance))
                            metric("Shadow Clip (≤2)", String(format: "%.2f%%", hist.shadowClippingPercent))
                            metric("Highlight Clip (≥253)", String(format: "%.2f%%", hist.highlightClippingPercent))
                            metric("Profile / Depth", "\(hist.bitDepth)bpc")
                        }
                    }
                } else {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Computing pixel luminance and RGB histograms...")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear { computeHistogram() }
        .onChange(of: previewImage) { _, _ in computeHistogram() }
    }

    private func channelToggle(_ title: String, isOn: Binding<Bool>, tint: Color) -> some View {
        Toggle(title, isOn: isOn)
            .toggleStyle(.button)
            .controlSize(.small)
            .tint(tint)
    }

    private func histogramCanvas(_ hist: ImageHistogramData) -> some View {
        Canvas { ctx, size in
            let maxCount: Double = {
                var peak = 1
                if showLuminance { peak = max(peak, hist.luminanceBins.max() ?? 1) }
                if showRed { peak = max(peak, hist.redBins.max() ?? 1) }
                if showGreen { peak = max(peak, hist.greenBins.max() ?? 1) }
                if showBlue { peak = max(peak, hist.blueBins.max() ?? 1) }
                return Double(peak)
            }()

            func drawBins(_ bins: [Int], color: Color, lineWidth: CGFloat) {
                guard bins.count == 256 else { return }
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height))
                for i in 0..<256 {
                    let x = (CGFloat(i) / 255.0) * size.width
                    let y = size.height - (CGFloat(Double(bins[i]) / maxCount) * (size.height - 6))
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.closeSubpath()
                ctx.fill(path, with: .color(color.opacity(0.22)))
                ctx.stroke(path, with: .color(color.opacity(0.85)), lineWidth: lineWidth)
            }

            if showRed { drawBins(hist.redBins, color: .red, lineWidth: 1.2) }
            if showGreen { drawBins(hist.greenBins, color: .green, lineWidth: 1.2) }
            if showBlue { drawBins(hist.blueBins, color: .blue, lineWidth: 1.2) }
            if showLuminance { drawBins(hist.luminanceBins, color: .white, lineWidth: 1.5) }
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(AppTheme.Typography.caption).foregroundStyle(.secondary)
            Text(value).font(AppTheme.Typography.subheadline.weight(.semibold).monospacedDigit())
        }
    }

    private func computeHistogram() {
        guard let nsImg = previewImage,
              let cg = nsImg.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            histogram = nil
            return
        }
        let info = colorInfo
        Task.detached(priority: .userInitiated) {
            let data = ImageColorAnalysisService.computeHistogram(cgImage: cg, colorInfo: info)
            await MainActor.run { self.histogram = data }
        }
    }
}

struct ImageColorPaletteExtractorCardView: View {
    let previewImage: NSImage?

    @State private var swatchCount: Int = 5
    @State private var result: ImagePaletteExtractionResult?
    @State private var copyFeedback: String? = nil

    private let countChoices = [3, 5, 8, 12, 16]

    var body: some View {
        AppCard(title: "Dominant Color Palette Extractor", icon: "swatchpalette") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        countPicker
                        Spacer()
                        exportButtons
                    }
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                        countPicker
                        exportButtons
                    }
                }

                if let result, !result.swatches.isEmpty {
                    // Proportional Coverage Strip
                    GeometryReader { geo in
                        HStack(spacing: 1) {
                            ForEach(result.swatches) { sw in
                                let w = max(4, (CGFloat(sw.coveragePercent) / 100.0) * geo.size.width)
                                Rectangle()
                                    .fill(Color(red: Double(sw.red) / 255.0, green: Double(sw.green) / 255.0, blue: Double(sw.blue) / 255.0))
                                    .frame(width: w)
                            }
                        }
                    }
                    .frame(height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))

                    // Detailed Swatches List
                    VStack(spacing: AppTheme.Spacing.xs) {
                        ForEach(result.swatches) { sw in
                            HStack(spacing: AppTheme.Spacing.sm) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color(red: Double(sw.red) / 255.0, green: Double(sw.green) / 255.0, blue: Double(sw.blue) / 255.0))
                                    .frame(width: 24, height: 24)
                                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))

                                Text(sw.hex)
                                    .font(AppTheme.Typography.monoCaption.weight(.semibold))
                                    .frame(width: 66, alignment: .leading)

                                ViewThatFits(in: .horizontal) {
                                    HStack(spacing: AppTheme.Spacing.sm) {
                                        Text(sw.rgbString)
                                            .font(AppTheme.Typography.monoCaption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)

                                        Text(sw.hsl)
                                            .font(AppTheme.Typography.monoCaption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }

                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(sw.rgbString)
                                            .font(AppTheme.Typography.monoCaption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)

                                        Text(sw.hsl)
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                }

                                Spacer(minLength: 4)

                                Text(String(format: "%.1f%%", sw.coveragePercent))
                                    .font(AppTheme.Typography.monoCaption)
                                    .foregroundStyle(.secondary)

                                Button("Copy HEX") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(sw.hex, forType: .string)
                                    copyFeedback = "Copied \(sw.hex)"
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .padding(.vertical, 3)
                        }
                    }

                    if let copyFeedback {
                        Text(copyFeedback)
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(AppTheme.Colors.accent)
                    }
                } else {
                    Text("Select an image to extract dominant swatches.")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { extract() }
        .onChange(of: previewImage) { _, _ in extract() }
        .onChange(of: swatchCount) { _, _ in extract() }
    }

    private var countPicker: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Text("Colors:").font(AppTheme.Typography.caption).foregroundStyle(.secondary)
            ForEach(countChoices, id: \.self) { count in
                Button("\(count)") {
                    swatchCount = count
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .tint(swatchCount == count ? AppTheme.Colors.accent : .secondary)
            }
        }
    }

    private var exportButtons: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Button("Export PNG") { exportPalettePNG() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(result?.swatches.isEmpty ?? true)
            Button("Export JSON") { exportTextFile(content: ImageColorAnalysisService.exportJSON(swatches: result?.swatches ?? []), ext: "json", defaultName: "palette.json") }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(result?.swatches.isEmpty ?? true)
            Button("Export CSS") { exportTextFile(content: ImageColorAnalysisService.exportCSS(swatches: result?.swatches ?? []), ext: "css", defaultName: "palette.css") }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(result?.swatches.isEmpty ?? true)
        }
    }

    private func extract() {
        guard let nsImg = previewImage,
              let cg = nsImg.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            result = nil
            return
        }
        let targetK = swatchCount
        Task.detached(priority: .userInitiated) {
            let res = ImageColorAnalysisService.extractPalette(cgImage: cg, colorCount: targetK)
            await MainActor.run { self.result = res }
        }
    }

    private func exportPalettePNG() {
        guard let swatches = result?.swatches, !swatches.isEmpty,
              let data = try? ImageColorAnalysisService.renderPalettePNG(swatches: swatches) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "palette.png"
        panel.allowedContentTypes = [.png]
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url, options: .atomic)
            copyFeedback = "Saved \(url.lastPathComponent)"
        }
    }

    private func exportTextFile(content: String, ext: String, defaultName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        if let ut = UTType(filenameExtension: ext) {
            panel.allowedContentTypes = [ut]
        }
        if panel.runModal() == .OK, let url = panel.url {
            try? content.data(using: .utf8)?.write(to: url, options: .atomic)
            copyFeedback = "Saved \(url.lastPathComponent)"
        }
    }
}
