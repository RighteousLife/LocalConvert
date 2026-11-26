import Foundation

struct PDFPageNormalizationRequest: Codable, Equatable, Sendable {
    static let optionKey = "pdf_normalization_request"

    let target: PDFPageSizeTarget

    init(target: PDFPageSizeTarget) {
        self.target = target
    }

    func encodedOption() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let value = String(data: data, encoding: .utf8) else {
            throw ConversionError.invalidInput("The normalization settings could not be encoded.")
        }
        return value
    }

    static func decode(from options: [String: String]) throws -> Self {
        guard let rawValue = options[optionKey], let data = rawValue.data(using: .utf8) else {
            throw ConversionError.invalidInput("Missing PDF page-size normalization settings.")
        }
        do {
            return try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw ConversionError.invalidInput("The PDF page-size normalization settings are invalid.")
        }
    }
}

struct PDFNormalizationDetectedFeature: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let detail: String
}

struct PDFNormalizationPreflight: Equatable, Sendable {
    let detectedFeatures: [PDFNormalizationDetectedFeature]

    var requiresConfirmation: Bool { !detectedFeatures.isEmpty }

    static func assess(_ report: PDFDocumentInspectionReport) -> Self {
        var features: [PDFNormalizationDetectedFeature] = []
        let annotationTypes = Set(report.annotationTypes.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) })

        if annotationTypes.contains("link") {
            features.append(.init(
                id: "links",
                title: "Hyperlinks and link annotations",
                detail: "Link annotations may not remain interactive after page appearance is rewritten."
            ))
        }
        if report.hasAcroForm || report.hasXFA {
            features.append(.init(
                id: "forms",
                title: "Interactive forms",
                detail: report.hasXFA ? "AcroForm/XFA form data may not be preserved." : "AcroForm fields and their interactive behavior may not be preserved."
            ))
        }
        if report.hasJavaScriptActions {
            features.append(.init(id: "javascript", title: "Document JavaScript", detail: "JavaScript actions may not be preserved."))
        }
        if report.hasEmbeddedFiles || report.hasAssociatedFiles {
            features.append(.init(id: "attachments", title: "Embedded attachments", detail: "Embedded or associated files may not be preserved."))
        }
        if report.hasOptionalContentLayers {
            features.append(.init(id: "layers", title: "Optional-content layers", detail: "Layer controls and hidden-content behavior may not be preserved."))
        }
        if report.hasStructureTree {
            features.append(.init(id: "tagged-pdf", title: "Tagged PDF structure", detail: "Accessibility tags and reading structure may not be preserved."))
        }
        if report.hasDigitalSignatures || !report.signatureFieldNames.isEmpty {
            features.append(.init(
                id: "signatures",
                title: "Digital signatures or signature fields",
                detail: "Rewriting a digitally signed PDF invalidates its existing digital signatures; signature fields may also be lost."
            ))
        }

        return Self(detectedFeatures: features)
    }

    /// A queue submission is permitted only after explicit acknowledgement when inspection found risky structures.
    func permitsSubmission(afterExplicitConfirmation confirmed: Bool) -> Bool {
        !requiresConfirmation || confirmed
    }

    @discardableResult
    func submit(afterExplicitConfirmation confirmed: Bool, enqueue: () -> Void) -> Bool {
        guard permitsSubmission(afterExplicitConfirmation: confirmed) else { return false }
        enqueue()
        return true
    }
}
