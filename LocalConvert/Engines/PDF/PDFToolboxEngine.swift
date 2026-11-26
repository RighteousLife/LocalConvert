import Foundation
import PDFKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

final class PDFToolboxEngine: ConversionEngine, @unchecked Sendable {
    
    let name = "PDFToolboxEngine"
    
    var supportedInputFormats: Set<FileFormat> {
        [.pdf, .jpg, .png, .heic, .tiff]
    }
    
    var supportedOutputFormats: Set<FileFormat> {
        [.pdf, .png, .jpg, .tiff]
    }
    
    func canConvert(from input: FileFormat, to output: FileFormat) -> Bool {
        guard supportedInputFormats.contains(input) && supportedOutputFormats.contains(output) else {
            return false
        }
        if input == .pdf {
            return output == .pdf || output.category == .image
        } else if input.category == .image {
            return output == .pdf
        }
        return false
    }
    
    func availableOutputFormats(for input: FileFormat) -> Set<FileFormat> {
        if input == .pdf {
            return [.pdf, .png, .jpg, .tiff]
        } else if input.category == .image {
            return [.pdf]
        }
        return []
    }
    
    func isAvailable() async -> Bool {
        return true
    }
    
    func convert(
        inputs: [URL],
        to outputFormat: FileFormat,
        outputDirectory: URL,
        options: ConversionOptions,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> ConversionResult {
        
        let operation = options.customOptions["pdf_operation"] ?? "unknown"
        
        try Task.checkCancellation()
        if operation == "normalizePageSizes", inputs.count != 1 {
            throw ConversionError.invalidInput("Choose exactly one source PDF to normalize.")
        }
        
        if operation == "imagesToPDF" {
            return try await performImagesToPDF(inputs: inputs, outputDirectory: outputDirectory, progress: progress)
        }
        guard let firstInput = inputs.first else {
            throw ConversionError.invalidInput("No input files provided.")
        }
        if operation == "pdfToImages" {
            // Check if we use PDFConversionEngine or do it here. We'll do it here.
            return try await performPDFToImages(input: firstInput, to: outputFormat, outputDirectory: outputDirectory, options: options, progress: progress)
        }
        if operation == "normalizePageSizes", outputFormat != .pdf {
            throw ConversionError.invalidInput("PDF page-size normalization produces a PDF file.")
        }
        
        // All other operations are PDF -> PDF
        let input = firstInput
        var outputName = input.deletingPathExtension().lastPathComponent
        
        if operation == "merge" {
            outputName += "_merged"
        } else if operation == "splitEveryPage" || operation == "splitRanges" {
            outputName += "_split"
        } else if operation == "separatePages" {
            outputName += "_separated"
        } else if operation == "normalizePageSizes" {
            outputName += "_normalized"
        } else {
            outputName += "_\(operation)"
        }
        
        let outputURL = try ConversionManager.reserveUniqueOutputURL(
            directory: outputDirectory,
            baseName: outputName,
            extension: outputFormat.fileExtension,
            sourceURL: input,
            policy: operation == "normalizePageSizes" ? .createUnique : options.resolvedExistingFileHandling
        )
        defer { ConversionManager.releaseReservedOutputURL(outputURL) }
        
        if operation == "merge" {
            return try await performMerge(inputs: inputs, outputURL: outputURL, options: options, progress: progress)
        } else if operation == "pageWorkspace" {
            return try await performPageWorkspace(input: input, outputURL: outputURL, options: options, progress: progress)
        } else if operation == "splitEveryPage" {
            return try await performSplit(input: input, strategy: .everyPage, outputDirectory: outputDirectory, options: options, progress: progress)
        } else if operation == "splitEveryN" {
            let chunk = Int(options.customOptions["pdf_split_every_n"] ?? "2") ?? 2
            return try await performSplit(input: input, strategy: .everyNPages(chunk), outputDirectory: outputDirectory, options: options, progress: progress)
        } else if operation == "splitBookmarks" {
            return try await performSplit(input: input, strategy: .topLevelBookmarks, outputDirectory: outputDirectory, options: options, progress: progress)
        } else if operation == "splitRanges" {
            let rangesString = options.customOptions["pdf_pages"] ?? ""
            return try await performSplit(input: input, strategy: .pageRanges(rangesString), outputDirectory: outputDirectory, options: options, progress: progress)
        } else if operation == "extract" {
            let rangesString = options.customOptions["pdf_pages"] ?? ""
            return try await performExtract(input: input, rangesString: rangesString, outputURL: outputURL, options: options, progress: progress)
        } else if operation == "delete" {
            let rangesString = options.customOptions["pdf_pages"] ?? ""
            return try await performDelete(input: input, rangesString: rangesString, outputURL: outputURL, options: options, progress: progress)
        } else if operation == "reorder" {
            let rangesString = options.customOptions["pdf_pages"] ?? ""
            return try await performReorder(input: input, rangesString: rangesString, outputURL: outputURL, options: options, progress: progress)
        } else if operation == "duplicate" {
            let rangesString = options.customOptions["pdf_pages"] ?? ""
            return try await performDuplicate(input: input, rangesString: rangesString, outputURL: outputURL, options: options, progress: progress)
        } else if operation == "rotate" {
            let rotationStr = options.customOptions["pdf_rotation"] ?? "90"
            let rotation = Int(rotationStr) ?? 90
            let rangesString = options.customOptions["pdf_pages"] ?? ""
            return try await performRotate(input: input, rotation: rotation, rangesString: rangesString, outputURL: outputURL, options: options, progress: progress)
        } else if operation == "crop" || operation == "resize" {
            return try await performCropOrResize(input: input, outputURL: outputURL, options: options, progress: progress)
        } else if operation == "insert" {
            return try await performInsert(input: input, outputURL: outputURL, options: options, progress: progress)
        } else if operation == "annotate" {
            return try await performAnnotate(input: input, outputURL: outputURL, options: options, progress: progress)
        } else if operation == "compress" {
            return try await performCompress(input: input, outputURL: outputURL, options: options, progress: progress)
        } else if operation == "separatePages" {
            return try await performSeparatePages(input: input, outputURL: outputURL, options: options, progress: progress)
        } else if operation == "normalizePageSizes" {
            return try await performNormalizePageSizes(input: input, outputURL: outputURL, options: options, progress: progress)
        } else if operation == "ocr" {
            return try await performOCR(input: input, outputURL: outputURL, outputDirectory: outputDirectory, options: options, progress: progress)
        } else if operation == "pdfa" {
            return try await performPDFA(input: input, outputURL: outputURL, options: options, progress: progress)
        } else if operation == "redact" {
            return try await performRedact(input: input, outputURL: outputURL, options: options, progress: progress)
        } else if operation == "forms" {
            return try await performForms(input: input, outputURL: outputURL, options: options, progress: progress)
        } else if operation == "security" {
            return try await performSecurity(input: input, outputURL: outputURL, options: options, progress: progress)
        }
        
        throw ConversionError.invalidInput("Unknown operation \(operation)")
    }
    
    // MARK: - Document Loading with Password Decryption
    
    private func loadPDFDocument(from url: URL, options: ConversionOptions) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else {
            throw ConversionError.invalidInput("The PDF file could not be opened. It may be corrupted or invalid.")
        }
        if doc.isLocked {
            if let pwd = options.customOptions["pdf_password"], !pwd.isEmpty {
                guard doc.unlock(withPassword: pwd) else {
                    throw ConversionError.invalidInput("Incorrect password for protected PDF document '\(url.lastPathComponent)'.")
                }
            } else {
                throw ConversionError.invalidInput("The PDF file '\(url.lastPathComponent)' is password-protected. Please provide a password.")
            }
        }
        guard doc.pageCount > 0 else {
            throw ConversionError.invalidInput("The PDF file does not contain any pages.")
        }
        return doc
    }
    
    // MARK: - Delegated Page Management Implementations

    private func performPageWorkspace(input: URL, outputURL: URL, options: ConversionOptions, progress: @Sendable (ConversionProgress) -> Void) async throws -> ConversionResult {
        guard let json = options.customOptions["pdf_page_workspace"],
              let data = json.data(using: .utf8),
              let draft = try? JSONDecoder().decode(PDFPageWorkspaceDraft.self, from: data) else {
            throw ConversionError.invalidInput("Missing page workspace configuration.")
        }
        let startTime = CFAbsoluteTimeGetCurrent()
        let res = try await PDFPageManagementService.commitWorkspace(
            draft: draft,
            outputURL: outputURL,
            defaultPassword: options.customOptions["pdf_password"],
            progress: progress
        )
        let size = (try? FileManager.default.attributesOfItem(atPath: res.outputURL.path)[.size] as? Int64) ?? 0
        return ConversionResult(outputURL: res.outputURL, outputFormat: .pdf, fileSize: size, duration: CFAbsoluteTimeGetCurrent() - startTime, engineName: name)
    }

    private func performMerge(inputs: [URL], outputURL: URL, options: ConversionOptions, progress: @Sendable (ConversionProgress) -> Void) async throws -> ConversionResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        let res = try await PDFPageManagementService.merge(
            inputs: inputs,
            outputURL: outputURL,
            password: options.customOptions["pdf_password"],
            progress: progress
        )
        let size = (try? FileManager.default.attributesOfItem(atPath: res.outputURL.path)[.size] as? Int64) ?? 0
        return ConversionResult(outputURL: res.outputURL, outputFormat: .pdf, fileSize: size, duration: CFAbsoluteTimeGetCurrent() - startTime, engineName: name)
    }

    private func performSplit(
        input: URL,
        strategy: PDFSplitStrategy,
        outputDirectory: URL,
        options: ConversionOptions,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> ConversionResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        let res = try await PDFPageManagementService.split(
            input: input,
            strategy: strategy,
            outputDirectory: outputDirectory,
            baseName: input.deletingPathExtension().lastPathComponent,
            existingFileHandling: options.resolvedExistingFileHandling,
            password: options.customOptions["pdf_password"],
            progress: progress
        )
        let size = (try? FileManager.default.attributesOfItem(atPath: res.outputURL.path)[.size] as? Int64) ?? 0
        return ConversionResult(
            outputURL: res.outputURL,
            additionalOutputURLs: res.additionalOutputURLs,
            outputFormat: .pdf,
            fileSize: size,
            duration: CFAbsoluteTimeGetCurrent() - startTime,
            engineName: name
        )
    }

    private func performExtract(input: URL, rangesString: String, outputURL: URL, options: ConversionOptions, progress: @Sendable (ConversionProgress) -> Void) async throws -> ConversionResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        let res = try await PDFPageManagementService.extractPages(
            input: input,
            pageRanges: rangesString,
            outputURL: outputURL,
            password: options.customOptions["pdf_password"],
            progress: progress
        )
        let size = (try? FileManager.default.attributesOfItem(atPath: res.outputURL.path)[.size] as? Int64) ?? 0
        return ConversionResult(outputURL: res.outputURL, outputFormat: .pdf, fileSize: size, duration: CFAbsoluteTimeGetCurrent() - startTime, engineName: name)
    }

    private func performDelete(input: URL, rangesString: String, outputURL: URL, options: ConversionOptions, progress: @Sendable (ConversionProgress) -> Void) async throws -> ConversionResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        let res = try await PDFPageManagementService.deletePages(
            input: input,
            pageRanges: rangesString,
            outputURL: outputURL,
            password: options.customOptions["pdf_password"],
            progress: progress
        )
        let size = (try? FileManager.default.attributesOfItem(atPath: res.outputURL.path)[.size] as? Int64) ?? 0
        return ConversionResult(outputURL: res.outputURL, outputFormat: .pdf, fileSize: size, duration: CFAbsoluteTimeGetCurrent() - startTime, engineName: name)
    }

    private func performReorder(input: URL, rangesString: String, outputURL: URL, options: ConversionOptions, progress: @Sendable (ConversionProgress) -> Void) async throws -> ConversionResult {
        return try await performExtract(input: input, rangesString: rangesString, outputURL: outputURL, options: options, progress: progress)
    }

    private func performDuplicate(input: URL, rangesString: String, outputURL: URL, options: ConversionOptions, progress: @Sendable (ConversionProgress) -> Void) async throws -> ConversionResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        let doc = try loadPDFDocument(from: input, options: options)
        let targets = rangesString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Set(1...doc.pageCount)
            : Set(PageRangeParser.parse(rangesString, maxPages: doc.pageCount))
        let res = try await PDFPageManagementService.duplicatePages(
            input: input,
            oneBasedIndices: targets,
            outputURL: outputURL,
            password: options.customOptions["pdf_password"],
            progress: progress
        )
        let size = (try? FileManager.default.attributesOfItem(atPath: res.outputURL.path)[.size] as? Int64) ?? 0
        return ConversionResult(outputURL: res.outputURL, outputFormat: .pdf, fileSize: size, duration: CFAbsoluteTimeGetCurrent() - startTime, engineName: name)
    }

    private func performRotate(input: URL, rotation: Int, rangesString: String, outputURL: URL, options: ConversionOptions, progress: @Sendable (ConversionProgress) -> Void) async throws -> ConversionResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        let res = try await PDFPageManagementService.rotatePages(
            input: input,
            rotationDelta: rotation,
            pageRanges: rangesString,
            outputURL: outputURL,
            password: options.customOptions["pdf_password"],
            progress: progress
        )
        let size = (try? FileManager.default.attributesOfItem(atPath: res.outputURL.path)[.size] as? Int64) ?? 0
        return ConversionResult(outputURL: res.outputURL, outputFormat: .pdf, fileSize: size, duration: CFAbsoluteTimeGetCurrent() - startTime, engineName: name)
    }

    private func performCropOrResize(input: URL, outputURL: URL, options: ConversionOptions, progress: @Sendable (ConversionProgress) -> Void) async throws -> ConversionResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        let cropRect: NormalizedPDFCropRect? = {
            guard let raw = options.customOptions["pdf_crop_rect"],
                  let data = raw.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(NormalizedPDFCropRect.self, from: data)
        }()
        let preset: PDFPageSizePreset = {
            guard let raw = options.customOptions["pdf_page_size"],
                  let data = raw.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(PDFPageSizePreset.self, from: data) else { return .original }
            return decoded
        }()
        let mode = PDFPageResizeMode(rawValue: options.customOptions["pdf_resize_mode"] ?? "") ?? .fitPreserveAspect
        let res = try await PDFPageManagementService.cropAndResizePages(
            input: input,
            pageRanges: options.customOptions["pdf_pages"],
            normalizedCrop: cropRect,
            targetSizePreset: preset,
            resizeMode: mode,
            outputURL: outputURL,
            password: options.customOptions["pdf_password"],
            progress: progress
        )
        let size = (try? FileManager.default.attributesOfItem(atPath: res.outputURL.path)[.size] as? Int64) ?? 0
        return ConversionResult(outputURL: res.outputURL, outputFormat: .pdf, fileSize: size, duration: CFAbsoluteTimeGetCurrent() - startTime, engineName: name)
    }

    private func performInsert(input: URL, outputURL: URL, options: ConversionOptions, progress: @Sendable (ConversionProgress) -> Void) async throws -> ConversionResult {
        guard let insertPath = options.customOptions["pdf_insert_source_path"] else {
            throw ConversionError.invalidInput("Missing source PDF path for insert operation.")
        }
        let startTime = CFAbsoluteTimeGetCurrent()
        let pos = Int(options.customOptions["pdf_insert_position"] ?? "1") ?? 1
        let res = try await PDFPageManagementService.insertPages(
            basePDF: input,
            insertPDF: URL(fileURLWithPath: insertPath),
            insertPageRanges: options.customOptions["pdf_insert_pages"],
            atOneBasedPosition: pos,
            outputURL: outputURL,
            basePassword: options.customOptions["pdf_password"],
            insertPassword: options.customOptions["pdf_insert_password"],
            progress: progress
        )
        let size = (try? FileManager.default.attributesOfItem(atPath: res.outputURL.path)[.size] as? Int64) ?? 0
        return ConversionResult(outputURL: res.outputURL, outputFormat: .pdf, fileSize: size, duration: CFAbsoluteTimeGetCurrent() - startTime, engineName: name)
    }

    private func performAnnotate(input: URL, outputURL: URL, options: ConversionOptions, progress: @Sendable (ConversionProgress) -> Void) async throws -> ConversionResult {
        guard let json = options.customOptions["pdf_annotate_config"],
              let data = json.data(using: .utf8),
              var saveOptions = try? JSONDecoder().decode(PDFAnnotationSaveOptions.self, from: data) else {
            throw ConversionError.invalidInput("Missing annotation configuration.")
        }
        if saveOptions.password == nil {
            saveOptions.password = options.customOptions["pdf_password"]
        }
        let startTime = CFAbsoluteTimeGetCurrent()
        let res = try await PDFAnnotationService.applyAndSave(
            inputURL: input,
            outputURL: outputURL,
            options: saveOptions,
            progress: progress
        )
        let size = (try? FileManager.default.attributesOfItem(atPath: res.outputURL.path)[.size] as? Int64) ?? 0
        return ConversionResult(outputURL: res.outputURL, outputFormat: .pdf, fileSize: size, duration: CFAbsoluteTimeGetCurrent() - startTime, engineName: name)
    }
    
    private func performCompress(input: URL, outputURL: URL, options: ConversionOptions, progress: @Sendable (ConversionProgress) -> Void) async throws -> ConversionResult {
        var compressConfig: PDFCompressionOptions
        if let json = options.customOptions["pdf_compress_config"],
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(PDFCompressionOptions.self, from: data) {
            compressConfig = decoded
        } else {
            compressConfig = PDFCompressionOptions.forProfile(.balanced)
        }
        if compressConfig.password == nil {
            compressConfig.password = options.customOptions["pdf_password"]
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        let info = try await PDFCompressionService.compress(
            inputURL: input,
            outputURL: outputURL,
            options: compressConfig,
            progress: progress
        )
        return ConversionResult(
            outputURL: info.outputURL,
            outputFormat: .pdf,
            fileSize: info.compressedBytes,
            duration: CFAbsoluteTimeGetCurrent() - startTime,
            engineName: name
        )
    }

    // MARK: - Phase 34 Pro Operations (OCR, PDF/A, Redact, Forms, Security)

    private func performOCR(
        input: URL,
        outputURL: URL,
        outputDirectory: URL,
        options: ConversionOptions,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> ConversionResult {
        var ocrConfig: PDFOCROptions
        if let json = options.customOptions["pdf_ocr_config"],
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(PDFOCROptions.self, from: data) {
            ocrConfig = decoded
        } else {
            ocrConfig = .default
        }
        if ocrConfig.password == nil {
            ocrConfig.password = options.customOptions["pdf_password"]
        }

        let sidecarBase = input.deletingPathExtension().lastPathComponent + "_ocr_text"
        let sidecarURL: URL? = ocrConfig.exportExtractedTextSidecar
            ? try ConversionManager.reserveUniqueOutputURL(
                directory: outputDirectory,
                baseName: sidecarBase,
                extension: "txt",
                sourceURL: input,
                policy: .createUnique
            )
            : nil
        defer {
            if let sidecarURL {
                ConversionManager.releaseReservedOutputURL(sidecarURL)
            }
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        let res = try await PDFOCRService.runOCR(
            inputURL: input,
            outputPDFURL: outputURL,
            sidecarTextURL: sidecarURL,
            options: ocrConfig,
            progress: progress
        )
        let size = (try? FileManager.default.attributesOfItem(atPath: res.outputPDFURL.path)[.size] as? Int64) ?? 0
        let additional = res.sidecarTextURL.map { [$0] } ?? []
        return ConversionResult(
            outputURL: res.outputPDFURL,
            additionalOutputURLs: additional,
            outputFormat: .pdf,
            fileSize: size,
            duration: CFAbsoluteTimeGetCurrent() - startTime,
            engineName: name
        )
    }

    private func performPDFA(
        input: URL,
        outputURL: URL,
        options: ConversionOptions,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> ConversionResult {
        let profileName = options.customOptions["pdf_pdfa_profile"] ?? PDFAProfile.pdfa2b.rawValue
        guard let profile = PDFAProfile(rawValue: profileName) else {
            throw ConversionError.invalidInput("Unknown PDF/A profile '\(profileName)'.")
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        let res = try await PDFArchivalService.convertToPDFA(
            inputURL: input,
            outputURL: outputURL,
            profile: profile,
            password: options.customOptions["pdf_password"],
            progress: progress
        )
        let size = (try? FileManager.default.attributesOfItem(atPath: res.outputURL.path)[.size] as? Int64) ?? 0
        return ConversionResult(
            outputURL: res.outputURL,
            outputFormat: .pdf,
            fileSize: size,
            duration: CFAbsoluteTimeGetCurrent() - startTime,
            engineName: name
        )
    }

    private func performRedact(
        input: URL,
        outputURL: URL,
        options: ConversionOptions,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> ConversionResult {
        guard let json = options.customOptions["pdf_redact_config"],
              let data = json.data(using: .utf8),
              var redactConfig = try? JSONDecoder().decode(PDFRedactionOptions.self, from: data) else {
            throw ConversionError.invalidInput("Missing redaction configuration.")
        }
        if redactConfig.password == nil {
            redactConfig.password = options.customOptions["pdf_password"]
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        let report = try await PDFRedactionService.redact(
            inputURL: input,
            outputURL: outputURL,
            options: redactConfig,
            progress: progress
        )
        guard report.isVerifiedClean else {
            throw ConversionError.engineExecutionFailed(
                "Permanent redaction failed post-write verification; residual sensitive content detected: \(report.residualMatchesFound.joined(separator: ", ")).",
                underlyingError: nil
            )
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: report.outputURL.path)[.size] as? Int64) ?? 0
        return ConversionResult(
            outputURL: report.outputURL,
            outputFormat: .pdf,
            fileSize: size,
            duration: CFAbsoluteTimeGetCurrent() - startTime,
            engineName: name
        )
    }

    private func performForms(
        input: URL,
        outputURL: URL,
        options: ConversionOptions,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> ConversionResult {
        let fields: [PDFFormFieldItem]
        if let json = options.customOptions["pdf_form_fields"],
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([PDFFormFieldItem].self, from: data) {
            fields = decoded
        } else {
            fields = []
        }
        let flatten = (options.customOptions["pdf_form_flatten"] == "true")

        progress(.determinate(0.3, message: flatten ? "Flattening PDF form..." : "Saving PDF form..."))
        let startTime = CFAbsoluteTimeGetCurrent()
        let res = try PDFFormService.applyAndSave(
            inputURL: input,
            outputURL: outputURL,
            editedFields: fields,
            flatten: flatten,
            password: options.customOptions["pdf_password"]
        )
        progress(.determinate(1.0, message: "Complete"))
        let size = (try? FileManager.default.attributesOfItem(atPath: res.outputURL.path)[.size] as? Int64) ?? 0
        return ConversionResult(
            outputURL: res.outputURL,
            outputFormat: .pdf,
            fileSize: size,
            duration: CFAbsoluteTimeGetCurrent() - startTime,
            engineName: name
        )
    }

    private func performSecurity(
        input: URL,
        outputURL: URL,
        options: ConversionOptions,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> ConversionResult {
        guard let json = options.customOptions["pdf_security_config"],
              let data = json.data(using: .utf8),
              let secConfig = try? JSONDecoder().decode(PDFSecurityOptions.self, from: data) else {
            throw ConversionError.invalidInput("Missing PDF security configuration.")
        }

        progress(.determinate(0.35, message: secConfig.mode == .encrypt ? "Encrypting PDF..." : "Removing PDF password..."))
        let startTime = CFAbsoluteTimeGetCurrent()
        let res = try PDFSecurityService.applySecurity(
            inputURL: input,
            outputURL: outputURL,
            options: secConfig
        )
        progress(.determinate(1.0, message: "Complete"))
        let size = (try? FileManager.default.attributesOfItem(atPath: res.outputURL.path)[.size] as? Int64) ?? 0
        return ConversionResult(
            outputURL: res.outputURL,
            outputFormat: .pdf,
            fileSize: size,
            duration: CFAbsoluteTimeGetCurrent() - startTime,
            engineName: name
        )
    }
    
    private func performImagesToPDF(inputs: [URL], outputDirectory: URL, progress: @Sendable (ConversionProgress) -> Void) async throws -> ConversionResult {
        guard let firstInput = inputs.first else {
            throw ConversionError.invalidInput("No image files provided.")
        }
        let startTime = CFAbsoluteTimeGetCurrent()
        let subDoc = PDFDocument()
        var inserted = 0

        let outputName = firstInput.deletingPathExtension().lastPathComponent + "_images"
        let outputURL = try ConversionManager.reserveUniqueOutputURL(
            directory: outputDirectory,
            baseName: outputName,
            extension: "pdf",
            sourceURL: firstInput,
            policy: .createUnique
        )
        defer { ConversionManager.releaseReservedOutputURL(outputURL) }

        for (i, url) in inputs.enumerated() {
            try Task.checkCancellation()
            progress(.determinate(Double(i) / Double(max(1, inputs.count)), message: "Adding \(url.lastPathComponent)..."))
            autoreleasepool {
                if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                   let cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) {
                    let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
                    let orientRaw = (props?[kCGImagePropertyOrientation] as? UInt32) ?? 1
                    let oriented = ImageProcessor.orientCGImage(cg, orientation: CGImagePropertyOrientation(rawValue: orientRaw) ?? .up)
                    let nsImage = NSImage(cgImage: oriented, size: NSSize(width: oriented.width, height: oriented.height))
                    if let page = PDFPage(image: nsImage) {
                        subDoc.insert(page, at: inserted)
                        inserted += 1
                    }
                } else if let image = NSImage(contentsOf: url), let page = PDFPage(image: image) {
                    subDoc.insert(page, at: inserted)
                    inserted += 1
                }
            }
        }

        guard subDoc.pageCount > 0 else {
            throw ConversionError.engineExecutionFailed("Failed to save Images to PDF", underlyingError: nil)
        }
        try PDFPageManagementService.writeAtomicallyAndVerify(document: subDoc, to: outputURL, expectedPageCount: subDoc.pageCount)

        let size = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
        return ConversionResult(outputURL: outputURL, outputFormat: .pdf, fileSize: size, duration: CFAbsoluteTimeGetCurrent() - startTime, engineName: name)
    }

    private func performPDFToImages(input: URL, to outputFormat: FileFormat, outputDirectory: URL, options: ConversionOptions, progress: @Sendable (ConversionProgress) -> Void) async throws -> ConversionResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        let doc = try loadPDFDocument(from: input, options: options)
        let dpi = options.effectivePDFDPI
        let baseName = input.deletingPathExtension().lastPathComponent

        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-PDFToolboxImages-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        var reserved = [URL]()
        defer {
            for url in reserved { ConversionManager.releaseReservedOutputURL(url) }
        }
        var stagedPages: [(tempURL: URL, finalURL: URL)] = []
        let utType: UTType = (outputFormat == .jpg) ? .jpeg : ((outputFormat == .tiff) ? .tiff : .png)

        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            progress(.determinate(Double(i) / Double(doc.pageCount), message: "Rendering page \(i + 1)..."))

            let url = try ConversionManager.reserveUniqueOutputURL(
                directory: outputDirectory,
                baseName: "\(baseName)_page_\(i + 1)",
                extension: outputFormat.fileExtension,
                sourceURL: input,
                policy: options.resolvedExistingFileHandling
            )
            reserved.append(url)

            let tempPageURL = stagingDir.appendingPathComponent("page-\(i).\(outputFormat.fileExtension)")
            let wrotePage: Bool = autoreleasepool {
                guard let page = doc.page(at: i) else { return false }
                let upright = PDFCoordinateGeometry.uprightSize(for: page)
                let scale = CGFloat(dpi / 72.0)
                let width = max(1, Int((upright.width * scale).rounded()))
                let height = max(1, Int((upright.height * scale).rounded()))

                let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
                let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
                guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: bitmapInfo) else {
                    return false
                }

                context.setFillColor(.white)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.saveGState()
                context.scaleBy(x: scale, y: scale)
                page.draw(with: .cropBox, to: context)
                context.restoreGState()

                guard let cgImage = context.makeImage(),
                      let dest = CGImageDestinationCreateWithURL(tempPageURL as CFURL, utType.identifier as CFString, 1, nil) else {
                    return false
                }
                var destProps: [CFString: Any] = [:]
                if outputFormat == .jpg {
                    destProps[kCGImageDestinationLossyCompressionQuality] = options.effectiveImageQuality
                }
                CGImageDestinationAddImage(dest, cgImage, destProps as CFDictionary)
                return CGImageDestinationFinalize(dest)
            }

            if wrotePage {
                stagedPages.append((tempURL: tempPageURL, finalURL: url))
            }
        }

        try Task.checkCancellation()

        guard !stagedPages.isEmpty else {
            throw ConversionError.engineExecutionFailed("Failed to render PDF pages to images", underlyingError: nil)
        }

        let policy = options.resolvedExistingFileHandling
        var generated = [URL]()
        do {
            for staged in stagedPages {
                try Task.checkCancellation()
                let committedURL = try OutputReservationCoordinator.moveOrReplaceTempFile(
                    staged.tempURL,
                    to: staged.finalURL,
                    policy: policy
                )
                generated.append(committedURL)
            }
        } catch {
            if policy != .overwrite {
                for createdURL in generated {
                    try? FileManager.default.removeItem(at: createdURL)
                }
            }
            throw error
        }

        guard let first = generated.first else {
            throw ConversionError.engineExecutionFailed("Failed to render PDF pages to images", underlyingError: nil)
        }

        var additional = generated
        additional.removeFirst()

        let size = (try? FileManager.default.attributesOfItem(atPath: first.path)[.size] as? Int64) ?? 0
        return ConversionResult(outputURL: first, additionalOutputURLs: additional, outputFormat: outputFormat, fileSize: size, duration: CFAbsoluteTimeGetCurrent() - startTime, engineName: name)
    }
    
    // MARK: - PDF Grid Split (Separate Pages)
    
    private func performSeparatePages(
        input: URL,
        outputURL: URL,
        options: ConversionOptions,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> ConversionResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        let columns = try validatedGridDivision(
            optionKey: PDFGridLayout.columnsOptionKey,
            label: "Columns across",
            options: options
        )
        let rows = try validatedGridDivision(
            optionKey: PDFGridLayout.rowsOptionKey,
            label: "Rows down",
            options: options
        )
        
        let splitResult = try await PDFGridPageSplitter.split(
            input: input,
            outputURL: outputURL,
            layout: PDFGridLayout(rows: rows, columns: columns),
            password: options.customOptions["pdf_password"],
            progress: progress
        )
        
        let size = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
        let duration = CFAbsoluteTimeGetCurrent() - startTime
        
        return ConversionResult(
            outputURL: splitResult.outputURL,
            outputFormat: .pdf,
            fileSize: size,
            duration: duration,
            engineName: name
        )
    }

    private func performNormalizePageSizes(
        input: URL,
        outputURL: URL,
        options: ConversionOptions,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> ConversionResult {
        let request = try PDFPageNormalizationRequest.decode(from: options.customOptions)
        let startedAt = CFAbsoluteTimeGetCurrent()
        let result = try await PDFPageNormalizationService.normalize(
            sourceURL: input,
            target: request.target,
            outputURL: outputURL,
            password: options.customOptions["pdf_password"],
            progress: progress
        )
        let size = (try? FileManager.default.attributesOfItem(atPath: result.outputURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        return ConversionResult(
            outputURL: result.outputURL,
            outputFormat: .pdf,
            fileSize: size,
            duration: CFAbsoluteTimeGetCurrent() - startedAt,
            engineName: name
        )
    }

    private func validatedGridDivision(
        optionKey: String,
        label: String,
        options: ConversionOptions
    ) throws -> Int {
        guard let rawValue = options.customOptions[optionKey] else { return 2 }
        guard let value = Int(rawValue),
              (PDFGridLayout.minimumDivisionCount...PDFGridLayout.maximumDivisionCount).contains(value) else {
            throw ConversionError.invalidInput(
                "\(label) must be an integer from \(PDFGridLayout.minimumDivisionCount) to \(PDFGridLayout.maximumDivisionCount)."
            )
        }
        return value
    }
}
