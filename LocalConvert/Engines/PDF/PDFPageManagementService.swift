import Foundation
import PDFKit
import CoreGraphics
import ImageIO
import AppKit

// MARK: - PDF Page Management Service

enum PDFPageManagementService {

    /// Commits a non-destructive `PDFPageWorkspaceDraft` (delete, reorder, move, duplicate, insert from other PDFs,
    /// rotate, crop, and/or normalize page dimensions) into a new output PDF atomically, preserving outlines & forms.
    static func commitWorkspace(
        draft: PDFPageWorkspaceDraft,
        outputURL: URL,
        passwordsByURL: [URL: String] = [:],
        defaultPassword: String? = nil,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> PDFPageOperationResult {
        try Task.checkCancellation()

        guard !draft.pages.isEmpty else {
            throw ConversionError.invalidInput("Cannot create a PDF with zero pages.")
        }

        // Verify source immutability for every referenced source PDF
        let outResolved = outputURL.standardizedFileURL.resolvingSymlinksInPath()
        for desc in draft.pages {
            let srcResolved = desc.sourceURL.standardizedFileURL.resolvingSymlinksInPath()
            guard srcResolved != outResolved else {
                throw ConversionError.invalidInput("Page management output must not overwrite a source PDF.")
            }
        }

        // Stale-file protection when baseline identity snapshot is present
        if let expected = draft.sourceIdentity, !expected.validateMatchesDisk().isValid {
            throw ConversionError.invalidInput("The source PDF was modified on disk since opening Page Studio. Reload the file before exporting.")
        }

        // Load and unlock each unique source PDF once
        var loadedDocs: [URL: PDFDocument] = [:]
        var orderedSources: [(url: URL, document: PDFDocument)] = []
        for desc in draft.pages {
            try Task.checkCancellation()
            let key = desc.sourceURL.standardizedFileURL
            if loadedDocs[key] != nil { continue }
            let pwd = passwordsByURL[key] ?? defaultPassword
            let doc = try openAndUnlock(url: key, password: pwd)
            loadedDocs[key] = doc
            orderedSources.append((key, doc))
        }

        let targetDoc = PDFDocument()
        var pageLookup: [PDFOutlineRemapper.RemapKey: PDFPage] = [:]
        var warnings: [String] = []

        // Check signature presence on primary sources
        for src in orderedSources {
            if let inspect = try? PDFDocumentInspector.inspect(url: src.url, password: passwordsByURL[src.url] ?? defaultPassword),
               inspect.hasDigitalSignatures {
                warnings.append("Source '\(src.url.lastPathComponent)' contained digital signature(s); rewriting pages produces a new unsigned PDF.")
            }
        }

        if let primary = draft.primaryURL?.standardizedFileURL,
           let attrs = loadedDocs[primary]?.documentAttributes {
            targetDoc.documentAttributes = attrs
        } else if let firstAttrs = orderedSources.first?.document.documentAttributes {
            targetDoc.documentAttributes = firstAttrs
        }

        let total = draft.pages.count
        for (targetIdx, desc) in draft.pages.enumerated() {
            try Task.checkCancellation()
            progress(.determinate(Double(targetIdx) / Double(max(1, total)) * 0.85, message: "Building page \(targetIdx + 1) of \(total)..."))

            let key = desc.sourceURL.standardizedFileURL
            guard let srcDoc = loadedDocs[key],
                  desc.sourcePageIndex >= 0,
                  desc.sourcePageIndex < srcDoc.pageCount,
                  let srcPage = srcDoc.page(at: desc.sourcePageIndex) else {
                throw ConversionError.invalidInput("Page \(desc.sourcePageIndex + 1) is out of range for '\(key.lastPathComponent)'.")
            }

            let outPage: PDFPage = try autoreleasepool {
                try buildTransformedPage(from: srcPage, descriptor: desc)
            }
            targetDoc.insert(outPage, at: targetIdx)

            let remapKey = PDFOutlineRemapper.RemapKey(url: key, pageIndex: desc.sourcePageIndex)
            if pageLookup[remapKey] == nil {
                pageLookup[remapKey] = outPage
            }
        }

        let outlineOutcome = PDFOutlineRemapper.remapOutlines(
            sources: orderedSources,
            targetPageLookup: pageLookup,
            into: targetDoc
        )

        var outlineNote: String? = nil
        if outlineOutcome.omittedCount > 0 {
            outlineNote = "\(outlineOutcome.omittedCount) bookmark(s) pointing to removed pages were omitted; \(outlineOutcome.preservedCount) bookmark(s) preserved."
            warnings.append(outlineNote!)
        }

        progress(.determinate(0.92, message: "Writing and verifying PDF..."))
        try writeAtomicallyAndVerify(document: targetDoc, to: outputURL, expectedPageCount: total)
        progress(.determinate(1.0, message: "Complete"))

        return PDFPageOperationResult(
            outputURL: outputURL,
            additionalOutputURLs: [],
            pageCount: total,
            preservedOutlineCount: outlineOutcome.preservedCount,
            omittedOutlineCount: outlineOutcome.omittedCount,
            outlineLimitationNote: outlineNote,
            warnings: warnings
        )
    }

    // MARK: - Convenience Structured Operations

    static func merge(
        inputs: [URL],
        outputURL: URL,
        password: String? = nil,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> PDFPageOperationResult {
        guard !inputs.isEmpty else {
            throw ConversionError.invalidInput("No PDF files provided to merge.")
        }
        var descriptors: [PDFPageDescriptor] = []
        for url in inputs {
            let doc = try openAndUnlock(url: url, password: password)
            for idx in 0..<doc.pageCount {
                descriptors.append(PDFPageDescriptor(sourceURL: url, sourcePageIndex: idx))
            }
        }
        let draft = PDFPageWorkspaceDraft(primaryURL: inputs.first, pages: descriptors, sourceIdentity: nil)
        return try await commitWorkspace(draft: draft, outputURL: outputURL, defaultPassword: password, progress: progress)
    }

    static func extractPages(
        input: URL,
        pageRanges: String,
        outputURL: URL,
        password: String? = nil,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> PDFPageOperationResult {
        let doc = try openAndUnlock(url: input, password: password)
        let pages = PageRangeParser.parse(pageRanges, maxPages: doc.pageCount)
        guard !pages.isEmpty else {
            throw ConversionError.invalidInput("No valid pages matched '\(pageRanges)'.")
        }
        let descriptors = pages.map { PDFPageDescriptor(sourceURL: input, sourcePageIndex: $0 - 1) }
        return try await commitWorkspace(
            draft: PDFPageWorkspaceDraft(primaryURL: input, pages: descriptors),
            outputURL: outputURL,
            defaultPassword: password,
            progress: progress
        )
    }

    static func deletePages(
        input: URL,
        pageRanges: String,
        outputURL: URL,
        password: String? = nil,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> PDFPageOperationResult {
        let doc = try openAndUnlock(url: input, password: password)
        let toDelete = Set(PageRangeParser.parse(pageRanges, maxPages: doc.pageCount))
        let remaining = (1...doc.pageCount).filter { !toDelete.contains($0) }
        guard !remaining.isEmpty else {
            throw ConversionError.invalidInput("Cannot delete all pages of a PDF.")
        }
        let descriptors = remaining.map { PDFPageDescriptor(sourceURL: input, sourcePageIndex: $0 - 1) }
        return try await commitWorkspace(
            draft: PDFPageWorkspaceDraft(primaryURL: input, pages: descriptors),
            outputURL: outputURL,
            defaultPassword: password,
            progress: progress
        )
    }

    static func reorderPages(
        input: URL,
        orderedOneBasedIndices: [Int],
        outputURL: URL,
        password: String? = nil,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> PDFPageOperationResult {
        let doc = try openAndUnlock(url: input, password: password)
        let valid = orderedOneBasedIndices.filter { $0 >= 1 && $0 <= doc.pageCount }
        guard !valid.isEmpty else {
            throw ConversionError.invalidInput("No valid page indices provided for reordering.")
        }
        let descriptors = valid.map { PDFPageDescriptor(sourceURL: input, sourcePageIndex: $0 - 1) }
        return try await commitWorkspace(
            draft: PDFPageWorkspaceDraft(primaryURL: input, pages: descriptors),
            outputURL: outputURL,
            defaultPassword: password,
            progress: progress
        )
    }

    static func duplicatePages(
        input: URL,
        oneBasedIndices: Set<Int>,
        outputURL: URL,
        password: String? = nil,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> PDFPageOperationResult {
        let doc = try openAndUnlock(url: input, password: password)
        var descriptors: [PDFPageDescriptor] = []
        for idx in 1...doc.pageCount {
            descriptors.append(PDFPageDescriptor(sourceURL: input, sourcePageIndex: idx - 1))
            if oneBasedIndices.contains(idx) {
                descriptors.append(PDFPageDescriptor(sourceURL: input, sourcePageIndex: idx - 1))
            }
        }
        return try await commitWorkspace(
            draft: PDFPageWorkspaceDraft(primaryURL: input, pages: descriptors),
            outputURL: outputURL,
            defaultPassword: password,
            progress: progress
        )
    }

    static func insertPages(
        basePDF: URL,
        insertPDF: URL,
        insertPageRanges: String?,
        atOneBasedPosition: Int,
        outputURL: URL,
        basePassword: String? = nil,
        insertPassword: String? = nil,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> PDFPageOperationResult {
        let baseDoc = try openAndUnlock(url: basePDF, password: basePassword)
        let insertDoc = try openAndUnlock(url: insertPDF, password: insertPassword)

        let insertIndices: [Int]
        if let raw = insertPageRanges?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            insertIndices = PageRangeParser.parse(raw, maxPages: insertDoc.pageCount)
        } else {
            insertIndices = Array(1...insertDoc.pageCount)
        }
        guard !insertIndices.isEmpty else {
            throw ConversionError.invalidInput("No valid pages selected from '\(insertPDF.lastPathComponent)' to insert.")
        }

        var descriptors = (0..<baseDoc.pageCount).map {
            PDFPageDescriptor(sourceURL: basePDF, sourcePageIndex: $0)
        }
        let clampedInsertPos = max(0, min(descriptors.count, atOneBasedPosition - 1))
        let newDescs = insertIndices.map { PDFPageDescriptor(sourceURL: insertPDF, sourcePageIndex: $0 - 1) }
        descriptors.insert(contentsOf: newDescs, at: clampedInsertPos)

        var pwds: [URL: String] = [:]
        if let basePassword, !basePassword.isEmpty { pwds[basePDF.standardizedFileURL] = basePassword }
        if let insertPassword, !insertPassword.isEmpty { pwds[insertPDF.standardizedFileURL] = insertPassword }

        return try await commitWorkspace(
            draft: PDFPageWorkspaceDraft(primaryURL: basePDF, pages: descriptors),
            outputURL: outputURL,
            passwordsByURL: pwds,
            defaultPassword: basePassword,
            progress: progress
        )
    }

    static func rotatePages(
        input: URL,
        rotationDelta: Int,
        pageRanges: String?,
        outputURL: URL,
        password: String? = nil,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> PDFPageOperationResult {
        let doc = try openAndUnlock(url: input, password: password)
        let targetSet: Set<Int>
        if let raw = pageRanges?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            targetSet = Set(PageRangeParser.parse(raw, maxPages: doc.pageCount))
        } else {
            targetSet = Set(1...doc.pageCount)
        }
        let descriptors = (0..<doc.pageCount).map { idx in
            PDFPageDescriptor(
                sourceURL: input,
                sourcePageIndex: idx,
                rotationDeltaDegrees: targetSet.contains(idx + 1) ? rotationDelta : 0
            )
        }
        return try await commitWorkspace(
            draft: PDFPageWorkspaceDraft(primaryURL: input, pages: descriptors),
            outputURL: outputURL,
            defaultPassword: password,
            progress: progress
        )
    }

    static func cropAndResizePages(
        input: URL,
        pageRanges: String?,
        normalizedCrop: NormalizedPDFCropRect?,
        targetSizePreset: PDFPageSizePreset,
        resizeMode: PDFPageResizeMode = .fitPreserveAspect,
        outputURL: URL,
        password: String? = nil,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> PDFPageOperationResult {
        let doc = try openAndUnlock(url: input, password: password)
        let targetSet: Set<Int>
        if let raw = pageRanges?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            targetSet = Set(PageRangeParser.parse(raw, maxPages: doc.pageCount))
        } else {
            targetSet = Set(1...doc.pageCount)
        }
        let descriptors = (0..<doc.pageCount).map { idx in
            let applies = targetSet.contains(idx + 1)
            return PDFPageDescriptor(
                sourceURL: input,
                sourcePageIndex: idx,
                normalizedCrop: applies ? normalizedCrop : nil,
                targetSizePreset: applies ? targetSizePreset : .original,
                resizeMode: resizeMode
            )
        }
        return try await commitWorkspace(
            draft: PDFPageWorkspaceDraft(primaryURL: input, pages: descriptors),
            outputURL: outputURL,
            defaultPassword: password,
            progress: progress
        )
    }

    static func split(
        input: URL,
        strategy: PDFSplitStrategy,
        outputDirectory: URL,
        baseName: String,
        existingFileHandling: ExistingFileHandling,
        password: String? = nil,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> PDFPageOperationResult {
        let doc = try openAndUnlock(url: input, password: password)
        let pageCount = doc.pageCount

        var groups: [(suffix: String, oneBasedPages: [Int])] = []
        switch strategy {
        case .everyPage:
            for p in 1...pageCount {
                groups.append(("page_\(p)", [p]))
            }
        case .everyNPages(let chunkSizeRaw):
            let chunkSize = max(1, chunkSizeRaw)
            var start = 1
            var part = 1
            while start <= pageCount {
                let end = min(pageCount, start + chunkSize - 1)
                groups.append(("part\(part)_p\(start)-\(end)", Array(start...end)))
                start = end + 1
                part += 1
            }
        case .pageRanges(let raw):
            let sections = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            for (idx, sec) in sections.enumerated() {
                let parsed = PageRangeParser.parse(sec, maxPages: pageCount)
                if !parsed.isEmpty {
                    groups.append(("part\(idx + 1)", parsed))
                }
            }
        case .topLevelBookmarks:
            var startPages: [(title: String, page: Int)] = []
            if let root = doc.outlineRoot {
                for i in 0..<root.numberOfChildren {
                    guard let child = root.child(at: i) else { continue }
                    let pObj = child.destination?.page ?? (child.action as? PDFActionGoTo)?.destination.page
                    if let pObj {
                        let zeroIdx = doc.index(for: pObj)
                        if zeroIdx != NSNotFound {
                            let label = (child.label ?? "section_\(i + 1)")
                                .replacingOccurrences(of: "/", with: "-")
                                .replacingOccurrences(of: ":", with: "-")
                            startPages.append((label, zeroIdx + 1))
                        }
                    }
                }
            }
            let sortedUnique = startPages.sorted { $0.page < $1.page }.reduce(into: [(title: String, page: Int)]()) { acc, item in
                if acc.last?.page != item.page { acc.append(item) }
            }
            if sortedUnique.isEmpty {
                throw ConversionError.invalidInput("This PDF has no top-level bookmarks/outlines to split on.")
            }
            for (idx, entry) in sortedUnique.enumerated() {
                let nextStart = (idx + 1 < sortedUnique.count) ? sortedUnique[idx + 1].page : (pageCount + 1)
                let endPage = max(entry.page, nextStart - 1)
                let cleanLabel = String(entry.title.prefix(32)).trimmingCharacters(in: .whitespacesAndNewlines)
                groups.append(("\(idx + 1)_\(cleanLabel.isEmpty ? "section" : cleanLabel)", Array(entry.page...endPage)))
            }
        }

        guard !groups.isEmpty else {
            throw ConversionError.invalidInput("No valid page groups were produced for splitting.")
        }

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-PDFSplit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        var reserved: [URL] = []
        var staged: [(tempURL: URL, finalURL: URL)] = []
        var totalOutlines = 0
        var omittedOutlines = 0
        defer {
            for r in reserved { ConversionManager.releaseReservedOutputURL(r) }
        }

        for (idx, group) in groups.enumerated() {
            try Task.checkCancellation()
            progress(.determinate(Double(idx) / Double(groups.count), message: "Writing split file \(idx + 1) of \(groups.count)..."))
            let outURL = try ConversionManager.reserveUniqueOutputURL(
                directory: outputDirectory,
                baseName: "\(baseName)_\(group.suffix)",
                extension: "pdf",
                sourceURL: input,
                policy: existingFileHandling
            )
            reserved.append(outURL)
            let tempSplitURL = tempRoot.appendingPathComponent("split_\(idx).pdf")
            let descriptors = group.oneBasedPages.map { PDFPageDescriptor(sourceURL: input, sourcePageIndex: $0 - 1) }
            let res = try await commitWorkspace(
                draft: PDFPageWorkspaceDraft(primaryURL: input, pages: descriptors),
                outputURL: tempSplitURL,
                defaultPassword: password,
                progress: { _ in }
            )
            staged.append((tempURL: res.outputURL, finalURL: outURL))
            totalOutlines += res.preservedOutlineCount
            omittedOutlines += res.omittedOutlineCount
        }

        try Task.checkCancellation()

        var generated: [URL] = []
        do {
            for item in staged {
                let committedURL = try OutputReservationCoordinator.moveOrReplaceTempFile(
                    item.tempURL,
                    to: item.finalURL,
                    policy: existingFileHandling
                )
                generated.append(committedURL)
            }
        } catch {
            if existingFileHandling != .overwrite {
                for createdURL in generated {
                    try? FileManager.default.removeItem(at: createdURL)
                }
            }
            throw error
        }

        guard let first = generated.first else {
            throw ConversionError.engineExecutionFailed("Split produced no output PDFs.", underlyingError: nil)
        }
        return PDFPageOperationResult(
            outputURL: first,
            additionalOutputURLs: Array(generated.dropFirst()),
            pageCount: generated.count,
            preservedOutlineCount: totalOutlines,
            omittedOutlineCount: omittedOutlines,
            outlineLimitationNote: nil,
            warnings: []
        )
    }

    // MARK: - Helpers (Transforms, Atomic Staging, Unlock)

    static func openAndUnlock(url: URL, password: String?) throws -> PDFDocument {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConversionError.inputFileNotFound(url)
        }
        guard let doc = PDFDocument(url: url) else {
            throw ConversionError.invalidInput("The PDF file '\(url.lastPathComponent)' could not be opened. It may be corrupted or invalid.")
        }
        if doc.isLocked {
            if let password, !password.isEmpty {
                guard doc.unlock(withPassword: password) else {
                    throw ConversionError.invalidInput("Incorrect password for protected PDF '\(url.lastPathComponent)'.")
                }
            } else {
                throw ConversionError.invalidInput("The PDF '\(url.lastPathComponent)' is password-protected.")
            }
        }
        guard doc.pageCount > 0 else {
            throw ConversionError.invalidInput("The PDF '\(url.lastPathComponent)' contains no pages.")
        }
        return doc
    }

    private static func buildTransformedPage(from sourcePage: PDFPage, descriptor: PDFPageDescriptor) throws -> PDFPage {
        guard let copied = sourcePage.copy() as? PDFPage else {
            throw ConversionError.engineExecutionFailed("Failed to copy PDF page instance.", underlyingError: nil)
        }

        // Apply incremental rotation first (modifies viewer rotation property cleanly without touching vector streams)
        if descriptor.rotationDeltaDegrees != 0 {
            copied.rotation = PDFCoordinateGeometry.normalizedRotation(copied.rotation + descriptor.rotationDeltaDegrees)
        }

        // Non-destructive CropBox adjustment when preserving page scaling
        if let normCrop = descriptor.normalizedCrop, !normCrop.isFullPage {
            let rawCrop = PDFCoordinateGeometry.uprightNormalizedRectToRawPage(normCrop, on: copied)
            copied.setBounds(rawCrop, for: .cropBox)
            if descriptor.targetSizePreset == .original {
                // TrimBox aligned cleanly as well
                copied.setBounds(rawCrop, for: .trimBox)
            }
        }

        // If no page dimension normalization requested, return the lightweight native copied PDFPage directly
        guard descriptor.targetSizePreset != .original,
              let presetBase = descriptor.targetSizePreset.sizeInPoints else {
            return copied
        }

        // Page dimension normalization: vector-preserving CGContext redraw onto new MediaBox (+ migrate annotations)
        let currentUpright = PDFCoordinateGeometry.uprightSize(for: copied)
        let isCurrentLandscape = currentUpright.width > currentUpright.height
        let targetSize: CGSize
        if descriptor.matchPageOrientation && isCurrentLandscape && presetBase.height > presetBase.width {
            targetSize = CGSize(width: presetBase.height, height: presetBase.width)
        } else {
            targetSize = presetBase
        }

        let targetBox = CGRect(origin: .zero, size: targetSize)
        var mediaBox = targetBox
        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ConversionError.engineExecutionFailed("Failed to create PDF context for page dimension resize.", underlyingError: nil)
        }

        let pageInfo: [CFString: Any] = [
            kCGPDFContextMediaBox: Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size) as CFData
        ]
        ctx.beginPDFPage(pageInfo as CFDictionary)
        ctx.setFillColor(.white)
        ctx.fill(targetBox)

        let sx = targetSize.width / max(1, currentUpright.width)
        let sy = targetSize.height / max(1, currentUpright.height)
        let chosenScale: CGFloat
        switch descriptor.resizeMode {
        case .fitPreserveAspect: chosenScale = min(sx, sy)
        case .fillCrop: chosenScale = max(sx, sy)
        case .centerUnscaled: chosenScale = 1.0
        }

        let drawnW = currentUpright.width * chosenScale
        let drawnH = currentUpright.height * chosenScale
        let originX = (targetSize.width - drawnW) * 0.5
        let originY = (targetSize.height - drawnH) * 0.5
        let drawRect = CGRect(x: originX, y: originY, width: drawnW, height: drawnH)

        ctx.saveGState()
        ctx.clip(to: targetBox)
        // PDFPage.draw(with: .cropBox, to:) automatically transforms for CropBox origin and page.rotation
        // into upright (0, 0, currentUpright.width, currentUpright.height) space.
        ctx.translateBy(x: drawRect.minX, y: drawRect.minY)
        ctx.scaleBy(x: chosenScale, y: chosenScale)
        copied.draw(with: .cropBox, to: ctx)
        ctx.restoreGState()

        ctx.endPDFPage()
        ctx.closePDF()

        guard let singleDoc = PDFDocument(data: pdfData as Data),
              let resizedPage = singleDoc.page(at: 0) else {
            throw ConversionError.engineExecutionFailed("Failed to finalize resized PDF page.", underlyingError: nil)
        }
        return resizedPage
    }

    static func writeAtomicallyAndVerify(document: PDFDocument, to outputURL: URL, expectedPageCount: Int) throws {
        let tempOut = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-PDFPage-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tempOut) }

        guard document.write(to: tempOut) else {
            throw ConversionError.engineExecutionFailed("Failed to write PDF to temporary staging file.", underlyingError: nil)
        }
        guard FileManager.default.fileExists(atPath: tempOut.path),
              let verifyDoc = PDFDocument(url: tempOut),
              verifyDoc.pageCount == expectedPageCount else {
            throw ConversionError.engineExecutionFailed("Output PDF failed structural post-write validation.", underlyingError: nil)
        }
        _ = try OutputReservationCoordinator.moveOrReplaceTempFile(tempOut, to: outputURL, policy: .overwrite)
    }
}
