import Foundation
import Testing
import AppKit
@testable import LocalConvert

@Suite("Phase 26.1 — UX Refinement & Compatibility Tests")
struct Phase26_1Tests {
    
    // MARK: - Helpers
    
    private func mockDetectionResult(url: URL, format: FileFormat) -> FileDetectionResult {
        FileDetectionResult(
            url: url,
            detectedFormat: format,
            extensionFormat: format,
            utTypeFormat: format,
            magicBytesFormat: format,
            confidence: .high
        )
    }
    
    // MARK: - 1. Quick Convert Intersection Capability
    
    @Test("Quick Convert computes exact format intersection for multiple images")
    @MainActor
    func testQuickConvertIntersectionImages() {
        let appState = AppState()
        
        let pngURL = URL(fileURLWithPath: "/tmp/sample1.png")
        let jpgURL = URL(fileURLWithPath: "/tmp/sample2.jpg")
        
        let file1 = DroppedFile(
            url: pngURL,
            detectionResult: mockDetectionResult(url: pngURL, format: .png),
            options: .default
        )
        let file2 = DroppedFile(
            url: jpgURL,
            detectionResult: mockDetectionResult(url: jpgURL, format: .jpg),
            options: .default
        )
        
        appState.droppedFiles = [file1, file2]
        
        let quickFormats = appState.quickConvertFormats
        #expect(!quickFormats.isEmpty)
        // Both PNG and JPG can convert to WebP, PDF, PNG, etc.
        #expect(quickFormats.contains(.webp))
        #expect(quickFormats.contains(.pdf))
        
        // Ensure every format in quickFormats is supported by BOTH files
        for fmt in quickFormats {
            #expect(file1.availableOutputFormats.contains(fmt))
            #expect(file2.availableOutputFormats.contains(fmt))
        }
    }
    
    @Test("Quick Convert excludes formats not supported by all files in queue")
    @MainActor
    func testQuickConvertExcludesNonUniversalFormats() {
        let appState = AppState()
        
        let pngURL = URL(fileURLWithPath: "/tmp/sample1.png")
        let docxURL = URL(fileURLWithPath: "/tmp/sample2.docx")
        
        let file1 = DroppedFile(
            url: pngURL,
            detectionResult: mockDetectionResult(url: pngURL, format: .png),
            options: .default
        )
        let file2 = DroppedFile(
            url: docxURL,
            detectionResult: mockDetectionResult(url: docxURL, format: .docx),
            options: .default
        )
        
        appState.droppedFiles = [file1, file2]
        
        let quickFormats = appState.quickConvertFormats
        
        // DOCX cannot convert to WebP, so WebP must NOT be in quickFormats
        #expect(!quickFormats.contains(.webp))
        
        // Both PNG and DOCX can convert to PDF, so PDF should be present
        #expect(quickFormats.contains(.pdf))
        
        for fmt in quickFormats {
            #expect(file1.availableOutputFormats.contains(fmt))
            #expect(file2.availableOutputFormats.contains(fmt))
        }
    }
    
    // MARK: - 2. Quick Presets Universal Compatibility
    
    @Test("Quick Presets only includes presets applicable to all loaded files")
    @MainActor
    func testQuickPresetsFiltering() {
        let appState = AppState()
        
        let pngURL = URL(fileURLWithPath: "/tmp/sample.png")
        let file1 = DroppedFile(
            url: pngURL,
            detectionResult: mockDetectionResult(url: pngURL, format: .png),
            options: .default
        )
        
        appState.droppedFiles = [file1]
        
        let presets = appState.quickPresets
        #expect(!presets.isEmpty)
        for preset in presets {
            #expect(file1.availableOutputFormats.contains(preset.targetFormat))
        }
        
        // Add an incompatible file like an MP4 video
        let mp4URL = URL(fileURLWithPath: "/tmp/video.mp4")
        let file2 = DroppedFile(
            url: mp4URL,
            detectionResult: mockDetectionResult(url: mp4URL, format: .mp4),
            options: .default
        )
        
        appState.droppedFiles = [file1, file2]
        let mixedPresets = appState.quickPresets
        // Only presets supported by both image and video should remain (or empty if none)
        for preset in mixedPresets {
            #expect(file1.availableOutputFormats.contains(preset.targetFormat))
            #expect(file2.availableOutputFormats.contains(preset.targetFormat))
        }
    }
    
    // MARK: - 3. Repeat Conversion Compatibility
    
    @Test("Repeat conversion is compatible when current files support the last output format")
    @MainActor
    func testRepeatConversionCompatible() {
        let appState = AppState()
        
        appState.lastConversionConfig = LastConversionConfig(
            inputFormat: .png,
            outputFormat: .webp,
            options: .default,
            timestamp: Date()
        )
        
        let jpgURL = URL(fileURLWithPath: "/tmp/photo.jpg")
        let file = DroppedFile(
            url: jpgURL,
            detectionResult: mockDetectionResult(url: jpgURL, format: .jpg),
            options: .default
        )
        
        appState.droppedFiles = [file]
        
        #expect(appState.isRepeatConversionCompatible == true)
    }
    
    @Test("Repeat conversion is incompatible and shows clear error when format cannot be converted")
    @MainActor
    func testRepeatConversionIncompatible() {
        let appState = AppState()
        
        // Last conversion was PNG -> WebP
        appState.lastConversionConfig = LastConversionConfig(
            inputFormat: .png,
            outputFormat: .webp,
            options: .default,
            timestamp: Date()
        )
        
        // Loaded file is PDF (which cannot be converted to WebP by standard engines)
        let pdfURL = URL(fileURLWithPath: "/tmp/document.pdf")
        let file = DroppedFile(
            url: pdfURL,
            detectionResult: mockDetectionResult(url: pdfURL, format: .pdf),
            options: .default
        )
        
        appState.droppedFiles = [file]
        
        #expect(appState.isRepeatConversionCompatible == false)
        
        appState.repeatLastConversion()
        
        #expect(appState.showError == true)
        #expect(appState.errorMessage == "Your last conversion isn't compatible with the selected files.")
    }
    
    // MARK: - 4. Compact Size Comparison Formatting
    
    @Test("ConversionSizeComparison formats summary accurately for reductions and expansions")
    func testSizeComparisonCompactFormatting() {
        let reduction = ConversionSizeComparison(inputBytes: 4_800_000, outputBytes: 1_200_000)
        #expect(reduction.formattedSummary == "75% smaller")
        #expect(reduction.isSmaller == true)
        #expect(reduction.isLarger == false)
        
        let expansion = ConversionSizeComparison(inputBytes: 1_000_000, outputBytes: 3_400_000)
        #expect(expansion.formattedSummary == "240% larger")
        #expect(expansion.isSmaller == false)
        #expect(expansion.isLarger == true)
        
        let same = ConversionSizeComparison(inputBytes: 500_000, outputBytes: 500_000)
        #expect(same.formattedSummary == "Same size")
        #expect(same.isSmaller == false)
        #expect(same.isLarger == false)
    }
}
