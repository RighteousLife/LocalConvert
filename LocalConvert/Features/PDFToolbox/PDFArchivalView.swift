import SwiftUI

struct PDFArchivalView: View {
    let selectedFiles: [DroppedFile]
    @Binding var password: String
    let onConvertPDFA: (PDFAProfile) -> Void

    @State private var selectedProfile: PDFAProfile = .pdfa2b
    @State private var validationReport: PDFAValidationReport? = nil
    @State private var validationError: String? = nil
    @State private var isValidating: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            AppCard(title: "Archival Conformance Profile", icon: "archivebox") {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    Picker("Target Profile", selection: $selectedProfile) {
                        ForEach(PDFAProfile.allCases) { profile in
                            HStack {
                                Text(profile.rawValue)
                                if !profile.isGenerationSupported {
                                    Text("(Unsupported for Generation)")
                                }
                            }
                            .tag(profile)
                        }
                    }
                    .frame(maxWidth: 340)

                    Text("Standard: \(selectedProfile.isoStandard)")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)

                    if let note = selectedProfile.limitationNote {
                        AppInfoBanner(
                            style: selectedProfile.isGenerationSupported ? .info : .warning,
                            message: note
                        )
                    }
                }
            }

            AppCard(title: "PDF/A Compliance Validator", icon: "checkmark.shield") {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    HStack {
                        Button {
                            validateSelectedFile()
                        } label: {
                            Label(isValidating ? "Validating..." : "Validate Current PDF Against \(selectedProfile.rawValue)", systemImage: "checkmark.shield")
                        }
                        .disabled(selectedFiles.count != 1 || isValidating)

                        Spacer()
                    }

                    if let validationError {
                        AppInfoBanner(style: .error, message: validationError)
                    } else if let report = validationReport {
                        HStack(spacing: AppTheme.Spacing.xs) {
                            Image(systemName: report.isCompliant ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(report.isCompliant ? AppTheme.Colors.success : AppTheme.Colors.error)
                            Text(report.isCompliant ? "Passed checks for \(report.profile.rawValue)" : "Failed \(report.failedRequirements.count) requirement(s) for \(report.profile.rawValue)")
                                .font(AppTheme.Typography.subheadline)
                                .fontWeight(.semibold)
                            Spacer()
                            AppStatusBadge(
                                text: report.isCompliant ? "COMPLIANT" : "NON-COMPLIANT",
                                tint: report.isCompliant ? AppTheme.Colors.success : AppTheme.Colors.error
                            )
                        }

                        ForEach(report.checks) { check in
                            HStack(alignment: .top, spacing: AppTheme.Spacing.xs) {
                                Image(systemName: check.passed ? "checkmark" : "xmark")
                                    .foregroundStyle(check.passed ? AppTheme.Colors.success : AppTheme.Colors.error)
                                    .font(AppTheme.Typography.caption)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(check.requirement)
                                        .font(AppTheme.Typography.caption)
                                        .fontWeight(.medium)
                                    Text(check.detail)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    if let obj = check.objectPath, !obj.isEmpty {
                                        Text("Object: \(obj)")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }

                        AppInfoBanner(style: .info, message: report.validationScopeNote)

                        ForEach(report.warnings, id: \.self) { warn in
                            AppInfoBanner(style: .warning, message: warn)
                        }
                    }
                }
            }

            HStack(spacing: AppTheme.Spacing.md) {
                Text("Uses bundled LibreOffice archival PDF export (embedded fonts, ICC OutputIntents, XMP pdfaid) followed by structural validation.")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    onConvertPDFA(selectedProfile)
                } label: {
                    Label("Convert to \(selectedProfile.rawValue)", systemImage: "archivebox.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(selectedFiles.isEmpty || !selectedProfile.isGenerationSupported)
            }
        }
    }

    private func validateSelectedFile() {
        guard let file = selectedFiles.first else { return }
        isValidating = true
        validationError = nil
        let profile = selectedProfile
        let pwd = password.isEmpty ? nil : password
        Task.detached {
            do {
                let res = try PDFDocumentInspector.validatePDFA(url: file.url, expectedProfile: profile, password: pwd)
                await MainActor.run {
                    validationReport = res
                    isValidating = false
                }
            } catch {
                await MainActor.run {
                    validationError = error.localizedDescription
                    isValidating = false
                }
            }
        }
    }
}
