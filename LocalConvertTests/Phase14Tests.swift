import Testing
import Foundation
@testable import LocalConvert

@Suite("Phase 14 Presets & Quick Actions Tests")
struct Phase14Tests {
    
    @Test("Video Maximum Compatibility Preset")
    func testVideoMaximumCompatibilityPreset() {
        var options = ConversionOptions()
        options.preset = .videoMaximumCompatibility
        options.applyPreset()
        
        #expect(options.mediaQuality == .medium)
        #expect(options.customOptions["vcodec"] == "libx264")
        #expect(options.customOptions["acodec"] == "aac")
        #expect(options.customOptions["pix_fmt"] == "yuv420p")
        
        let target = ConversionPreset.videoMaximumCompatibility.targetOutputFormat(for: .video)
        #expect(target == .mp4)
    }
    
    @Test("Audio Only Preset")
    func testAudioOnlyPreset() {
        var options = ConversionOptions()
        options.preset = .audioOnly
        options.applyPreset()
        
        #expect(options.mediaQuality == .high)
        #expect(options.customOptions["audio_only"] == "true")
        
        let target = ConversionPreset.audioOnly.targetOutputFormat(for: .video)
        #expect(target == .mp3)
    }
    
    @Test("Document Presets")
    func testDocumentPresets() {
        var opts1 = ConversionOptions()
        opts1.preset = .documentPDF
        opts1.applyPreset()
        #expect(opts1.pdfDPI == 150.0)
        #expect(ConversionPreset.documentPDF.targetOutputFormat(for: .document) == .pdf)
        
        var opts2 = ConversionOptions()
        opts2.preset = .documentEditable
        opts2.applyPreset()
        #expect(opts2.pdfOfficeMode == .editable)
        #expect(ConversionPreset.documentEditable.targetOutputFormat(for: .document) == .docx)
        
        var opts3 = ConversionOptions()
        opts3.preset = .documentPrintArchive
        opts3.applyPreset()
        #expect(opts3.pdfDPI == 300.0)
        #expect(opts3.preserveMetadata == true)
        #expect(opts3.customOptions["pdf_archive"] == "true")
    }
    
    @Test("History Manager Tests")
    @MainActor
    func testHistoryManager() async throws {
        let history = HistoryManager.shared
        history.clearHistory()
        #expect(history.items.isEmpty)
        
        let item1 = ConversionHistoryItem(
            id: UUID(),
            inputFilename: "test.mp4",
            inputFormatName: "MP4 Video",
            outputFilename: "test.gif",
            outputFormatName: "GIF Image",
            date: Date(),
            status: .completed,
            inputSizeBytes: 1000,
            outputSizeBytes: 500,
            presetName: nil,
            outputURLPath: "/tmp/test.gif",
            duration: 1.5
        )
        history.addEntry(item1)
        #expect(history.items.count == 1)
        #expect(history.items[0].inputFilename == "test.mp4")
        
        let item2 = ConversionHistoryItem(
            id: UUID(),
            inputFilename: "test.pdf",
            inputFormatName: "PDF Document",
            outputFilename: "test.docx",
            outputFormatName: "Word Document",
            date: Date(),
            status: .failed,
            inputSizeBytes: nil,
            outputSizeBytes: nil,
            presetName: "Editable",
            outputURLPath: nil,
            duration: nil
        )
        history.addEntry(item2)
        #expect(history.items.count == 2)
        #expect(history.items[0].status == .failed) // inserted at index 0
        
        history.clearFailed()
        #expect(history.items.count == 1)
        #expect(history.items[0].status == .completed)
        
        // 500 entry limit
        for _ in 0..<505 {
            history.addEntry(item1)
        }
        #expect(history.items.count == 500)
    }

    @Test("Quick Actions Scheme URL Parsing")
    func testQuickActionsURLParsing() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("test_quick_action.pdf")
        try "test".write(to: fileURL, atomically: true, encoding: .utf8)
        
        let url = URL(string: "localconvert://convert?file=\(fileURL.path)")!
        let result = FinderHandoffHandler.parseSchemeURL(url)
        switch result {
        case .success(let urls):
            #expect(urls.count == 1)
            #expect(urls[0].path == fileURL.path)
        case .failure:
            Issue.record("Failed to parse localconvert URL")
        }
        
        try? FileManager.default.removeItem(at: fileURL)
    }
}
