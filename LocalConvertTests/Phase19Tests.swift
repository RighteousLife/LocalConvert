import Testing
import Foundation
import AppKit
import PDFKit
import AVFoundation
@testable import LocalConvert

@Suite("Phase 19 Drop Zone, Saved Presets & Preset Manager Tests")
struct Phase19Tests {
    
    // MARK: - Helper Methods
    
    private func createTempDirectory() -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-Phase19Tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }
    
    private func createTestPNG(at url: URL, width: Int = 100, height: Int = 100) {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        )!
        
        let data = rep.representation(using: .png, properties: [:])!
        try! data.write(to: url)
    }
    
    private func createTestWAV(at url: URL, durationSeconds: Double = 0.5) {
        let sampleRate: Double = 44100.0
        let channels: UInt32 = 1
        let numSamples = Int(sampleRate * durationSeconds)
        
        var header = [UInt8]()
        header.append(contentsOf: "RIFF".utf8)
        let subchunk2Size = UInt32(numSamples * 2)
        let chunkSize = UInt32(36 + subchunk2Size)
        header.append(contentsOf: withUnsafeBytes(of: chunkSize.littleEndian) { Array($0) })
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        let subchunk1Size: UInt32 = 16
        header.append(contentsOf: withUnsafeBytes(of: subchunk1Size.littleEndian) { Array($0) })
        let audioFormat: UInt16 = 1
        header.append(contentsOf: withUnsafeBytes(of: audioFormat.littleEndian) { Array($0) })
        let numChannels16: UInt16 = UInt16(channels)
        header.append(contentsOf: withUnsafeBytes(of: numChannels16.littleEndian) { Array($0) })
        let sampleRate32: UInt32 = UInt32(sampleRate)
        header.append(contentsOf: withUnsafeBytes(of: sampleRate32.littleEndian) { Array($0) })
        let byteRate: UInt32 = UInt32(sampleRate * Double(channels) * 2)
        header.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        let blockAlign: UInt16 = UInt16(channels * 2)
        header.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        let bitsPerSample: UInt16 = 16
        header.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })
        header.append(contentsOf: "data".utf8)
        header.append(contentsOf: withUnsafeBytes(of: subchunk2Size.littleEndian) { Array($0) })
        
        var audioData = Data(header)
        for i in 0..<numSamples {
            let sample = sin(2.0 * .pi * 440.0 * Double(i) / sampleRate)
            let sampleInt16 = Int16(max(-32768, min(32767, sample * 32767.0)))
            withUnsafeBytes(of: sampleInt16.littleEndian) {
                audioData.append(contentsOf: $0)
            }
        }
        
        try! audioData.write(to: url)
    }
    
    private func createTestPDF(at url: URL, text: String = "Phase 19 Preset Test Document") {
        let img = NSImage(size: NSSize(width: 200, height: 200), flipped: false) { rect in
            NSString(string: text).draw(at: NSPoint(x: 20, y: 100), withAttributes: nil)
            return true
        }
        let pdfDoc = PDFDocument()
        if let pdfPage = PDFPage(image: img) {
            pdfDoc.insert(pdfPage, at: 0)
        }
        pdfDoc.write(to: url)
    }
    
    // MARK: - Test 1: SavedPreset Serialization & Schema Versioning
    
    @Test("SavedPreset Codable, Equatable, and Schema Versioning")
    func testSavedPresetCodableAndSchema() throws {
        let preset = SavedPreset(
            id: UUID(),
            name: "Custom WebP Optimizer",
            description: "High performance web export",
            createdAt: Date(),
            modifiedAt: Date(),
            targetFormat: .webp,
            sourceConstraint: .png,
            sourceCategoryConstraint: .image,
            options: ConversionOptions(
                preset: .web,
                preserveMetadata: false,
                imageQuality: 0.82,
                webpLossless: false
            ),
            outputDestinationPolicy: .customDirectory(path: "/Users/test/Output"),
            outputNamingPolicy: .addSuffix(suffix: "_optimized"),
            schemaVersion: 1,
            isBuiltIn: false
        )
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(preset)
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SavedPreset.self, from: data)
        
        #expect(decoded.id == preset.id)
        #expect(decoded.name == "Custom WebP Optimizer")
        #expect(decoded.description == "High performance web export")
        #expect(decoded.targetFormat == .webp)
        #expect(decoded.sourceConstraint == .png)
        #expect(decoded.sourceCategoryConstraint == .image)
        #expect(decoded.options.imageQuality == 0.82)
        #expect(decoded.options.preserveMetadata == false)
        #expect(decoded.outputDestinationPolicy == .customDirectory(path: "/Users/test/Output"))
        #expect(decoded.outputNamingPolicy == .addSuffix(suffix: "_optimized"))
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.isBuiltIn == false)
    }
    
    // MARK: - Test 2: PresetStore CRUD & File Persistence
    
    @Test("PresetStore CRUD Operations & Atomic File Persistence")
    @MainActor
    func testPresetStoreCRUD() throws {
        let tempDir = createTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let storeURL = tempDir.appendingPathComponent("test_presets.json")
        let store = PresetStore(fileURL: storeURL)
        
        // Initial load should contain default templates
        #expect(!store.userPresets.isEmpty)
        let initialCount = store.userPresets.count
        
        // 1. Create / Save
        let newPreset = SavedPreset(
            name: "My Audio Extractor",
            description: "Custom MP3 export",
            targetFormat: .mp3,
            sourceCategoryConstraint: .video,
            options: ConversionOptions(preset: .audioOnly)
        )
        store.save(newPreset)
        #expect(store.userPresets.count == initialCount + 1)
        #expect(store.get(id: newPreset.id)?.name == "My Audio Extractor")
        
        // 2. Duplicate
        let duplicated = store.duplicate(id: newPreset.id)
        #expect(duplicated != nil)
        #expect(duplicated?.name == "My Audio Extractor (Copy)")
        #expect(duplicated?.id != newPreset.id)
        #expect(store.userPresets.count == initialCount + 2)
        
        // 3. Update
        var updated = newPreset
        updated.name = "Renamed Audio Extractor"
        store.save(updated)
        #expect(store.get(id: newPreset.id)?.name == "Renamed Audio Extractor")
        
        // 4. Delete
        store.delete(id: duplicated!.id)
        #expect(store.get(id: duplicated!.id) == nil)
        
        // 5. Test Persistence with new Store instance pointing to same file
        let reloadedStore = PresetStore(fileURL: storeURL)
        #expect(reloadedStore.get(id: newPreset.id)?.name == "Renamed Audio Extractor")
        #expect(reloadedStore.userPresets.count == initialCount + 1)
    }
    
    // MARK: - Test 3: PresetStore Corruption Recovery
    
    @Test("PresetStore Corruption Recovery Falls Back Gracefully")
    @MainActor
    func testPresetStoreCorruptionRecovery() throws {
        let tempDir = createTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let storeURL = tempDir.appendingPathComponent("corrupted_presets.json")
        // Write corrupted non-JSON garbage
        try "CORRUPTED { NOT A VALID JSON } [ { ".write(to: storeURL, atomically: true, encoding: .utf8)
        
        let store = PresetStore(fileURL: storeURL)
        
        // Must recover safely with default templates without crashing
        #expect(!store.userPresets.isEmpty)
        #expect(store.userPresets.count == SavedPreset.defaultTemplates.count)
        
        // Must have created a backup file
        let contents = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        let hasBackup = contents.contains { $0.contains("corrupted") && $0 != "corrupted_presets.json" }
        #expect(hasBackup == true)
    }
    
    // MARK: - Test 4: PresetValidator Single Source of Truth Checks
    
    @Test("PresetValidator Capability and Constraint Checks")
    func testPresetValidator() {
        let validator = PresetValidator()
        let registry = ConversionRegistry.shared
        
        // Valid preset
        let validPreset = SavedPreset(
            name: "JPG to WebP",
            targetFormat: .webp,
            sourceConstraint: .jpg
        )
        let (isValid, _) = validator.isPresetValid(validPreset, registry: registry)
        #expect(isValid == true)
        
        // Empty name preset -> invalid
        let emptyNamePreset = SavedPreset(
            name: "   ",
            targetFormat: .webp
        )
        let (isEmptyValid, _) = validator.isPresetValid(emptyNamePreset, registry: registry)
        #expect(isEmptyValid == false)
        
        // Source constraint match check
        let compatibility1 = validator.isFileCompatible(preset: validPreset, fileFormat: .jpg, registry: registry)
        #expect(compatibility1.isCompatible == true)
        
        let compatibility2 = validator.isFileCompatible(preset: validPreset, fileFormat: .png, registry: registry)
        #expect(compatibility2.isCompatible == false) // Constraint was strictly JPG
        
        // Category constraint check
        let videoOnlyPreset = SavedPreset(
            name: "Video to MP4",
            targetFormat: .mp4,
            sourceCategoryConstraint: .video
        )
        let videoCompat = validator.isFileCompatible(preset: videoOnlyPreset, fileFormat: .mov, registry: registry)
        #expect(videoCompat.isCompatible == true)
        
        let imageCompat = validator.isFileCompatible(preset: videoOnlyPreset, fileFormat: .png, registry: registry)
        #expect(imageCompat.isCompatible == false) // Image is not video
    }
    
    // MARK: - Test 5: PresetValidator Mixed Batch Categorization
    
    @Test("PresetValidator Mixed Batch Categorization and Summary")
    func testPresetValidatorBatch() {
        let tempDir = createTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let pngURL = tempDir.appendingPathComponent("image.png")
        let jpgURL = tempDir.appendingPathComponent("photo.jpg")
        let subFolder = tempDir.appendingPathComponent("nested_folder")
        try! FileManager.default.createDirectory(at: subFolder, withIntermediateDirectories: true)
        
        createTestPNG(at: pngURL)
        createTestPNG(at: jpgURL) // Even with .jpg extension, it exists
        
        let preset = SavedPreset(
            name: "WebP Exporter",
            targetFormat: .webp,
            sourceCategoryConstraint: .image
        )
        
        let validator = PresetValidator()
        let result = validator.validateBatch(
            preset: preset,
            urls: [pngURL, jpgURL, subFolder]
        )
        
        #expect(result.compatibleCount == 2)
        #expect(result.incompatibleCount == 1) // folder is incompatible
        #expect(result.incompatibleURLs.first?.reason == "Folders are not supported.")
        #expect(result.hasCompatibleFiles == true)
        #expect(result.isFullyCompatible == false)
        #expect(result.summary.contains("Applies to 2 of 3 files"))
    }
    
    // MARK: - Test 6: Preset Naming Policy
    
    @Test("Preset Naming Policy Prefix, Suffix, Standard")
    func testPresetNamingPolicies() {
        let standard = OutputNamingPolicy.standard
        #expect(standard.apply(to: "document") == "document")
        
        let suffix = OutputNamingPolicy.addSuffix(suffix: "_converted")
        #expect(suffix.apply(to: "document") == "document_converted")
        
        let prefix = OutputNamingPolicy.addPrefix(prefix: "thumb_")
        #expect(prefix.apply(to: "photo") == "thumb_photo")
    }
    
    // MARK: - Test 7: Headless PresetExecutor UI-Independence
    
    @Test("PresetExecutor UI-Independent Execution Generating Correct Jobs")
    @MainActor
    func testPresetExecutorHeadless() {
        let tempDir = createTempDirectory()
        let customOutDir = tempDir.appendingPathComponent("custom_output")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let pngURL = tempDir.appendingPathComponent("sample.png")
        createTestPNG(at: pngURL)
        
        let preset = SavedPreset(
            name: "Headless WebP Converter",
            targetFormat: .webp,
            sourceCategoryConstraint: .image,
            options: ConversionOptions(imageQuality: 0.77),
            outputDestinationPolicy: .customDirectory(path: customOutDir.path),
            outputNamingPolicy: .addSuffix(suffix: "_web")
        )
        
        let manager = ConversionManager()
        let queue = ConversionQueue(conversionManager: manager)
        let executor = PresetExecutor()
        
        let report = executor.execute(
            preset: preset,
            inputURLs: [pngURL],
            conversionManager: manager,
            conversionQueue: queue
        )
        
        #expect(report.isCompleteSuccess == true)
        #expect(report.successEnqueuedCount == 1)
        #expect(report.enqueuedJobs.first?.outputFormat == .webp)
        #expect(report.enqueuedJobs.first?.outputDirectory.path == customOutDir.path)
        #expect(report.enqueuedJobs.first?.options.customOptions["preset_name"] == "Headless WebP Converter")
        #expect(report.enqueuedJobs.first?.options.customOptions["output_suffix"] == "_web")
    }
    
    // MARK: - Test 8: Real File Preset Execution (PNG -> WebP with History Logging)
    
    @Test("Real File Preset Conversion: PNG to WebP with History Preset Tracking")
    @MainActor
    func testRealFilePresetExecution() async throws {
        let tempDir = createTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let inputPNG = tempDir.appendingPathComponent("real_preset_test.png")
        createTestPNG(at: inputPNG, width: 64, height: 64)
        
        let preset = SavedPreset(
            name: "Phase 19 Web-Optimized WebP",
            targetFormat: .webp,
            sourceCategoryConstraint: .image,
            options: ConversionOptions(preset: .web, imageQuality: 0.80),
            outputDestinationPolicy: .sameAsInput,
            outputNamingPolicy: .standard
        )
        
        let manager = ConversionManager()
        let queue = ConversionQueue(conversionManager: manager)
        let executor = PresetExecutor()
        
        let report = executor.execute(
            preset: preset,
            inputURLs: [inputPNG],
            conversionManager: manager,
            conversionQueue: queue
        )
        
        #expect(report.successEnqueuedCount == 1)
        
        // Wait for queue processing to complete
        var attempts = 0
        while queue.isProcessing && attempts < 50 {
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            attempts += 1
        }
        
        #expect(queue.completedCount == 1)
        #expect(queue.failedCount == 0)
        
        // Verify output WebP file exists and has RIFF/WEBP header
        let expectedOutput = tempDir.appendingPathComponent("real_preset_test.webp")
        #expect(FileManager.default.fileExists(atPath: expectedOutput.path))
        
        let webpData = try Data(contentsOf: expectedOutput)
        #expect(webpData.count > 12)
        let headerPrefix = String(data: webpData.prefix(4), encoding: .ascii)
        let webpTag = String(data: webpData.subdata(in: 8..<12), encoding: .ascii)
        #expect(headerPrefix == "RIFF")
        #expect(webpTag == "WEBP")
        
        // Verify presetName was saved in HistoryManager
        let history = HistoryManager.shared.items
        let matchedItem = history.first { $0.inputFilename == "real_preset_test.png" }
        #expect(matchedItem != nil)
        #expect(matchedItem?.presetName == "Phase 19 Web-Optimized WebP" || matchedItem?.presetName == "Web Optimized")
    }
    
    // MARK: - Test 9: Real Audio Preset Execution (WAV -> MP3)
    
    @Test("Real Audio Preset Execution: WAV to MP3 Transcode")
    @MainActor
    func testRealAudioPresetExecution() async throws {
        let tempDir = createTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let inputWAV = tempDir.appendingPathComponent("preset_audio.wav")
        createTestWAV(at: inputWAV, durationSeconds: 0.3)
        
        let preset = SavedPreset(
            name: "Phase 19 Extract MP3",
            targetFormat: .mp3,
            sourceCategoryConstraint: .audio,
            options: ConversionOptions(preset: .audioOnly),
            outputDestinationPolicy: .sameAsInput,
            outputNamingPolicy: .standard
        )
        
        let manager = ConversionManager()
        let queue = ConversionQueue(conversionManager: manager)
        let executor = PresetExecutor()
        
        let report = executor.execute(
            preset: preset,
            inputURLs: [inputWAV],
            conversionManager: manager,
            conversionQueue: queue
        )
        
        #expect(report.successEnqueuedCount == 1)
        
        var attempts = 0
        while queue.isProcessing && attempts < 50 {
            try await Task.sleep(nanoseconds: 100_000_000)
            attempts += 1
        }
        
        #expect(queue.completedCount == 1)
        #expect(queue.failedCount == 0)
        
        let expectedOutput = tempDir.appendingPathComponent("preset_audio.mp3")
        #expect(FileManager.default.fileExists(atPath: expectedOutput.path))
        let mp3Data = try Data(contentsOf: expectedOutput)
        #expect(mp3Data.count > 0)
    }
    
    // MARK: - Test 10: Real PDF to DOCX Preset Execution
    
    @Test("Real PDF to DOCX Preset Execution via LibreOffice Engine")
    @MainActor
    func testRealPDFToDOCXPresetExecution() async throws {
        let tempDir = createTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let inputPDF = tempDir.appendingPathComponent("preset_document.pdf")
        createTestPDF(at: inputPDF, text: "Preset PDF to DOCX Conversion")
        
        let preset = SavedPreset(
            name: "Phase 19 PDF to DOCX",
            targetFormat: .docx,
            sourceConstraint: .pdf,
            options: ConversionOptions(preset: .documentEditable, pdfOfficeMode: .editable),
            outputDestinationPolicy: .sameAsInput,
            outputNamingPolicy: .standard
        )
        
        let manager = ConversionManager()
        let queue = ConversionQueue(conversionManager: manager)
        let executor = PresetExecutor()
        
        let report = executor.execute(
            preset: preset,
            inputURLs: [inputPDF],
            conversionManager: manager,
            conversionQueue: queue
        )
        
        #expect(report.successEnqueuedCount == 1)
        
        var attempts = 0
        while queue.isProcessing && attempts < 80 {
            try await Task.sleep(nanoseconds: 200_000_000)
            attempts += 1
        }
        
        #expect(queue.completedCount == 1)
        #expect(queue.failedCount == 0)
        
        let expectedOutput = tempDir.appendingPathComponent("preset_document.docx")
        #expect(FileManager.default.fileExists(atPath: expectedOutput.path))
        let docxData = try Data(contentsOf: expectedOutput)
        #expect(docxData.count > 0)
        // DOCX is a ZIP archive (PK\x03\x04)
        #expect(docxData.prefix(2) == Data([0x50, 0x4B]))
    }
    
    // MARK: - Test 11: PresetManager AppState Queue Application
    
    @Test("PresetManager apply preset updates AppState dropped files format and options")
    @MainActor
    func testPresetManagerApplyToAppState() {
        let tempDir = createTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let img1 = tempDir.appendingPathComponent("photo1.png")
        let img2 = tempDir.appendingPathComponent("photo2.png")
        createTestPNG(at: img1)
        createTestPNG(at: img2)
        
        let appState = AppState()
        appState.handleDroppedURLs([img1, img2])
        #expect(appState.droppedFiles.count == 2)
        
        let preset = SavedPreset(
            name: "Apply Test WebP",
            targetFormat: .webp,
            sourceCategoryConstraint: .image,
            options: ConversionOptions(imageQuality: 0.72)
        )
        
        let result = PresetManager.shared.apply(preset: preset, to: appState)
        #expect(result.compatibleCount == 2)
        #expect(appState.droppedFiles[0].selectedOutputFormat == .webp)
        #expect(appState.droppedFiles[1].selectedOutputFormat == .webp)
        #expect(appState.droppedFiles[0].options.imageQuality == 0.72)
        #expect(appState.droppedFiles[0].options.customOptions["preset_name"] == "Apply Test WebP")
    }
    
    // MARK: - Test 12: Built-in Presets Immutability & Deletion Guard
    
    @Test("PresetStore protects built-in templates from deletion")
    @MainActor
    func testPresetStoreBuiltInProtection() throws {
        let tempDir = createTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let storeURL = tempDir.appendingPathComponent("test_store.json")
        let store = PresetStore(fileURL: storeURL)
        
        guard let firstBuiltIn = store.userPresets.first(where: { $0.isBuiltIn }) else {
            Issue.record("No built-in preset found in store")
            return
        }
        
        let initialCount = store.userPresets.count
        store.delete(id: firstBuiltIn.id)
        
        // Built-in should NOT have been removed
        #expect(store.userPresets.count == initialCount)
        #expect(store.get(id: firstBuiltIn.id) != nil)
    }
    
    // MARK: - Test 13: Real PNG -> JPG Preset Execution
    
    @Test("Real PNG to JPG Preset Execution with Quality Setting")
    @MainActor
    func testRealPNGToJPGPresetExecution() async throws {
        let tempDir = createTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let inputPNG = tempDir.appendingPathComponent("sample_photo.png")
        createTestPNG(at: inputPNG, width: 80, height: 80)
        
        let preset = SavedPreset(
            name: "High-Quality JPEG Export",
            targetFormat: .jpg,
            sourceCategoryConstraint: .image,
            options: ConversionOptions(imageQuality: 0.95),
            outputDestinationPolicy: .sameAsInput,
            outputNamingPolicy: .standard
        )
        
        let manager = ConversionManager()
        let queue = ConversionQueue(conversionManager: manager)
        let executor = PresetExecutor()
        
        let report = executor.execute(
            preset: preset,
            inputURLs: [inputPNG],
            conversionManager: manager,
            conversionQueue: queue
        )
        
        #expect(report.successEnqueuedCount == 1)
        
        var attempts = 0
        while queue.isProcessing && attempts < 50 {
            try await Task.sleep(nanoseconds: 100_000_000)
            attempts += 1
        }
        
        #expect(queue.completedCount == 1)
        #expect(queue.failedCount == 0)
        
        let expectedOutput = tempDir.appendingPathComponent("sample_photo.jpg")
        #expect(FileManager.default.fileExists(atPath: expectedOutput.path))
        let jpgData = try Data(contentsOf: expectedOutput)
        #expect(jpgData.count > 4)
        // JPEG starts with 0xFF, 0xD8
        #expect(jpgData[0] == 0xFF && jpgData[1] == 0xD8)
    }
    
    // MARK: - Test 14: Real DOCX -> PDF Preset Execution
    
    @Test("Real DOCX to PDF Preset Execution via Office Engine")
    @MainActor
    func testRealDOCXToPDFPresetExecution() async throws {
        let tempDir = createTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let docxURL = try TestFixtureFactory.createDOCX(in: tempDir, name: "source_doc.docx", text: "Preset Office Conversion")
        
        let preset = SavedPreset(
            name: "Document to PDF",
            targetFormat: .pdf,
            options: ConversionOptions(preset: .documentPDF, pdfDPI: 300.0),
            outputDestinationPolicy: .sameAsInput,
            outputNamingPolicy: .standard
        )
        
        let manager = ConversionManager()
        let queue = ConversionQueue(conversionManager: manager)
        let executor = PresetExecutor()
        
        let report = executor.execute(
            preset: preset,
            inputURLs: [docxURL],
            conversionManager: manager,
            conversionQueue: queue
        )
        
        #expect(report.successEnqueuedCount == 1)
        
        var attempts = 0
        while queue.isProcessing && attempts < 80 {
            try await Task.sleep(nanoseconds: 200_000_000)
            attempts += 1
        }
        
        #expect(queue.completedCount == 1)
        #expect(queue.failedCount == 0)
        
        let expectedOutput = tempDir.appendingPathComponent("source_doc.pdf")
        #expect(FileManager.default.fileExists(atPath: expectedOutput.path))
        let pdf = PDFDocument(url: expectedOutput)
        #expect(pdf != nil)
        #expect((pdf?.pageCount ?? 0) >= 1)
    }
    
    // MARK: - Test 15: PresetValidator Rejection of Read-Only / Unsupported Output Routes
    
    @Test("PresetValidator rejects read-only format targets and unsupported routes")
    func testPresetValidatorNegativeTargets() {
        let validator = PresetValidator()
        let registry = ConversionRegistry.shared
        
        // DNG is read-only in LocalConvert
        let dngTargetPreset = SavedPreset(
            name: "Invalid DNG Target",
            targetFormat: .dng
        )
        let (isDngValid, _) = validator.isPresetValid(dngTargetPreset, registry: registry)
        #expect(isDngValid == false)
        
        // PSD is read-only
        let psdTargetPreset = SavedPreset(
            name: "Invalid PSD Target",
            targetFormat: .psd
        )
        let (isPsdValid, _) = validator.isPresetValid(psdTargetPreset, registry: registry)
        #expect(isPsdValid == false)
        
        // 3GP is read-only
        let threeGPTargetPreset = SavedPreset(
            name: "Invalid 3GP Target",
            targetFormat: .threeGP
        )
        let (is3gpValid, _) = validator.isPresetValid(threeGPTargetPreset, registry: registry)
        #expect(is3gpValid == false)
        
        // Cross-category invalid route (Audio into Video-only MP4 preset without video stream)
        let videoPreset = SavedPreset(
            name: "Video MP4",
            targetFormat: .mp4,
            sourceCategoryConstraint: .video
        )
        let audioCompat = validator.isFileCompatible(preset: videoPreset, fileFormat: .mp3, registry: registry)
        #expect(audioCompat.isCompatible == false)
    }
    
    // MARK: - Test 16: Drop Zone Deduplication and Folder Handling in AppState
    
    @Test("AppState Drop Zone deduplication and folder rejection notice")
    @MainActor
    func testDropZoneAppStateFlow() {
        let tempDir = createTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let file1 = tempDir.appendingPathComponent("f1.png")
        let file2 = tempDir.appendingPathComponent("f2.png")
        let folder = tempDir.appendingPathComponent("dropped_folder")
        createTestPNG(at: file1)
        createTestPNG(at: file2)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        
        let appState = AppState()
        // Drop file1 and file2 and folder
        appState.handleDroppedURLs([file1, file2, folder])
        #expect(appState.droppedFiles.count == 2)
        #expect(appState.folderRejectedNotice != nil)
        
        // Drop file1 again (duplicate)
        appState.handleDroppedURLs([file1])
        #expect(appState.droppedFiles.count == 2) // No duplicates added
    }
}

