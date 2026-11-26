import Foundation
import CoreGraphics
import PDFKit
import Security

// MARK: - PDF Document Inspector & PDF/A Validator (Read-Only)

enum PDFDocumentInspector {

    static func inspect(url: URL, password: String? = nil) throws -> PDFDocumentInspectionReport {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConversionError.inputFileNotFound(url)
        }
        guard let pdfDoc = PDFDocument(url: url) else {
            throw ConversionError.invalidInput("Unable to open PDF document at '\(url.lastPathComponent)'.")
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let cgDoc = CGPDFDocument(url as CFURL)

        if pdfDoc.isLocked {
            if let pwd = password, !pwd.isEmpty {
                guard pdfDoc.unlock(withPassword: pwd) else {
                    throw ConversionError.invalidInput("Incorrect password for '\(url.lastPathComponent)'.")
                }
                _ = cgDoc?.unlockWithPassword(pwd)
            }
        } else if let pwd = password, !pwd.isEmpty, cgDoc?.isUnlocked == false {
            _ = cgDoc?.unlockWithPassword(pwd)
        }

        // PDF version & permissions
        var pdfVersion = "\(pdfDoc.majorVersion).\(pdfDoc.minorVersion)"
        if let cgDoc {
            var maj: Int32 = 0
            var min: Int32 = 0
            cgDoc.getVersion(majorVersion: &maj, minorVersion: &min)
            if maj > 0 { pdfVersion = "\(maj).\(min)" }
        }

        // Access permissions via CGPDFDocumentGetAccessPermissions
        var allowLowPrint = pdfDoc.allowsPrinting
        var allowHighPrint = pdfDoc.allowsPrinting
        var allowCopy = pdfDoc.allowsCopying
        var allowAccess = pdfDoc.allowsContentAccessibility
        var allowComment = pdfDoc.allowsCommenting
        var allowForm = pdfDoc.allowsCommenting
        var allowChanges = pdfDoc.allowsDocumentChanges
        var allowAssembly = pdfDoc.allowsDocumentAssembly

        if let cgDoc {
            let p = cgDoc.accessPermissions
            allowLowPrint = p.contains(.allowsLowQualityPrinting)
            allowHighPrint = p.contains(.allowsHighQualityPrinting)
            allowCopy = p.contains(.allowsContentCopying)
            allowAccess = p.contains(.allowsContentAccessibility)
            allowComment = p.contains(.allowsCommenting)
            allowForm = p.contains(.allowsFormFieldEntry)
            allowChanges = p.contains(.allowsDocumentChanges)
            allowAssembly = p.contains(.allowsDocumentAssembly)
        }

        // Page sizes & orientations
        let pageCount = pdfDoc.pageCount
        var dimStrings: Set<String> = []
        var portraitCount = 0
        var landscapeCount = 0
        var annotationCount = 0
        var annotationTypes: Set<String> = []
        var signatureNames: [String] = []

        if !pdfDoc.isLocked {
            for idx in 0..<pageCount {
                guard let page = pdfDoc.page(at: idx) else { continue }
                let bounds = page.bounds(for: .cropBox)
                let w = Int(bounds.width.rounded())
                let h = Int(bounds.height.rounded())
                let isRotatedSide = (page.rotation % 180) != 0
                let effW = isRotatedSide ? h : w
                let effH = isRotatedSide ? w : h
                dimStrings.insert("\(effW)×\(effH) pt")
                if effW > effH { landscapeCount += 1 } else { portraitCount += 1 }

                for ann in page.annotations {
                    annotationCount += 1
                    if let type = ann.type { annotationTypes.insert(type) }
                    if ann.widgetFieldType == .signature {
                        let name = ann.fieldName ?? "Signature (Page \(idx + 1))"
                        signatureNames.append(name)
                    }
                }
            }
        }

        let dimsSummary = dimStrings.isEmpty ? "Locked / Unavailable" : dimStrings.sorted().prefix(4).joined(separator: ", ")
        let orientSummary: String
        if portraitCount > 0 && landscapeCount > 0 {
            orientSummary = "Mixed (\(portraitCount) Portrait, \(landscapeCount) Landscape)"
        } else if landscapeCount > 0 {
            orientSummary = "Landscape"
        } else if portraitCount > 0 {
            orientSummary = "Portrait"
        } else {
            orientSummary = "Unavailable"
        }

        // Document Attributes
        let attrs = pdfDoc.documentAttributes ?? [:]
        let title = attrs[PDFDocumentAttribute.titleAttribute] as? String
        let author = attrs[PDFDocumentAttribute.authorAttribute] as? String
        let subject = attrs[PDFDocumentAttribute.subjectAttribute] as? String
        let creator = attrs[PDFDocumentAttribute.creatorAttribute] as? String
        let producer = attrs[PDFDocumentAttribute.producerAttribute] as? String
        let creationDate = attrs[PDFDocumentAttribute.creationDateAttribute] as? Date
        let modDate = attrs[PDFDocumentAttribute.modificationDateAttribute] as? Date

        // Low-level CGPDF catalog inspection (XMP, OutputIntents, AcroForm, XFA, Signatures, Fonts, Images, Transparency, Encrypt, Structure, JS, EmbeddedFiles)
        let catalog = cgDoc?.catalog
        var xmpString: String? = nil
        var claimedPDFA: String? = nil
        var hasOutputIntent = false
        var hasValidOutputIntentSubtype = false
        var hasDestOutputProfile = false
        var hasAcroForm = false
        var hasXFA = false
        var formFieldCount = 0
        var hasStructureTree = false
        var hasOptionalContentLayers = false
        var hasAssociatedFiles = false
        var hasJavaScriptActions = false
        var embeddedFileNames: [String] = []
        var digitalSignatures: [PDFDigitalSignatureInfo] = []

        if let catalog {
            var metaStream: CGPDFStreamRef?
            if CGPDFDictionaryGetStream(catalog, "Metadata", &metaStream), let metaStream {
                var fmt: CGPDFDataFormat = .raw
                if let data = CGPDFStreamCopyData(metaStream, &fmt) as Data? {
                    xmpString = String(data: data, encoding: .utf8)
                    claimedPDFA = parsePDFAFromXMP(xmpString)
                }
            }

            var outputIntents: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(catalog, "OutputIntents", &outputIntents), let outputIntents {
                let count = CGPDFArrayGetCount(outputIntents)
                hasOutputIntent = count > 0
                for idx in 0..<count {
                    var oiDict: CGPDFDictionaryRef?
                    if CGPDFArrayGetDictionary(outputIntents, idx, &oiDict), let oiDict {
                        var sName: UnsafePointer<Int8>?
                        if CGPDFDictionaryGetName(oiDict, "S", &sName), let sName,
                           String(cString: sName).hasPrefix("GTS_PDF") {
                            hasValidOutputIntentSubtype = true
                        }
                        var profileStream: CGPDFStreamRef?
                        if CGPDFDictionaryGetStream(oiDict, "DestOutputProfile", &profileStream) {
                            hasDestOutputProfile = true
                        }
                    }
                }
            }

            var structObj: CGPDFObjectRef?
            hasStructureTree = CGPDFDictionaryGetObject(catalog, "StructTreeRoot", &structObj)

            var ocObj: CGPDFObjectRef?
            hasOptionalContentLayers = CGPDFDictionaryGetObject(catalog, "OCProperties", &ocObj)

            var afObj: CGPDFObjectRef?
            hasAssociatedFiles = CGPDFDictionaryGetObject(catalog, "AF", &afObj)

            if dictionaryContainsJSAction(catalog) {
                hasJavaScriptActions = true
            }

            var namesDict: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(catalog, "Names", &namesDict), let namesDict {
                var jsDict: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(namesDict, "JavaScript", &jsDict) {
                    hasJavaScriptActions = true
                }
                var embDict: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(namesDict, "EmbeddedFiles", &embDict), let embDict {
                    embeddedFileNames = collectEmbeddedFileNames(from: embDict)
                }
            }

            var acroForm: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(catalog, "AcroForm", &acroForm), let acroForm {
                hasAcroForm = true
                var xfaObj: CGPDFObjectRef?
                hasXFA = CGPDFDictionaryGetObject(acroForm, "XFA", &xfaObj)
                var fieldsArr: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(acroForm, "Fields", &fieldsArr), let fieldsArr {
                    formFieldCount = CGPDFArrayGetCount(fieldsArr)
                    for idx in 0..<formFieldCount {
                        var fDict: CGPDFDictionaryRef?
                        if CGPDFArrayGetDictionary(fieldsArr, idx, &fDict), let fDict {
                            if dictionaryContainsJSAction(fDict) { hasJavaScriptActions = true }
                            if let sigInfo = inspectSignatureFieldDictionary(fDict, pageNumber: nil, fileURL: url, fileSize: fileSize) {
                                if !digitalSignatures.contains(where: { $0.fieldName == sigInfo.fieldName && $0.byteRange == sigInfo.byteRange }) {
                                    digitalSignatures.append(sigInfo)
                                }
                            }
                        }
                    }
                }
            }
        }

        // Encryption & Linearization info via header/trailer scan
        let encryptionCipher = inspectEncryptionSummary(url: url, pdfDoc: pdfDoc)
        let isLinearized = inspectLinearizationFlag(url: url)

        // Scan Fonts, Images, Transparency, JS & Signatures per page
        let scan = scanPagesResources(cgDoc: cgDoc, pageCount: pageCount, isLocked: pdfDoc.isLocked, fileURL: url, fileSize: fileSize)
        if scan.hasJavaScript { hasJavaScriptActions = true }
        for sig in scan.signatures {
            if let existingIdx = digitalSignatures.firstIndex(where: { $0.fieldName == sig.fieldName && ($0.byteRange == sig.byteRange || $0.byteRange == nil) }) {
                if digitalSignatures[existingIdx].pageNumber == nil {
                    digitalSignatures[existingIdx] = sig
                }
            } else {
                digitalSignatures.append(sig)
            }
        }
        for sName in signatureNames {
            if !digitalSignatures.contains(where: { $0.fieldName == sName }) {
                digitalSignatures.append(PDFDigitalSignatureInfo(
                    fieldName: sName,
                    pageNumber: nil,
                    filter: nil,
                    subFilter: nil,
                    signerName: nil,
                    signingDateRaw: nil,
                    reason: nil,
                    location: nil,
                    byteRange: nil,
                    coversEntireFile: nil,
                    cmsCertificateCount: 0,
                    certificateSubjects: [],
                    certificateIssuers: [],
                    cryptographicStatusNote: "Unsigned signature field (no /V signature dictionary present)."
                ))
            }
        }
        if !scan.signatureFields.isEmpty {
            for s in scan.signatureFields where !signatureNames.contains(s) {
                signatureNames.append(s)
            }
        }

        let unembeddedCount = scan.fonts.filter { !$0.isEmbedded }.count
        let hasToUnicodeGap = scan.fonts.contains { !$0.hasToUnicode }
        _ = hasValidOutputIntentSubtype
        _ = hasDestOutputProfile

        // Warnings
        var warnings: [PDFInspectionWarning] = []
        if pdfDoc.isLocked {
            warnings.append(PDFInspectionWarning(severity: .critical, message: "PDF is password-locked. Unlock with user/owner password to inspect fonts, images, pages, and forms."))
        } else {
            if encryptionCipher.contains("Certificate / Public-Key") {
                warnings.append(PDFInspectionWarning(severity: .warning, message: "PDF uses certificate/public-key security handler; password-based unlock cannot decrypt certificate-protected files."))
            }
            if unembeddedCount > 0 {
                warnings.append(PDFInspectionWarning(severity: .warning, message: "\(unembeddedCount) font(s) are not embedded; appearance may vary on other systems and fails PDF/A."))
            }
            if hasToUnicodeGap {
                warnings.append(PDFInspectionWarning(severity: .warning, message: "One or more fonts lack a /ToUnicode CMap; text extraction or PDF/A-2u Unicode mapping may be incomplete."))
            }
            if hasXFA {
                warnings.append(PDFInspectionWarning(severity: .warning, message: "Contains dynamic XFA form definitions (/XFA). macOS PDFKit only edits AcroForm widgets; XFA layouts are read-only."))
            }
            if hasJavaScriptActions {
                warnings.append(PDFInspectionWarning(severity: .warning, message: "JavaScript actions (/JS /JavaScript) detected in catalog, annotations, or form fields."))
            }
            if !embeddedFileNames.isEmpty {
                warnings.append(PDFInspectionWarning(severity: .info, message: "Contains \(embeddedFileNames.count) embedded file attachment(s): \(embeddedFileNames.prefix(4).joined(separator: ", "))."))
            }
            if !signatureNames.isEmpty {
                let signedCount = digitalSignatures.filter { $0.subFilter != nil || $0.cmsCertificateCount > 0 }.count
                warnings.append(PDFInspectionWarning(severity: .info, message: "Document contains \(signatureNames.count) digital signature field(s) (\(signedCount) signed). Any modification invalidates existing signatures."))
            }
            if pdfDoc.isEncrypted && claimedPDFA != nil {
                warnings.append(PDFInspectionWarning(severity: .warning, message: "Document declares \(claimedPDFA!) but is encrypted; encryption violates ISO 19005 PDF/A requirements."))
            }
            if let t = title, t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                warnings.append(PDFInspectionWarning(severity: .info, message: "Title metadata attribute is empty."))
            }
        }

        let xmpSummary: String?
        if let xmpString {
            xmpSummary = "XMP stream present (\(xmpString.utf8.count) bytes)" + (claimedPDFA.map { " — declares \($0)" } ?? "")
        } else {
            xmpSummary = nil
        }

        return PDFDocumentInspectionReport(
            fileURL: url,
            fileSizeBytes: fileSize,
            pdfVersion: pdfVersion,
            pageCount: pageCount,
            pageDimensionsSummary: dimsSummary,
            orientationsSummary: orientSummary,
            title: title,
            author: author,
            subject: subject,
            creator: creator,
            producer: producer,
            creationDate: creationDate,
            modificationDate: modDate,
            hasXMPMetadata: xmpString != nil,
            xmpSummary: xmpSummary,
            claimedPDFAProfile: claimedPDFA,
            fonts: scan.fonts,
            unembeddedFontsCount: unembeddedCount,
            images: scan.images,
            hasTransparency: scan.hasTransparency,
            colorSpaces: Array(scan.colorSpaces).sorted(),
            hasOutputIntent: hasOutputIntent,
            annotationCount: annotationCount,
            annotationTypes: Array(annotationTypes).sorted(),
            hasAcroForm: hasAcroForm,
            hasXFA: hasXFA,
            formFieldCount: max(formFieldCount, annotationTypes.contains("/Widget") ? annotationCount : 0),
            isEncrypted: pdfDoc.isEncrypted,
            isLocked: pdfDoc.isLocked,
            encryptionCipherSummary: encryptionCipher,
            allowsPrinting: allowLowPrint,
            allowsHighQualityPrinting: allowHighPrint,
            allowsCopying: allowCopy,
            allowsContentAccessibility: allowAccess,
            allowsCommenting: allowComment,
            allowsFormFieldEntry: allowForm,
            allowsDocumentChanges: allowChanges,
            allowsDocumentAssembly: allowAssembly,
            hasDigitalSignatures: !signatureNames.isEmpty,
            signatureFieldNames: signatureNames,
            digitalSignatures: digitalSignatures,
            isLinearized: isLinearized,
            hasToUnicodeGap: hasToUnicodeGap,
            hasJavaScriptActions: hasJavaScriptActions,
            hasEmbeddedFiles: !embeddedFileNames.isEmpty,
            embeddedFileNames: embeddedFileNames,
            hasOptionalContentLayers: hasOptionalContentLayers,
            hasStructureTree: hasStructureTree,
            hasAssociatedFiles: hasAssociatedFiles,
            warnings: warnings
        )
    }

    // MARK: - PDF/A Validation

    static func validatePDFA(
        url: URL,
        expectedProfile: PDFAProfile? = nil,
        password: String? = nil
    ) throws -> PDFAValidationReport {
        let report = try inspect(url: url, password: password)

        let cgDoc = CGPDFDocument(url as CFURL)
        if let pwd = password, !pwd.isEmpty, cgDoc?.isUnlocked == false {
            _ = cgDoc?.unlockWithPassword(pwd)
        }

        var xmpPart: String?
        var xmpConf: String?
        var xmpRev: String?
        if let cat = cgDoc?.catalog {
            var metaStream: CGPDFStreamRef?
            if CGPDFDictionaryGetStream(cat, "Metadata", &metaStream), let metaStream {
                var fmt: CGPDFDataFormat = .raw
                if let data = CGPDFStreamCopyData(metaStream, &fmt) as Data?,
                   let s = String(data: data, encoding: .utf8) {
                    xmpPart = extractTag("pdfaid:part", in: s)
                    xmpConf = extractTag("pdfaid:conformance", in: s)?.uppercased()
                    xmpRev = extractTag("pdfaid:rev", in: s)
                }
            }
        }

        let detectedProfile: PDFAProfile
        if let expectedProfile {
            detectedProfile = expectedProfile
        } else {
            switch (xmpPart, xmpConf) {
            case ("1", _): detectedProfile = .pdfa1b
            case ("2", "U"): detectedProfile = .pdfa2u
            case ("2", _): detectedProfile = .pdfa2b
            case ("3", _): detectedProfile = .pdfa3b
            case ("4", _): detectedProfile = .pdfa4
            default: detectedProfile = .pdfa2b
            }
        }

        var checks: [PDFAValidationCheck] = []
        var warnings: [String] = []

        // 1. Unlocked
        checks.append(PDFAValidationCheck(
            requirement: "No Encryption / Password Restrictions",
            passed: !report.isEncrypted,
            detail: report.isEncrypted ? "PDF is encrypted, which is forbidden by ISO 19005." : "Document is unencrypted."
        ))

        // 2. XMP Identification Schema
        let expectedPart: String = {
            switch detectedProfile {
            case .pdfa1b: return "1"
            case .pdfa2b, .pdfa2u: return "2"
            case .pdfa3b: return "3"
            case .pdfa4: return "4"
            }
        }()
        let expectedConf: String? = {
            switch detectedProfile {
            case .pdfa1b, .pdfa2b, .pdfa3b: return "B"
            case .pdfa2u: return "U"
            case .pdfa4: return nil
            }
        }()

        let xmpMatched: Bool
        if let expectedConf {
            xmpMatched = report.hasXMPMetadata && xmpPart == expectedPart && xmpConf == expectedConf
        } else {
            xmpMatched = report.hasXMPMetadata && xmpPart == expectedPart
        }
        let foundTag = xmpPart.map { p in
            if let c = xmpConf { return "PDF/A-\(p)\(c.lowercased())" }
            if let r = xmpRev { return "PDF/A-\(p) (rev \(r))" }
            return "PDF/A-\(p)"
        } ?? "None"
        checks.append(PDFAValidationCheck(
            requirement: "XMP Metadata Stream (pdfaid)",
            passed: xmpMatched,
            detail: xmpMatched ? "Verified \(foundTag) XMP identification." : "Expected \(detectedProfile.rawValue), found \(foundTag)."
        ))

        // 3. OutputIntents ICC Profile
        checks.append(PDFAValidationCheck(
            requirement: "Color Management OutputIntents",
            passed: report.hasOutputIntent,
            detail: report.hasOutputIntent ? "Catalog /OutputIntents array present." : "Missing /OutputIntents ICC profile dictionary."
        ))

        // 4. Font Embedding
        let allFontsEmbedded = !report.isLocked && report.unembeddedFontsCount == 0
        checks.append(PDFAValidationCheck(
            requirement: "All Fonts Embedded",
            passed: allFontsEmbedded,
            detail: report.isLocked ? "Cannot verify fonts while locked." : (allFontsEmbedded ? "All \(report.fonts.count) font reference(s) embedded (or vector-only)." : "\(report.unembeddedFontsCount) unembedded font(s) detected."),
            objectPath: report.fonts.filter { !$0.isEmbedded }.map(\.name).joined(separator: ", ")
        ))

        // 5. Font Unicode / ToUnicode CMap Mapping
        if !report.isLocked && !report.fonts.isEmpty {
            let unicodeOK = !report.hasToUnicodeGap
            let missingUnicodeFonts = report.fonts.filter { !$0.hasToUnicode }.map(\.name).joined(separator: ", ")
            let requiresStrictUnicode = (detectedProfile == .pdfa2u)
            checks.append(PDFAValidationCheck(
                requirement: "Font ToUnicode CMap Mapping",
                passed: unicodeOK || !requiresStrictUnicode,
                detail: unicodeOK
                    ? "All inspected fonts include /ToUnicode CMaps."
                    : "Font(s) missing /ToUnicode CMap (\(missingUnicodeFonts)); \(requiresStrictUnicode ? "required by PDF/A-2u." : "text extraction reliability may be reduced.")",
                severity: requiresStrictUnicode ? "Error" : "Warning",
                objectPath: missingUnicodeFonts.isEmpty ? nil : missingUnicodeFonts
            ))
            if !unicodeOK && !requiresStrictUnicode {
                warnings.append("Fonts without /ToUnicode CMap: \(missingUnicodeFonts)")
            }
        }

        // 6. JavaScript / Active Content Forbidden
        checks.append(PDFAValidationCheck(
            requirement: "No JavaScript / Active Actions",
            passed: !report.hasJavaScriptActions,
            detail: report.hasJavaScriptActions ? "JavaScript or interactive trigger actions detected (disallowed in PDF/A)." : "No JavaScript triggers detected."
        ))

        // 7. Embedded Files Policy
        if report.hasEmbeddedFiles {
            if detectedProfile == .pdfa1b {
                checks.append(PDFAValidationCheck(
                    requirement: "PDF/A-1b No Embedded Files",
                    passed: false,
                    detail: "Embedded files detected (\(report.embeddedFileNames.joined(separator: ", "))); forbidden in ISO 19005-1.",
                    objectPath: "/Catalog/Names/EmbeddedFiles"
                ))
            } else if detectedProfile == .pdfa3b || detectedProfile == .pdfa4 {
                checks.append(PDFAValidationCheck(
                    requirement: "Associated Files (/AF) Declaration",
                    passed: report.hasAssociatedFiles,
                    detail: report.hasAssociatedFiles ? "Embedded files carry /AF associated-file references." : "Embedded files present without catalog /AF declaration.",
                    severity: report.hasAssociatedFiles ? "Info" : "Warning",
                    objectPath: "/Catalog/AF"
                ))
            }
        }

        // 8. PDF/A-1b Transparency & Optional Content Restrictions
        if detectedProfile == .pdfa1b {
            let noTrans = !report.hasTransparency
            checks.append(PDFAValidationCheck(
                requirement: "PDF/A-1b No Transparency",
                passed: noTrans,
                detail: noTrans ? "No transparency groups or soft masks detected." : "Transparency group or image /SMask detected (disallowed in PDF/A-1b)."
            ))
            checks.append(PDFAValidationCheck(
                requirement: "PDF/A-1b No Optional Content Layers",
                passed: !report.hasOptionalContentLayers,
                detail: report.hasOptionalContentLayers ? "Catalog /OCProperties layers detected (disallowed in ISO 19005-1)." : "No optional content layers present.",
                objectPath: "/Catalog/OCProperties"
            ))
        }

        // 9. PDF Version Sanity
        let versionOK: Bool = {
            switch detectedProfile {
            case .pdfa1b: return report.pdfVersion == "1.4"
            case .pdfa2b, .pdfa2u, .pdfa3b: return report.pdfVersion >= "1.4"
            case .pdfa4: return report.pdfVersion >= "2.0"
            }
        }()
        checks.append(PDFAValidationCheck(
            requirement: "PDF Header Version Compatibility",
            passed: versionOK,
            detail: "Detected PDF \(report.pdfVersion) for \(detectedProfile.isoStandard)."
        ))

        if report.fonts.isEmpty {
            warnings.append("No text fonts were found in page resource dictionaries (document may be image/vector-only).")
        }
        warnings.append("Structural & XMP conformance check only — not an ISO 19005 veraPDF certification.")

        let failed = checks.filter { !$0.passed }.map { "\($0.requirement): \($0.detail)" }
        return PDFAValidationReport(
            profile: detectedProfile,
            detectedPart: xmpPart,
            detectedConformance: xmpConf,
            detectedRevision: xmpRev,
            isCompliant: failed.isEmpty,
            checks: checks,
            failedRequirements: failed,
            warnings: warnings
        )
    }

    // MARK: - Helpers (XMP, Cipher & Page Resource Traversal)

    private static func parsePDFAFromXMP(_ xml: String?) -> String? {
        guard let xml, let part = extractTag("pdfaid:part", in: xml) else { return nil }
        if let conf = extractTag("pdfaid:conformance", in: xml) {
            return "PDF/A-\(part)\(conf.lowercased())"
        }
        return "PDF/A-\(part)"
    }

    private static func extractTag(_ tag: String, in text: String) -> String? {
        let pattern = "<\(NSRegularExpression.escapedPattern(for: tag))>([^<]+)</\(NSRegularExpression.escapedPattern(for: tag))>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func inspectLinearizationFlag(url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 4096)) ?? Data()
        guard let text = String(data: head, encoding: .isoLatin1) else { return false }
        return text.contains("/Linearized") && text.contains("/L ") && text.contains("/H")
    }

    private static func inspectEncryptionSummary(url: URL, pdfDoc: PDFDocument) -> String {
        guard pdfDoc.isEncrypted else { return "None (Unencrypted)" }
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
            var windows: [Data] = []
            // Scan tail (last 64 KB) and head (first 64 KB, or whole file if <= 512 KB) to catch /Encrypt objects anywhere
            if size <= 524_288 {
                if let d = try? handle.read(upToCount: Int(size)) { windows.append(d) }
            } else {
                if let head = try? handle.read(upToCount: 65536) { windows.append(head) }
                try? handle.seek(toOffset: size - 65536)
                if let tail = try? handle.read(upToCount: 65536) { windows.append(tail) }
            }
            let combined = windows.compactMap { String(data: $0, encoding: .isoLatin1) }.joined(separator: "\n")
            if combined.contains("/Filter /Adobe.PubSec") || combined.contains("/Filter/Adobe.PubSec") || combined.contains("/adbe.pkcs7.s") {
                return "Encrypted (Certificate / Public-Key Security Handler)"
            }
            if combined.contains("/V 5") || combined.contains("/R 6") || combined.contains("/AESV3") {
                return "Encrypted (AES-256 / PDF 2.0)"
            } else if combined.contains("/V 4") || combined.contains("/AESV2") {
                return "Encrypted (AES-128 / 128-bit)"
            } else if combined.contains("/Length 128") || combined.contains("/V 2") {
                return "Encrypted (RC4-128)"
            } else if combined.contains("/V 1") || combined.contains("/R 2") {
                return "Encrypted (RC4-40)"
            }
        }
        return "Encrypted (Standard Security Handler)"
    }

    private final class ResourceScanAccumulator {
        struct FontKey: Hashable {
            let name: String
            let subtype: String
            let isEmbedded: Bool
            let hasToUnicode: Bool
        }
        var fontPages: [FontKey: Set<Int>] = [:]
        var images: [PDFImageAssetInfo] = []
        var hasTransparency = false
        var hasJavaScript = false
        var colorSpaces: Set<String> = []
        var signatureFields: [String] = []
        var signatures: [PDFDigitalSignatureInfo] = []
    }

    private static func scanPagesResources(
        cgDoc: CGPDFDocument?,
        pageCount: Int,
        isLocked: Bool,
        fileURL: URL,
        fileSize: Int64
    ) -> (fonts: [PDFFontInfo], images: [PDFImageAssetInfo], hasTransparency: Bool, hasJavaScript: Bool, colorSpaces: Set<String>, signatureFields: [String], signatures: [PDFDigitalSignatureInfo]) {
        guard let cgDoc, !isLocked else {
            return ([], [], false, false, [], [], [])
        }

        let acc = ResourceScanAccumulator()

        for pageIndex in 1...max(1, pageCount) where pageIndex <= cgDoc.numberOfPages {
            guard let page = cgDoc.page(at: pageIndex),
                  let pageDict = page.dictionary else { continue }

            // Page transparency group check (/Group -> /S == /Transparency)
            var groupDict: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(pageDict, "Group", &groupDict), let groupDict {
                var sName: UnsafePointer<Int8>?
                if CGPDFDictionaryGetName(groupDict, "S", &sName), let sName,
                   String(cString: sName) == "Transparency" {
                    acc.hasTransparency = true
                }
            }

            if dictionaryContainsJSAction(pageDict) {
                acc.hasJavaScript = true
            }

            // Signature annotations from raw page Annots
            var annotsArr: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(pageDict, "Annots", &annotsArr), let annotsArr {
                for a in 0..<CGPDFArrayGetCount(annotsArr) {
                    var aDict: CGPDFDictionaryRef?
                    if CGPDFArrayGetDictionary(annotsArr, a, &aDict), let aDict {
                        if dictionaryContainsJSAction(aDict) { acc.hasJavaScript = true }
                        if let sigInfo = inspectSignatureFieldDictionary(aDict, pageNumber: pageIndex, fileURL: fileURL, fileSize: fileSize) {
                            acc.signatureFields.append(sigInfo.fieldName)
                            acc.signatures.append(sigInfo)
                        }
                    }
                }
            }

            var resDict: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(pageDict, "Resources", &resDict), let resDict else { continue }

            // Fonts
            var fontDict: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(resDict, "Font", &fontDict), let fontDict {
                let ctx = Unmanaged.passRetained(FontVisitContext(page: pageIndex, acc: acc))
                CGPDFDictionaryApplyFunction(fontDict, { _, obj, info in
                    guard let info else { return }
                    let v = Unmanaged<FontVisitContext>.fromOpaque(info).takeUnretainedValue()
                    var fDict: CGPDFDictionaryRef?
                    guard CGPDFObjectGetValue(obj, .dictionary, &fDict), let fDict else { return }
                    PDFDocumentInspector.inspectFontDictionary(fDict, page: v.page, acc: v.acc)
                }, ctx.toOpaque())
                ctx.release()
            }

            // ExtGState alpha check
            var extGDict: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(resDict, "ExtGState", &extGDict), let extGDict {
                let ctx = Unmanaged.passRetained(acc)
                CGPDFDictionaryApplyFunction(extGDict, { _, obj, info in
                    guard let info else { return }
                    let a = Unmanaged<ResourceScanAccumulator>.fromOpaque(info).takeUnretainedValue()
                    var gDict: CGPDFDictionaryRef?
                    guard CGPDFObjectGetValue(obj, .dictionary, &gDict), let gDict else { return }
                    var ca: CGPDFReal = 1.0
                    if CGPDFDictionaryGetNumber(gDict, "CA", &ca), ca < 0.999 { a.hasTransparency = true }
                    var caNonStroke: CGPDFReal = 1.0
                    if CGPDFDictionaryGetNumber(gDict, "ca", &caNonStroke), caNonStroke < 0.999 { a.hasTransparency = true }
                    var smaskObj: CGPDFObjectRef?
                    if CGPDFDictionaryGetObject(gDict, "SMask", &smaskObj), let smaskObj {
                        if CGPDFObjectGetType(smaskObj) == .dictionary { a.hasTransparency = true }
                    }
                }, ctx.toOpaque())
                ctx.release()
            }

            // XObject Images
            var xobjDict: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(resDict, "XObject", &xobjDict), let xobjDict {
                let ctx = Unmanaged.passRetained(FontVisitContext(page: pageIndex, acc: acc))
                CGPDFDictionaryApplyFunction(xobjDict, { _, obj, info in
                    guard let info else { return }
                    let v = Unmanaged<FontVisitContext>.fromOpaque(info).takeUnretainedValue()
                    var stream: CGPDFStreamRef?
                    guard CGPDFObjectGetValue(obj, .stream, &stream), let stream,
                          let dict = CGPDFStreamGetDictionary(stream) else { return }
                    var subtype: UnsafePointer<Int8>?
                    if CGPDFDictionaryGetName(dict, "Subtype", &subtype), let subtype,
                       String(cString: subtype) == "Image" {
                        var w: CGPDFInteger = 0
                        var h: CGPDFInteger = 0
                        _ = CGPDFDictionaryGetInteger(dict, "Width", &w)
                        _ = CGPDFDictionaryGetInteger(dict, "Height", &h)
                        let cs = PDFDocumentInspector.extractColorSpaceName(from: dict)
                        let filter = PDFDocumentInspector.extractFilterName(from: dict)
                        var smaskStream: CGPDFStreamRef?
                        let hasSMask = CGPDFDictionaryGetStream(dict, "SMask", &smaskStream)
                        if hasSMask { v.acc.hasTransparency = true }
                        v.acc.colorSpaces.insert(cs)
                        v.acc.images.append(PDFImageAssetInfo(
                            pageNumber: v.page,
                            width: w,
                            height: h,
                            colorSpace: cs,
                            compressionFilter: filter,
                            hasSoftMask: hasSMask
                        ))
                    }
                }, ctx.toOpaque())
                ctx.release()
            }
        }

        let fontList = acc.fontPages.map { key, pages in
            PDFFontInfo(
                name: key.name,
                subtype: key.subtype,
                isEmbedded: key.isEmbedded,
                hasToUnicode: key.hasToUnicode,
                pageNumbers: pages.sorted()
            )
        }.sorted { $0.name < $1.name }

        return (fontList, acc.images, acc.hasTransparency, acc.hasJavaScript, acc.colorSpaces, acc.signatureFields, acc.signatures)
    }

    private final class FontVisitContext {
        let page: Int
        let acc: ResourceScanAccumulator
        init(page: Int, acc: ResourceScanAccumulator) {
            self.page = page
            self.acc = acc
        }
    }

    private static func inspectFontDictionary(_ fDict: CGPDFDictionaryRef, page: Int, acc: ResourceScanAccumulator) {
        var baseNamePtr: UnsafePointer<Int8>?
        let rawName = CGPDFDictionaryGetName(fDict, "BaseFont", &baseNamePtr) && baseNamePtr != nil
            ? String(cString: baseNamePtr!)
            : "UnnamedFont"
        let cleanName = rawName

        var subPtr: UnsafePointer<Int8>?
        let subtype = CGPDFDictionaryGetName(fDict, "Subtype", &subPtr) && subPtr != nil
            ? String(cString: subPtr!)
            : "Unknown"

        var isEmbedded = false
        var descDict: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(fDict, "FontDescriptor", &descDict), let descDict {
            isEmbedded = descriptorHasEmbeddedFontFile(descDict)
        } else if subtype == "Type0" {
            // Check DescendantFonts[0] -> FontDescriptor -> FontFile*
            var descArr: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(fDict, "DescendantFonts", &descArr), let descArr,
               CGPDFArrayGetCount(descArr) > 0 {
                var cidDict: CGPDFDictionaryRef?
                if CGPDFArrayGetDictionary(descArr, 0, &cidDict), let cidDict {
                    var cidDesc: CGPDFDictionaryRef?
                    if CGPDFDictionaryGetDictionary(cidDict, "FontDescriptor", &cidDesc), let cidDesc {
                        isEmbedded = descriptorHasEmbeddedFontFile(cidDesc)
                    }
                }
            }
        } else if subtype == "Type3" {
            isEmbedded = true // Type3 glyphs are defined inline via CharProcs
        }

        var toUnicodeStream: CGPDFStreamRef?
        let hasToUnicode = CGPDFDictionaryGetStream(fDict, "ToUnicode", &toUnicodeStream)
            || subtype == "Type3"

        let key = ResourceScanAccumulator.FontKey(name: cleanName, subtype: subtype, isEmbedded: isEmbedded, hasToUnicode: hasToUnicode)
        acc.fontPages[key, default: []].insert(page)
    }

    private static func dictionaryContainsJSAction(_ dict: CGPDFDictionaryRef) -> Bool {
        var sPtr: UnsafePointer<Int8>?
        if CGPDFDictionaryGetName(dict, "S", &sPtr), let sPtr, String(cString: sPtr) == "JavaScript" {
            return true
        }
        var jsObj: CGPDFObjectRef?
        if CGPDFDictionaryGetObject(dict, "JS", &jsObj) { return true }
        var openActionDict: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(dict, "OpenAction", &openActionDict), let openActionDict {
            if dictionaryContainsJSAction(openActionDict) { return true }
        }
        var actionDict: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(dict, "A", &actionDict), let actionDict {
            if dictionaryContainsJSAction(actionDict) { return true }
        }
        var aaDict: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(dict, "AA", &aaDict), let aaDict {
            var hasChildJS = false
            let box = JSFlagBox()
            let ptr = Unmanaged.passRetained(box)
            CGPDFDictionaryApplyFunction(aaDict, { _, obj, info in
                guard let info else { return }
                let b = Unmanaged<JSFlagBox>.fromOpaque(info).takeUnretainedValue()
                var subDict: CGPDFDictionaryRef?
                if CGPDFObjectGetValue(obj, .dictionary, &subDict), let subDict {
                    if PDFDocumentInspector.dictionaryContainsJSAction(subDict) { b.found = true }
                }
            }, ptr.toOpaque())
            ptr.release()
            hasChildJS = box.found
            if hasChildJS { return true }
        }
        return false
    }

    private final class JSFlagBox { var found = false }

    private static func collectEmbeddedFileNames(from dict: CGPDFDictionaryRef) -> [String] {
        var results: [String] = []
        var namesArr: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dict, "Names", &namesArr), let namesArr {
            let count = CGPDFArrayGetCount(namesArr)
            var idx = 0
            while idx < count {
                var str: CGPDFStringRef?
                if CGPDFArrayGetString(namesArr, idx, &str), let str,
                   let cfStr = CGPDFStringCopyTextString(str) {
                    results.append(cfStr as String)
                }
                idx += 2
            }
        }
        var kidsArr: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dict, "Kids", &kidsArr), let kidsArr {
            for i in 0..<CGPDFArrayGetCount(kidsArr) {
                var childDict: CGPDFDictionaryRef?
                if CGPDFArrayGetDictionary(kidsArr, i, &childDict), let childDict {
                    results.append(contentsOf: collectEmbeddedFileNames(from: childDict))
                }
            }
        }
        return results
    }

    private static func inspectSignatureFieldDictionary(
        _ fieldDict: CGPDFDictionaryRef,
        pageNumber: Int?,
        fileURL: URL,
        fileSize: Int64
    ) -> PDFDigitalSignatureInfo? {
        var ftName: UnsafePointer<Int8>?
        guard CGPDFDictionaryGetName(fieldDict, "FT", &ftName), let ftName,
              String(cString: ftName) == "Sig" else {
            return nil
        }

        var tStr: CGPDFStringRef?
        let fieldTitle: String
        if CGPDFDictionaryGetString(fieldDict, "T", &tStr), let tStr,
           let cfStr = CGPDFStringCopyTextString(tStr) {
            fieldTitle = cfStr as String
        } else {
            fieldTitle = pageNumber.map { "DigitalSignature_p\($0)" } ?? "DigitalSignature"
        }

        var vDict: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(fieldDict, "V", &vDict), let vDict else {
            return PDFDigitalSignatureInfo(
                fieldName: fieldTitle,
                pageNumber: pageNumber,
                filter: nil,
                subFilter: nil,
                signerName: nil,
                signingDateRaw: nil,
                reason: nil,
                location: nil,
                byteRange: nil,
                coversEntireFile: nil,
                cmsCertificateCount: 0,
                certificateSubjects: [],
                certificateIssuers: [],
                cryptographicStatusNote: "Unsigned signature form field (no /V signature value)."
            )
        }

        func readName(_ key: String) -> String? {
            var p: UnsafePointer<Int8>?
            return CGPDFDictionaryGetName(vDict, key, &p) && p != nil ? String(cString: p!) : nil
        }
        func readText(_ key: String) -> String? {
            var s: CGPDFStringRef?
            guard CGPDFDictionaryGetString(vDict, key, &s), let s,
                  let cf = CGPDFStringCopyTextString(s) else { return nil }
            return cf as String
        }

        let filter = readName("Filter")
        let subFilter = readName("SubFilter")
        let signerName = readText("Name")
        let signingDate = readText("M")
        let reason = readText("Reason")
        let location = readText("Location")

        var byteRangeVals: [Int]? = nil
        var coversEOF: Bool? = nil
        var validByteRangeSlice: Data? = nil
        var brArr: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(vDict, "ByteRange", &brArr), let brArr,
           CGPDFArrayGetCount(brArr) == 4 {
            var vals: [Int] = []
            for idx in 0..<4 {
                var num: CGPDFInteger = 0
                if CGPDFArrayGetInteger(brArr, idx, &num) {
                    vals.append(Int(num))
                }
            }
            if vals.count == 4 {
                byteRangeVals = vals
                let o1 = vals[0], l1 = vals[1], o2 = vals[2], l2 = vals[3]
                if o1 >= 0 && l1 >= 0 && o2 >= o1 + l1 && l2 >= 0
                    && Int64(o1 + l1) <= fileSize && Int64(o2 + l2) <= fileSize {
                    coversEOF = (o1 == 0) && (Int64(o2 + l2) == fileSize)
                    if let fh = try? FileHandle(forReadingFrom: fileURL) {
                        defer { try? fh.close() }
                        try? fh.seek(toOffset: UInt64(o1))
                        let d1 = (try? fh.read(upToCount: l1)) ?? Data()
                        try? fh.seek(toOffset: UInt64(o2))
                        let d2 = (try? fh.read(upToCount: l2)) ?? Data()
                        if d1.count == l1 && d2.count == l2 {
                            validByteRangeSlice = d1 + d2
                        }
                    }
                } else {
                    coversEOF = false
                }
            }
        }

        // 1. Parse CMS / PKCS#7 & 2. Verify cryptographic digest against /ByteRange + 3. Check certificate validity & system trust
        var certCount = 0
        var subjects: [String] = []
        var issuers: [String] = []
        var cmsDecoded = false
        var numSigners = 0
        var cryptoStatus: PDFSignatureCryptoStatus = .malformedCMS
        var trustChainStatus = "Not evaluated"
        var isExpired: Bool? = nil

        let isCMSSubFilter = subFilter == nil
            || subFilter == "adbe.pkcs7.detached"
            || subFilter == "ETSI.CAdES.detached"
            || subFilter == "adbe.pkcs7.sha1"

        var contentsStr: CGPDFStringRef?
        if !isCMSSubFilter {
            cryptoStatus = .unsupportedSubFilter
            trustChainStatus = "Unsupported signature handler (\(subFilter ?? "unknown"))"
        } else if CGPDFDictionaryGetString(vDict, "Contents", &contentsStr), let contentsStr,
                  let bytePtr = CGPDFStringGetBytePtr(contentsStr) {
            let len = CGPDFStringGetLength(contentsStr)
            if len > 8 {
                let rawBytes = Data(bytes: bytePtr, count: len)
                // Trim zero-padding appended inside fixed-width PDF /Contents hex slots when ASN.1 SEQUENCE has explicit length
                let trimmedCMS = trimDERZeroPadding(rawBytes)
                var decoder: CMSDecoder?
                if CMSDecoderCreate(&decoder) == errSecSuccess, let decoder {
                    if subFilter != "adbe.pkcs7.sha1", let signedContent = validByteRangeSlice {
                        _ = CMSDecoderSetDetachedContent(decoder, signedContent as CFData)
                    }
                    let upd = trimmedCMS.withUnsafeBytes { buf -> OSStatus in
                        guard let base = buf.baseAddress else { return errSecParam }
                        return CMSDecoderUpdateMessage(decoder, base, trimmedCMS.count)
                    }
                    if upd == errSecSuccess && CMSDecoderFinalizeMessage(decoder) == errSecSuccess {
                        cmsDecoded = true
                        var countOut: Int = 0
                        if CMSDecoderGetNumSigners(decoder, &countOut) == errSecSuccess {
                            numSigners = countOut
                        }
                        var certsCF: CFArray?
                        if CMSDecoderCopyAllCerts(decoder, &certsCF) == errSecSuccess,
                           let certs = certsCF as? [SecCertificate] {
                            certCount = certs.count
                            let now = Date()
                            var anyExpired = false
                            var sawValidity = false
                            for cert in certs {
                                if let summary = SecCertificateCopySubjectSummary(cert) as String?, !summary.isEmpty {
                                    subjects.append(summary)
                                }
                                if let vals = SecCertificateCopyValues(cert, [kSecOIDX509V1IssuerName, kSecOIDX509V1ValidityNotAfter] as CFArray, nil) as? [CFString: Any] {
                                    if let entry = vals[kSecOIDX509V1IssuerName] as? [CFString: Any],
                                       let label = entry[kSecPropertyKeyValue] {
                                        issuers.append(String(describing: label))
                                    }
                                    if let expEntry = vals[kSecOIDX509V1ValidityNotAfter] as? [CFString: Any],
                                       let expSec = expEntry[kSecPropertyKeyValue] as? NSNumber {
                                        sawValidity = true
                                        // kSecPropertyKeyValue uses CFAbsoluteTime (seconds since 2001-01-01)
                                        let expDate = Date(timeIntervalSinceReferenceDate: expSec.doubleValue)
                                        if expDate < now { anyExpired = true }
                                    }
                                }
                            }
                            if sawValidity { isExpired = anyExpired }
                        }

                        if subFilter == "adbe.pkcs7.sha1" {
                            cryptoStatus = .validDigest
                            trustChainStatus = "Encapsulated PKCS#7 SHA-1 parsed (not detached ByteRange)"
                        } else if validByteRangeSlice != nil && numSigners > 0 {
                            let policy = SecPolicyCreateBasicX509()
                            var signerStatus: CMSSignerStatus = .unsigned
                            var secTrust: SecTrust?
                            var verifyOS: OSStatus = errSecSuccess
                            let st = CMSDecoderCopySignerStatus(decoder, 0, policy, true, &signerStatus, &secTrust, &verifyOS)
                            if st == errSecSuccess {
                                switch signerStatus {
                                case .valid, .invalidCert:
                                    // Per Security.framework CMSDecoderCopySignerStatus: `.invalidCert` verifies the signature digest cleanly while reporting trust failure via SecTrust.
                                    cryptoStatus = .validDigest
                                case .invalidSignature:
                                    cryptoStatus = .invalidDigest
                                case .needsDetachedContent:
                                    cryptoStatus = .malformedCMS
                                default:
                                    cryptoStatus = .invalidDigest
                                }
                                if let secTrust {
                                    var trustErr: CFError?
                                    let trusted = SecTrustEvaluateWithError(secTrust, &trustErr)
                                    if isExpired == true {
                                        trustChainStatus = trusted
                                            ? "Expired certificate (trusted root)"
                                            : "Untrusted / Self-Signed & Expired"
                                    } else {
                                        trustChainStatus = trusted
                                            ? "Trusted by macOS system trust store"
                                            : "Untrusted / Self-Signed or Unknown CA"
                                    }
                                }
                            }
                        } else {
                            cryptoStatus = .malformedCMS
                            trustChainStatus = "Missing ByteRange bytes for detached digest check"
                        }
                    }
                }
            }
        }

        var statusParts: [String] = []
        if let coversEOF {
            statusParts.append(coversEOF
                ? "ByteRange covers full file to EOF (no trailing incremental changes)."
                : "ByteRange does not cover entire file (incremental updates or modifications appended after signing).")
        }
        statusParts.append(cmsDecoded
            ? "CMS DER parsed (\(numSigners) signer(s), \(certCount) cert(s))."
            : "Raw /Contents could not be parsed as CMS DER.")
        statusParts.append("Crypto: \(cryptoStatus.rawValue). Trust: \(trustChainStatus). CRL/OCSP revocation not checked offline.")

        return PDFDigitalSignatureInfo(
            fieldName: fieldTitle,
            pageNumber: pageNumber,
            filter: filter,
            subFilter: subFilter,
            signerName: signerName,
            signingDateRaw: signingDate,
            reason: reason,
            location: location,
            byteRange: byteRangeVals,
            coversEntireFile: coversEOF,
            cmsCertificateCount: certCount,
            certificateSubjects: subjects,
            certificateIssuers: issuers,
            cryptographicStatusNote: statusParts.joined(separator: " "),
            cmsParsed: cmsDecoded,
            cryptoStatus: cryptoStatus,
            trustChainStatus: trustChainStatus,
            isCertificateExpired: isExpired,
            revocationStatus: "Not checked offline (CRL/OCSP revocation not performed)"
        )
    }

    private static func trimDERZeroPadding(_ data: Data) -> Data {
        guard data.count >= 4, data[data.startIndex] == 0x30 else { return data }
        let lenByte = data[data.index(after: data.startIndex)]
        if lenByte < 0x80 {
            let total = 2 + Int(lenByte)
            return total <= data.count ? Data(data.prefix(total)) : data
        } else if lenByte == 0x81, data.count >= 3 {
            let total = 3 + Int(data[data.index(data.startIndex, offsetBy: 2)])
            return total <= data.count ? Data(data.prefix(total)) : data
        } else if lenByte == 0x82, data.count >= 4 {
            let b2 = Int(data[data.index(data.startIndex, offsetBy: 2)])
            let b3 = Int(data[data.index(data.startIndex, offsetBy: 3)])
            let total = 4 + (b2 << 8 | b3)
            return total <= data.count ? Data(data.prefix(total)) : data
        }
        return data
    }

    private static func descriptorHasEmbeddedFontFile(_ descDict: CGPDFDictionaryRef) -> Bool {
        var s: CGPDFStreamRef?
        return CGPDFDictionaryGetStream(descDict, "FontFile", &s)
            || CGPDFDictionaryGetStream(descDict, "FontFile2", &s)
            || CGPDFDictionaryGetStream(descDict, "FontFile3", &s)
    }

    private static func extractColorSpaceName(from imageDict: CGPDFDictionaryRef) -> String {
        var namePtr: UnsafePointer<Int8>?
        if CGPDFDictionaryGetName(imageDict, "ColorSpace", &namePtr), let namePtr {
            return String(cString: namePtr)
        }
        var csArr: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(imageDict, "ColorSpace", &csArr), let csArr,
           CGPDFArrayGetCount(csArr) > 0 {
            var arrNamePtr: UnsafePointer<Int8>?
            if CGPDFArrayGetName(csArr, 0, &arrNamePtr), let arrNamePtr {
                return String(cString: arrNamePtr)
            }
        }
        return "Unknown"
    }

    private static func extractFilterName(from imageDict: CGPDFDictionaryRef) -> String {
        var namePtr: UnsafePointer<Int8>?
        if CGPDFDictionaryGetName(imageDict, "Filter", &namePtr), let namePtr {
            return humanFilterName(String(cString: namePtr))
        }
        var arr: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(imageDict, "Filter", &arr), let arr {
            var names: [String] = []
            for idx in 0..<CGPDFArrayGetCount(arr) {
                var p: UnsafePointer<Int8>?
                if CGPDFArrayGetName(arr, idx, &p), let p {
                    names.append(humanFilterName(String(cString: p)))
                }
            }
            if !names.isEmpty { return names.joined(separator: ", ") }
        }
        return "Raw / Uncompressed"
    }

    private static func humanFilterName(_ raw: String) -> String {
        switch raw {
        case "DCTDecode": return "JPEG (DCTDecode)"
        case "JPXDecode": return "JPEG 2000 (JPXDecode)"
        case "FlateDecode": return "Flate / Zlib"
        case "CCITTFaxDecode": return "CCITT Fax"
        case "JBIG2Decode": return "JBIG2"
        default: return raw
        }
    }
}
