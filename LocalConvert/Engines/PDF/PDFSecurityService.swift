import Foundation
import PDFKit
import CoreGraphics

// MARK: - PDF Security Service (Encryption, Decryption, Granular Permissions)

enum PDFSecurityService {

    struct SecurityResult: Sendable {
        let outputURL: URL
        let isEncrypted: Bool
        let signaturesInvalidated: Bool
        let summary: String
    }

    static func applySecurity(
        inputURL: URL,
        outputURL: URL,
        options: PDFSecurityOptions
    ) throws -> SecurityResult {
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw ConversionError.inputFileNotFound(inputURL)
        }
        guard inputURL.standardizedFileURL != outputURL.standardizedFileURL else {
            throw ConversionError.invalidInput("Security operations never overwrite the source PDF directly.")
        }

        guard let doc = PDFDocument(url: inputURL) else {
            throw ConversionError.invalidInput("Unable to open PDF '\(inputURL.lastPathComponent)'.")
        }

        if doc.isLocked {
            guard !options.currentPassword.isEmpty, doc.unlock(withPassword: options.currentPassword) else {
                throw ConversionError.invalidInput("Incorrect or missing current password for '\(inputURL.lastPathComponent)'.")
            }
        } else if doc.isEncrypted && !options.currentPassword.isEmpty {
            // Attempt owner password unlock when already readable with empty user password so owner permissions/decrypt succeed
            _ = doc.unlock(withPassword: options.currentPassword)
        }

        let report = try? PDFDocumentInspector.inspect(
            url: inputURL,
            password: options.currentPassword.isEmpty ? nil : options.currentPassword
        )
        let hadSignatures = report?.hasDigitalSignatures ?? false

        if let cipher = report?.encryptionCipherSummary,
           cipher.contains("Certificate / Public-Key") {
            throw ConversionError.engineExecutionFailed(
                "Unsupported encryption algorithm: certificate/public-key PDF security handlers cannot be decrypted or modified with a password.",
                underlyingError: cipher
            )
        }

        let tempOut = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-Sec-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tempOut) }

        switch options.mode {
        case .decrypt:
            if doc.isEncrypted && doc.permissionsStatus != .owner {
                throw ConversionError.engineExecutionFailed(
                    "Password removal requires the owner password when owner permissions are set.",
                    underlyingError: nil
                )
            }
            // PDFDocument.write(to:) retains existing /Encrypt trailer dictionaries when called on an originally encrypted document.
            // Copy unlocked pages and metadata into a clean PDFDocument so encryption metadata is genuinely stripped.
            let freshDoc = PDFDocument()
            for idx in 0..<doc.pageCount {
                if let page = doc.page(at: idx) {
                    freshDoc.insert(page, at: freshDoc.pageCount)
                }
            }
            if let attrs = doc.documentAttributes {
                freshDoc.documentAttributes = attrs
            }
            guard freshDoc.write(to: tempOut) else {
                throw ConversionError.engineExecutionFailed("Failed to save unlocked PDF.", underlyingError: nil)
            }
            guard let verify = PDFDocument(url: tempOut), !verify.isLocked, !verify.isEncrypted else {
                throw ConversionError.engineExecutionFailed(
                    "Password removal requires the owner password when owner restrictions are set.",
                    underlyingError: nil
                )
            }
            _ = try OutputReservationCoordinator.moveOrReplaceTempFile(tempOut, to: outputURL, policy: .overwrite)

            return SecurityResult(
                outputURL: outputURL,
                isEncrypted: false,
                signaturesInvalidated: hadSignatures,
                summary: "Encryption and password restrictions removed."
            )

        case .encrypt:
            let effectiveOwner = options.ownerPassword.isEmpty ? options.userPassword : options.ownerPassword
            guard !effectiveOwner.isEmpty else {
                throw ConversionError.invalidInput("Specify at least a User Password or an Owner Password to encrypt the PDF.")
            }

            let perms = options.makeCGPermissions()
            var writeOptions: [PDFDocumentWriteOption: Any] = [
                .ownerPasswordOption: effectiveOwner,
                .accessPermissionsOption: perms.rawValue
            ]
            if !options.userPassword.isEmpty {
                writeOptions[.userPasswordOption] = options.userPassword
            }

            guard doc.write(to: tempOut, withOptions: writeOptions) else {
                throw ConversionError.engineExecutionFailed("Failed to encrypt PDF document.", underlyingError: nil)
            }

            guard let verify = PDFDocument(url: tempOut), verify.isEncrypted else {
                throw ConversionError.engineExecutionFailed("Encrypted PDF failed security verification.", underlyingError: nil)
            }

            _ = try OutputReservationCoordinator.moveOrReplaceTempFile(tempOut, to: outputURL, policy: .overwrite)

            let permSummary = [
                options.allowHighQualityPrinting ? "High-DPI Print" : (options.allowPrinting ? "Low-DPI Print" : "No Print"),
                options.allowCopying ? "Copy Allowed" : "Copy Restricted",
                options.allowDocumentChanges ? "Edit Allowed" : "Edit Restricted"
            ].joined(separator: ", ")

            return SecurityResult(
                outputURL: outputURL,
                isEncrypted: true,
                signaturesInvalidated: hadSignatures,
                summary: "Encrypted (\(permSummary)). Note: PDF permissions rely on compliant viewers and do not guarantee prevention of third-party extraction once opened."
            )
        }
    }
}
