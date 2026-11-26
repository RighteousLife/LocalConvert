import SwiftUI

struct PDFCompressOptionsView: View {
    let selectedFiles: [DroppedFile]
    @Binding var options: PDFCompressionOptions

    private var totalOriginalBytes: Int64 {
        selectedFiles.reduce(0) { sum, f in
            sum + f.fileSize
        }
    }

    @ViewBuilder
    private var compressionParameterControls: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            Text("Image Codec")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(.secondary)
            Picker("Image Codec", selection: $options.imageCodec) {
                ForEach(PDFImageCompressionCodec.allCases) { codec in
                    Text(codec.rawValue).tag(codec)
                }
            }
            .labelsHidden()
            .frame(minWidth: 160, maxWidth: 190)
            .accessibilityLabel("Image Codec")
            .onChange(of: options.imageCodec) { _, _ in options.profile = .custom }
        }

        let dpiAndQualityDisabled = (options.imageCodec == .losslessFlate || options.strategy == .losslessCleanup || options.strategy == .structurePreserving)

        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            Text("Target Resolution: \(Int(options.targetDPI)) DPI")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(.secondary)
            Slider(value: $options.targetDPI, in: 72...300, step: 12)
                .frame(minWidth: 120, maxWidth: 160)
                .disabled(dpiAndQualityDisabled)
                .accessibilityLabel("Target image resolution")
                .accessibilityValue("\(Int(options.targetDPI)) DPI")
                .onChange(of: options.targetDPI) { _, _ in options.profile = .custom }
        }

        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            Text("Quality: \(Int(options.imageQuality * 100))%")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(.secondary)
            Slider(value: $options.imageQuality, in: 0.25...0.98, step: 0.05)
                .frame(minWidth: 110, maxWidth: 140)
                .disabled(dpiAndQualityDisabled)
                .accessibilityLabel("Image compression quality")
                .accessibilityValue("\(Int(options.imageQuality * 100)) percent")
                .onChange(of: options.imageQuality) { _, _ in options.profile = .custom }
        }
    }

    private var estimatedRangeText: String {
        guard let range = PDFCompressionService.estimateSizeRange(originalBytes: totalOriginalBytes, options: options) else {
            return "—"
        }
        let low = ByteCountFormatter.string(fromByteCount: range.lowerBound, countStyle: .file)
        let high = ByteCountFormatter.string(fromByteCount: range.upperBound, countStyle: .file)
        return "\(low) – \(high)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            AppCard(title: "Compression Profile", icon: "arrow.down.right.and.arrow.up.left") {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    Picker("Preset", selection: $options.profile) {
                        ForEach(PDFCompressionProfile.allCases) { profile in
                            Text(profile.rawValue).tag(profile)
                        }
                    }
                    .onChange(of: options.profile) { _, newProfile in
                        if newProfile != .custom {
                            options = PDFCompressionOptions.forProfile(newProfile)
                        }
                    }

                    Text(options.profile.summary)
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)

                    if options.profile == .custom || options.profile.isLossy {
                        Divider()
                        Picker("Compression Strategy", selection: $options.strategy) {
                            ForEach(PDFCompressionStrategy.allCases) { strat in
                                Text(strat.rawValue).tag(strat)
                            }
                        }
                        .onChange(of: options.strategy) { _, _ in options.profile = .custom }

                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: AppTheme.Spacing.lg) {
                                compressionParameterControls
                            }
                            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                                compressionParameterControls
                            }
                        }

                        Toggle("Strip document metadata & embedded XMP streams", isOn: $options.stripMetadata)
                            .onChange(of: options.stripMetadata) { _, _ in options.profile = .custom }

                        if options.strategy == .rasterizePages {
                            Toggle("Convert rasterized pages to Grayscale", isOn: $options.grayscale)
                                .onChange(of: options.grayscale) { _, _ in options.profile = .custom }
                        }
                    }
                }
            }

            AppCard(padding: AppTheme.Spacing.sm) {
                HStack(spacing: AppTheme.Spacing.xl) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Original Size")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                        Text(ByteCountFormatter.string(fromByteCount: totalOriginalBytes, countStyle: .file))
                            .font(AppTheme.Typography.subheadline)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Estimated Output Range")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                        Text(estimatedRangeText)
                            .font(AppTheme.Typography.subheadline)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }

                    Spacer()
                }
            }

            if options.imageCodec == .losslessFlate || options.profile == .maximumQuality || options.strategy == .losslessCleanup {
                AppInfoBanner(
                    style: .info,
                    message: "Lossless Structure Cleanup rewrites PDF streams without lossy image re-encoding, keeping vector text, links, outlines, and forms intact."
                )
            } else if options.strategy == .quartzOptimized {
                AppInfoBanner(
                    style: .info,
                    message: "Quartz Vector-Preserving mode downsamples embedded images to \(Int(options.targetDPI)) DPI (\(Int(options.imageQuality * 100))% JPEG) while keeping selectable vector text, links, annotations, and outlines. Interactive AcroForm fields are flattened; fonts are kept without glyph subsetting."
                )
            } else if options.strategy == .structurePreserving || options.profile == .webOptimized {
                AppInfoBanner(
                    style: .info,
                    message: "Structure-Preserving mode optimizes embedded screen images while keeping vector text, links, outlines, and forms intact. Note: byte-range /Linearized Fast Web View hint tables are not written by macOS PDFKit."
                )
            } else {
                AppInfoBanner(
                    style: .warning,
                    message: "Rasterize Pages mode re-renders each page at \(Int(options.targetDPI)) DPI (\(options.grayscale ? "Grayscale, " : "")\(options.imageCodec.rawValue)), flattening vector text, links, outlines, annotations, and forms into pixels."
                )
            }
        }
    }
}
