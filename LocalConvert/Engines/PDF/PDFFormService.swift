import Foundation
import PDFKit
import CoreGraphics

// MARK: - PDF AcroForm Service (XFA Explicitly Distinguished)

enum PDFFormService {

    struct FormWriteResult: Sendable {
        let outputURL: URL
        let updatedFieldCount: Int
        let flattened: Bool
    }

    static func inspectForms(url: URL, password: String? = nil) throws -> PDFFormInspection {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConversionError.inputFileNotFound(url)
        }
        guard let doc = PDFDocument(url: url) else {
            throw ConversionError.invalidInput("Unable to open PDF '\(url.lastPathComponent)'.")
        }
        if doc.isLocked {
            guard let pwd = password, !pwd.isEmpty, doc.unlock(withPassword: pwd) else {
                throw ConversionError.invalidInput("PDF '\(url.lastPathComponent)' is password-protected.")
            }
        }

        let report = try PDFDocumentInspector.inspect(url: url, password: password)
        var fields: [PDFFormFieldItem] = []

        for pageIndex in 0..<doc.pageCount {
            guard let page = doc.page(at: pageIndex) else { continue }
            for (annIdx, ann) in page.annotations.enumerated() {
                let isWidget = (ann.type ?? "") == "/Widget"
                    || ann.type == "Widget"
                    || ann.fieldName != nil
                    || [PDFAnnotationWidgetSubtype.text, .button, .choice, .signature].contains(ann.widgetFieldType)
                guard isWidget else {
                    continue
                }
                let kind: PDFFormFieldKind
                switch ann.widgetFieldType {
                case .text: kind = .text
                case .button:
                    switch ann.widgetControlType {
                    case .checkBoxControl: kind = .checkbox
                    case .radioButtonControl: kind = .radio
                    case .pushButtonControl: kind = .pushButton
                    default: kind = .checkbox
                    }
                case .choice: kind = .choice
                case .signature: kind = .signature
                default: kind = .unknown
                }

                let name = ann.fieldName ?? "Field_p\(pageIndex + 1)_\(annIdx + 1)"
                let item = PDFFormFieldItem(
                    id: "\(pageIndex)::\(annIdx)::\(name)",
                    pageIndex: pageIndex,
                    fieldName: name,
                    kind: kind,
                    stringValue: ann.widgetStringValue ?? "",
                    boolValue: (ann.buttonWidgetState == .onState),
                    choices: ann.choices ?? [],
                    isReadOnly: ann.isReadOnly,
                    bounds: ann.bounds
                )
                fields.append(item)
            }
        }

        let hasAcro = report.hasAcroForm || !fields.isEmpty
        let xfaNote: String? = report.hasXFA
            ? "Dynamic XFA (/XFA) stream detected in AcroForm dictionary. macOS PDFKit only inspects and edits static AcroForm widgets; XFA scripts and dynamic templates are unsupported and left read-only."
            : nil
        let jsNote: String? = report.hasJavaScriptActions
            ? "Embedded AcroForm / annotation JavaScript actions detected; form calculation or validation scripts are not executed during offline editing."
            : nil

        return PDFFormInspection(
            hasAcroForm: hasAcro,
            hasXFA: report.hasXFA,
            xfaNote: xfaNote,
            hasJavaScriptActions: report.hasJavaScriptActions,
            javaScriptNote: jsNote,
            fields: fields
        )
    }

    static func applyAndSave(
        inputURL: URL,
        outputURL: URL,
        editedFields: [PDFFormFieldItem],
        flatten: Bool,
        password: String? = nil
    ) throws -> FormWriteResult {
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw ConversionError.inputFileNotFound(inputURL)
        }
        guard inputURL.standardizedFileURL != outputURL.standardizedFileURL else {
            throw ConversionError.invalidInput("Form save never overwrites the source PDF directly.")
        }

        guard let doc = PDFDocument(url: inputURL) else {
            throw ConversionError.invalidInput("Unable to open PDF '\(inputURL.lastPathComponent)'.")
        }
        if doc.isLocked {
            guard let pwd = password, !pwd.isEmpty, doc.unlock(withPassword: pwd) else {
                throw ConversionError.invalidInput("PDF '\(inputURL.lastPathComponent)' is password-protected.")
            }
        }

        var lookupByID: [String: PDFFormFieldItem] = [:]
        var lookupByName: [String: PDFFormFieldItem] = [:]
        var selectedRadioIDByGroup: [String: String] = [:]
        for f in editedFields {
            lookupByID[f.id] = f
            lookupByName[f.fieldName] = f
            if f.kind == .radio && f.boolValue {
                selectedRadioIDByGroup[f.fieldName] = f.id
            }
        }

        var updatedCount = 0
        for pageIndex in 0..<doc.pageCount {
            guard let page = doc.page(at: pageIndex) else { continue }
            for (annIdx, ann) in page.annotations.enumerated() {
                let isWidget = (ann.type ?? "") == "/Widget"
                    || ann.type == "Widget"
                    || ann.fieldName != nil
                    || [PDFAnnotationWidgetSubtype.text, .button, .choice, .signature].contains(ann.widgetFieldType)
                guard isWidget else {
                    continue
                }
                let name = ann.fieldName ?? "Field_p\(pageIndex + 1)_\(annIdx + 1)"
                let id = "\(pageIndex)::\(annIdx)::\(name)"
                guard let edited = lookupByID[id] ?? lookupByName[name] else { continue }
                guard !ann.isReadOnly else { continue }

                switch edited.kind {
                case .text, .choice:
                    ann.widgetStringValue = edited.stringValue
                    ann.shouldDisplay = true
                    updatedCount += 1
                case .checkbox:
                    ann.buttonWidgetState = edited.boolValue ? .onState : .offState
                    ann.shouldDisplay = true
                    updatedCount += 1
                case .radio:
                    if let winnerID = selectedRadioIDByGroup[name] {
                        ann.buttonWidgetState = (id == winnerID) ? .onState : .offState
                    } else {
                        ann.buttonWidgetState = edited.boolValue ? .onState : .offState
                    }
                    ann.shouldDisplay = true
                    updatedCount += 1
                default:
                    break
                }
            }
        }

        let tempOut = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-Form-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tempOut) }

        let ok: Bool
        if flatten {
            ok = doc.write(to: tempOut, withOptions: [.burnInAnnotationsOption: true])
        } else {
            ok = doc.write(to: tempOut)
        }
        guard ok, PDFDocument(url: tempOut)?.pageCount == doc.pageCount else {
            throw ConversionError.engineExecutionFailed("Failed to save \(flatten ? "flattened " : "")PDF form.", underlyingError: nil)
        }

        _ = try OutputReservationCoordinator.moveOrReplaceTempFile(tempOut, to: outputURL, policy: .overwrite)

        return FormWriteResult(outputURL: outputURL, updatedFieldCount: updatedCount, flattened: flatten)
    }

    static func resetFieldsToEmpty(_ fields: [PDFFormFieldItem]) -> [PDFFormFieldItem] {
        fields.map { item in
            guard !item.isReadOnly else { return item }
            var copy = item
            switch copy.kind {
            case .text, .choice:
                copy.stringValue = ""
            case .checkbox, .radio:
                copy.boolValue = false
            default:
                break
            }
            return copy
        }
    }

    static func exportFormDataJSON(fields: [PDFFormFieldItem], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(fields)
        try data.write(to: url, options: .atomic)
    }

    static func importFormDataJSON(from url: URL) throws -> [PDFFormFieldItem] {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([PDFFormFieldItem].self, from: data)
    }
}
