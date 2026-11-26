import SwiftUI
import AppKit

// MARK: - Before / After & Objective Quality Inspector View

struct ImageComparisonView: View {
    let sourceURL: URL?
    let outputFormat: FileFormat
    let config: ImageToolboxConfig
    let snapshot: ImageComparisonSnapshot?
    let isLoading: Bool
    let statusText: String
    let onRefresh: () -> Void
    let onCancel: () -> Void

    @State private var showDifferenceMap: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                if let qr = snapshot?.qualityReport, qr.differenceMapImage != nil {
                    HStack {
                        Picker("Comparison View", selection: $showDifferenceMap) {
                            Text("Before / After Canvas").tag(false)
                            Text("Pixel Difference Map").tag(true)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 320)

                        Spacer()
                        Button { onRefresh() } label: {
                            Label("Recompute", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                if showDifferenceMap, let diffImg = snapshot?.qualityReport?.differenceMapImage {
                    AppCard(title: "Amplified Pixel Difference Heatmap (4× Gain)", icon: "waveform.path.ecg.rectangle") {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                            Image(nsImage: diffImg)
                                .resizable()
                                .scaledToFit()
                                .frame(minHeight: 280, maxHeight: 380)
                                .frame(maxWidth: .infinity)
                                .background(Color.black)
                                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
                            Text("Dark blue/black indicates near-zero delta; yellow/magenta highlights pixel shift or compression residuals.")
                                .font(AppTheme.Typography.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    ImageLivePreviewCanvas(
                        beforeImage: snapshot?.beforeImage,
                        afterImage: snapshot?.afterImage,
                        beforeFormat: snapshot?.beforeFormat ?? (sourceURL?.pathExtension.uppercased() ?? "INPUT"),
                        afterFormat: snapshot?.afterFormat ?? outputFormat.shortExtensionLabel,
                        telemetry: snapshot?.telemetry,
                        isLoading: isLoading,
                        statusText: statusText,
                        minCanvasHeight: 300,
                        showFullRenderButton: true,
                        fullRenderButtonTitle: "Render Full Comparison",
                        emptyTitle: "Full-Resolution Before / After Inspector",
                        emptySubtitle: "Click Render Full Comparison to encode full-resolution \(outputFormat.shortExtensionLabel) bytes in memory and measure PSNR, SSIM, MSE, MAE & visual difference map.",
                        onRenderFull: onRefresh,
                        onCancel: onCancel
                    )
                }

                if let qr = snapshot?.qualityReport {
                    AppCard(title: "Objective Image Quality Metrics (\(qr.comparedWidth)×\(qr.comparedHeight) sRGB)", icon: "chart.bar.xaxis") {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: AppTheme.Spacing.md)], alignment: .leading, spacing: AppTheme.Spacing.sm) {
                                metricBox(
                                    label: "PSNR (Higher = Better)",
                                    value: qr.psnrDB.isInfinite ? "∞ dB (Exact)" : String(format: "%.2f dB", qr.psnrDB)
                                )
                                metricBox(
                                    label: "SSIM (1.0 = Identical)",
                                    value: String(format: "%.4f", qr.ssim)
                                )
                                metricBox(
                                    label: "MSE (Pixel Sq Err)",
                                    value: String(format: "%.2f", qr.mse)
                                )
                                metricBox(
                                    label: "MAE (Mean Abs Err)",
                                    value: String(format: "%.2f / 255", qr.mae)
                                )
                                metricBox(
                                    label: "Max Channel Delta",
                                    value: "\(qr.maxChannelDelta) / 255"
                                )
                            }

                            if qr.hadDimensionMismatch || qr.hadColorSpaceNormalization {
                                AppInfoBanner(
                                    style: .info,
                                    message: [
                                        qr.hadDimensionMismatch ? "Resolution differed; reference was bilinear-normalized to output dimensions for comparison." : nil,
                                        qr.hadColorSpaceNormalization ? "Color profiles were normalized to sRGB prior to metric calculation." : nil
                                    ].compactMap { $0 }.joined(separator: " ")
                                )
                            }

                            Text(qr.butteraugliNote)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let note = snapshot?.telemetry.note, !note.isEmpty {
                    AppInfoBanner(style: .info, message: note)
                }
            }
            .padding(AppTheme.Spacing.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func metricBox(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(AppTheme.Typography.caption).foregroundStyle(.secondary)
            Text(value).font(AppTheme.Typography.subheadline.weight(.semibold).monospacedDigit())
        }
    }
}
