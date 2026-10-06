import Foundation
import Testing
@testable import LocalConvert

@Suite("Phase 16 Conversion Capability & Smart Workflows Tests")
struct Phase16Tests {
    
    let registry = ConversionRegistry.shared
    
    // MARK: - 1. Single Source of Truth & Registry Consistency
    
    @Test("Registry Single Source of Truth Consistency")
    func testRegistryConsistency() {
        let allInputs = registry.supportedInputFormats
        #expect(!allInputs.isEmpty)
        
        for input in allInputs {
            let supportedOutputs = registry.supportedOutputFormats(for: input)
            // Same format should never be in supported outputs
            #expect(!supportedOutputs.contains(input))
            
            for output in supportedOutputs {
                #expect(registry.canConvert(from: input, to: output))
                let engine = registry.findEngine(from: input, to: output)
                #expect(engine != nil)
            }
        }
    }
    
    // MARK: - 2. Positive Capability Verification
    
    @Test("Positive Capabilities: Image Routes")
    func testImageCapabilities() {
        #expect(registry.canConvert(from: .jpg, to: .png))
        #expect(registry.canConvert(from: .png, to: .jpg))
        #expect(registry.canConvert(from: .heic, to: .jpg))
        #expect(registry.canConvert(from: .heic, to: .png))
        #expect(registry.canConvert(from: .heic, to: .webp))
        #expect(registry.canConvert(from: .heic, to: .pdf))
        #expect(registry.canConvert(from: .png, to: .webp))
        #expect(registry.canConvert(from: .png, to: .pdf))
        #expect(registry.canConvert(from: .svg, to: .png))
        #expect(registry.canConvert(from: .svg, to: .pdf))
        #expect(registry.canConvert(from: .avif, to: .png))
        #expect(registry.canConvert(from: .png, to: .avif))
    }
    
    @Test("Positive Capabilities: Office & Document Routes")
    func testOfficeCapabilities() {
        #expect(registry.canConvert(from: .docx, to: .pdf))
        #expect(registry.canConvert(from: .xlsx, to: .pdf))
        #expect(registry.canConvert(from: .pptx, to: .pdf))
        #expect(registry.canConvert(from: .odt, to: .pdf))
        #expect(registry.canConvert(from: .ods, to: .pdf))
        #expect(registry.canConvert(from: .odp, to: .pdf))
        #expect(registry.canConvert(from: .rtf, to: .pdf))
        #expect(registry.canConvert(from: .pdf, to: .docx))
        #expect(registry.canConvert(from: .pdf, to: .xlsx))
        #expect(registry.canConvert(from: .pdf, to: .pptx))
        #expect(registry.canConvert(from: .csv, to: .tsv))
        #expect(registry.canConvert(from: .tsv, to: .csv))
        #expect(registry.canConvert(from: .csv, to: .xlsx))
        #expect(registry.canConvert(from: .xlsx, to: .csv))
    }
    
    @Test("Positive Capabilities: Media Routes (Audio, Video & Audio Extraction)")
    func testMediaCapabilities() {
        // Audio -> Audio
        #expect(registry.canConvert(from: .wav, to: .mp3))
        #expect(registry.canConvert(from: .mp3, to: .flac))
        #expect(registry.canConvert(from: .flac, to: .m4a))
        #expect(registry.canConvert(from: .m4a, to: .wav))
        
        // Video -> Video
        #expect(registry.canConvert(from: .mp4, to: .mov))
        #expect(registry.canConvert(from: .mov, to: .mp4))
        #expect(registry.canConvert(from: .mkv, to: .mp4))
        #expect(registry.canConvert(from: .webm, to: .mp4))
        
        // Video -> Audio (Extraction)
        #expect(registry.canConvert(from: .mp4, to: .mp3))
        #expect(registry.canConvert(from: .mov, to: .m4a))
        #expect(registry.canConvert(from: .mkv, to: .aac))
        
        // GIF <-> Video
        #expect(registry.canConvert(from: .mp4, to: .gif))
        #expect(registry.canConvert(from: .gif, to: .mp4))
    }
    
    @Test("Positive Capabilities: PDF Format Conversions (PDF -> Images)")
    func testPDFImageCapabilities() {
        #expect(registry.canConvert(from: .pdf, to: .png))
        #expect(registry.canConvert(from: .pdf, to: .jpg))
        #expect(registry.canConvert(from: .pdf, to: .tiff))
    }
    
    // MARK: - 3. Negative Capability Verification
    
    @Test("Negative Capabilities: Unsupported Cross-Category Routes")
    func testNegativeCapabilities() {
        #expect(!registry.canConvert(from: .png, to: .mp3))
        #expect(!registry.canConvert(from: .mp4, to: .docx))
        #expect(!registry.canConvert(from: .docx, to: .mp3))
        #expect(!registry.canConvert(from: .pdf, to: .svg))
        #expect(!registry.canConvert(from: .csv, to: .mp4))
        #expect(!registry.canConvert(from: .mp3, to: .png))
        #expect(!registry.canConvert(from: .wav, to: .docx))
        #expect(!registry.canConvert(from: .docx, to: .jpg))
        #expect(!registry.canConvert(from: .xlsx, to: .mp4))
    }
    
    // MARK: - 4. Smart Recommendations Strictly Derived from Registry
    
    @Test("Smart Recommendations: Valid Targets Only")
    func testSmartRecommendations() {
        // HEIC recommendations
        let heicRecs = registry.recommendedOutputFormats(for: .heic)
        let heicSupported = registry.supportedOutputFormats(for: .heic)
        #expect(!heicRecs.isEmpty)
        for target in heicRecs {
            #expect(heicSupported.contains(target))
        }
        #expect(heicRecs.contains(.jpg))
        #expect(heicRecs.contains(.png))
        #expect(heicRecs.contains(.webp))
        #expect(heicRecs.contains(.pdf))
        #expect(!heicRecs.contains(.mp3))
        #expect(!heicRecs.contains(.docx))
        
        // DOCX recommendations
        let docxRecs = registry.recommendedOutputFormats(for: .docx)
        #expect(docxRecs.contains(.pdf))
        #expect(!docxRecs.contains(.mp3))
        #expect(!docxRecs.contains(.jpg))
        
        // MP4 recommendations
        let mp4Recs = registry.recommendedOutputFormats(for: .mp4)
        #expect(mp4Recs.contains(.mp3))
        #expect(mp4Recs.contains(.mov))
        #expect(!mp4Recs.contains(.docx))
        #expect(!mp4Recs.contains(.pdf))
        
        // PDF recommendations
        let pdfRecs = registry.recommendedOutputFormats(for: .pdf)
        #expect(pdfRecs.contains(.docx))
        #expect(pdfRecs.contains(.xlsx))
        #expect(pdfRecs.contains(.pptx))
        #expect(pdfRecs.contains(.png))
        #expect(pdfRecs.contains(.jpg))
        #expect(!pdfRecs.contains(.mp3))
        #expect(!pdfRecs.contains(.pdf))
    }
    
    // MARK: - 5. Preset Capability Validation
    
    @Test("Preset Capability Validation")
    func testPresetCapabilityValidation() {
        // Audio Only preset
        #expect(registry.isPresetSupported(.audioOnly, for: .mp4))
        #expect(registry.isPresetSupported(.audioOnly, for: .mov))
        #expect(!registry.isPresetSupported(.audioOnly, for: .docx))
        #expect(!registry.isPresetSupported(.audioOnly, for: .jpg))
        
        // Document PDF preset
        #expect(registry.isPresetSupported(.documentPDF, for: .docx))
        #expect(registry.isPresetSupported(.documentPDF, for: .xlsx))
        #expect(!registry.isPresetSupported(.documentPDF, for: .mp4))
        
        // Document Editable preset (PDF -> DOCX)
        #expect(registry.isPresetSupported(.documentEditable, for: .pdf))
        #expect(!registry.isPresetSupported(.documentEditable, for: .mp4))
        
        // Video Maximum Compatibility preset
        #expect(registry.isPresetSupported(.videoMaximumCompatibility, for: .mov))
        #expect(registry.isPresetSupported(.videoMaximumCompatibility, for: .mkv))
        #expect(!registry.isPresetSupported(.videoMaximumCompatibility, for: .png))
        #expect(!registry.isPresetSupported(.videoMaximumCompatibility, for: .docx))
        
        // Web preset
        #expect(registry.isPresetSupported(.web, for: .png))
        #expect(registry.isPresetSupported(.web, for: .mp4))
    }
    
    // MARK: - 6. PDF Separation & PDF Toolbox Routing
    
    @Test("PDF Separation: PDF Toolbox vs Format Conversion")
    func testPDFSeparation() {
        let pdfSupportedOutputs = registry.supportedOutputFormats(for: .pdf)
        
        // PDF should not be in its own format conversion outputs
        #expect(!pdfSupportedOutputs.contains(.pdf))
        
        // Format conversions from PDF
        #expect(pdfSupportedOutputs.contains(.docx))
        #expect(pdfSupportedOutputs.contains(.xlsx))
        #expect(pdfSupportedOutputs.contains(.pptx))
        #expect(pdfSupportedOutputs.contains(.png))
        #expect(pdfSupportedOutputs.contains(.jpg))
        #expect(pdfSupportedOutputs.contains(.tiff))
        
        // PDFToolboxEngine is resolved when pdf_operation is passed
        var toolboxOptions = ConversionOptions.default
        toolboxOptions.customOptions["pdf_operation"] = "merge"
        let toolboxEngine = registry.findEngine(from: .pdf, to: .pdf, options: toolboxOptions)
        #expect(toolboxEngine != nil)
        #expect(toolboxEngine?.name == "PDFToolboxEngine")
        
        // PDFConversionEngine is resolved for PDF -> PNG
        let imageEngine = registry.findEngine(from: .pdf, to: .png)
        #expect(imageEngine != nil)
        #expect(imageEngine?.name == "PDFEngine")
        
        // OfficeConversionEngine is resolved for PDF -> DOCX
        let officeEngine = registry.findEngine(from: .pdf, to: .docx)
        #expect(officeEngine != nil)
        #expect(officeEngine?.name == "OfficeEngine")
    }
}
