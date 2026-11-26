import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PDFFormsView: View {
    @EnvironmentObject private var appState: AppState

    let selectedFiles: [DroppedFile]
    @Binding var password: String
    let onSaveForm: ([PDFFormFieldItem], Bool) -> Void

    @State private var inspection: PDFFormInspection? = nil
    @State private var errorMessage: String? = nil
    @State private var isLoading: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            if selectedFiles.count != 1 {
                AppInfoBanner(style: .info, message: "Select a single PDF to inspect and edit AcroForm fields.")
            } else if let file = selectedFiles.first {
                let draft = appState.pdfToolboxStore.formDraft(for: file.url)

                HStack(spacing: AppTheme.Spacing.sm) {
                    Button {
                        loadFormFields(url: file.url)
                    } label: {
                        Label(isLoading ? "Scanning..." : "Scan Form Fields", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isLoading)

                    if !draft.fields.isEmpty {
                        Button("Export JSON") { exportJSON(defaultName: file.fileName, fields: draft.fields) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Button("Import JSON") { importJSON(for: file.url) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    Spacer()
                }

                if let errorMessage {
                    AppInfoBanner(style: .error, message: errorMessage)
                }

                if let inspection {
                    if inspection.hasXFA, let xfaNote = inspection.xfaNote {
                        AppInfoBanner(style: .warning, message: xfaNote)
                    }

                    if draft.fields.isEmpty {
                        AppCard(title: "Form Detection", icon: "list.bullet.rectangle") {
                            Text(inspection.hasAcroForm
                                 ? "AcroForm dictionary present, but no editable widget fields were found."
                                 : "No AcroForm fields found in this PDF document.")
                                .font(AppTheme.Typography.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        AppCard(title: "AcroForm Fields (\(draft.fields.count))", icon: "square.and.pencil") {
                            ScrollView {
                                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                                    ForEach(draft.fields) { field in
                                        ViewThatFits(in: .horizontal) {
                                            HStack(alignment: .center, spacing: AppTheme.Spacing.sm) {
                                                formFieldLabel(field)
                                                    .frame(minWidth: 160, maxWidth: 210, alignment: .leading)
                                                Spacer(minLength: AppTheme.Spacing.sm)
                                                formFieldControl(for: field, fileURL: file.url)
                                            }

                                            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                                                formFieldLabel(field)
                                                formFieldControl(for: field, fileURL: file.url)
                                            }
                                        }
                                        Divider()
                                    }
                                }
                            }
                            .frame(minHeight: 160, maxHeight: 260)
                        }

                        if let jsNote = inspection.javaScriptNote, inspection.hasJavaScriptActions {
                            AppInfoBanner(style: .warning, message: jsNote)
                        }

                        Toggle(
                            "Flatten form fields (permanently burns field values & annotations into page graphics)",
                            isOn: Binding(
                                get: { appState.pdfToolboxStore.formDraft(for: file.url).flattenFields },
                                set: { newValue in
                                    appState.pdfToolboxStore.updateFormDraft(
                                        for: file.url,
                                        title: "Toggle Flatten Form Fields"
                                    ) { draft in
                                        draft.flattenFields = newValue
                                    }
                                }
                            )
                        )

                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: AppTheme.Spacing.md) {
                                Text("Saves updated AcroForm PDF to a new file without modifying the original.")
                                    .font(AppTheme.Typography.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                formActionButtons(draft: draft, fileURL: file.url)
                            }

                            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                                Text("Saves updated AcroForm PDF to a new file without modifying the original.")
                                    .font(AppTheme.Typography.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                HStack {
                                    Spacer(minLength: 0)
                                    formActionButtons(draft: draft, fileURL: file.url)
                                }
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            if let file = selectedFiles.first {
                loadFormFields(url: file.url)
            }
        }
        .onChange(of: selectedFiles.map { $0.id }) { _, _ in
            if let file = selectedFiles.first {
                loadFormFields(url: file.url)
            } else {
                inspection = nil
            }
        }
    }

    @ViewBuilder
    private func formFieldLabel(_ field: PDFFormFieldItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(field.fieldName)
                .font(AppTheme.Typography.subheadline)
                .fontWeight(.medium)
            Text("Page \(field.pageIndex + 1) • \(field.kind.rawValue)\(field.isReadOnly ? " • Read-Only" : "")")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func formFieldControl(for field: PDFFormFieldItem, fileURL: URL) -> some View {
        switch field.kind {
        case .text:
            TextField("Value", text: textFieldBinding(for: field, url: fileURL))
                .textFieldStyle(.roundedBorder)
                .disabled(field.isReadOnly)
                .frame(maxWidth: 260)
        case .checkbox:
            Toggle(field.boolValue ? "Checked" : "Unchecked", isOn: checkboxBinding(for: field, url: fileURL))
                .disabled(field.isReadOnly)
        case .radio:
            Toggle(field.boolValue ? "Selected" : "Unselected", isOn: radioBinding(for: field, url: fileURL))
                .disabled(field.isReadOnly)
        case .choice:
            if field.choices.isEmpty {
                TextField("Selection", text: textFieldBinding(for: field, url: fileURL))
                    .textFieldStyle(.roundedBorder)
                    .disabled(field.isReadOnly)
                    .frame(maxWidth: 260)
            } else {
                Picker("", selection: choiceBinding(for: field, url: fileURL)) {
                    ForEach(field.choices, id: \.self) { opt in
                        Text(opt).tag(opt)
                    }
                }
                .disabled(field.isReadOnly)
                .frame(maxWidth: 260)
            }
        default:
            Text(field.stringValue.isEmpty ? "Non-editable widget" : field.stringValue)
                .font(AppTheme.Typography.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func formActionButtons(draft: PDFFormDraftSnapshot, fileURL: URL) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Button("Reset Fields") {
                appState.pdfToolboxStore.updateFormDraft(
                    for: fileURL,
                    title: "Reset Form Fields"
                ) { draft in
                    draft.fields = PDFFormService.resetFieldsToEmpty(draft.fields)
                }
            }
            .buttonStyle(.bordered)
            .fixedSize(horizontal: true, vertical: false)
            .disabled(draft.fields.allSatisfy(\.isReadOnly))

            Button {
                onSaveForm(draft.fields, draft.flattenFields)
            } label: {
                Label(draft.flattenFields ? "Save Flattened PDF" : "Save Filled Form PDF", systemImage: "checkmark.rectangle.stack")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func textFieldBinding(for field: PDFFormFieldItem, url: URL) -> Binding<String> {
        Binding(
            get: {
                appState.pdfToolboxStore.formDraft(for: url).fields.first(where: { $0.id == field.id })?.stringValue ?? field.stringValue
            },
            set: { newValue in
                appState.pdfToolboxStore.updateFormDraft(
                    for: url,
                    title: "Edit \(field.fieldName)",
                    coalesceKey: field.id
                ) { draft in
                    guard let idx = draft.fields.firstIndex(where: { $0.id == field.id }), !draft.fields[idx].isReadOnly else { return }
                    draft.fields[idx].stringValue = newValue
                }
            }
        )
    }

    private func checkboxBinding(for field: PDFFormFieldItem, url: URL) -> Binding<Bool> {
        Binding(
            get: {
                appState.pdfToolboxStore.formDraft(for: url).fields.first(where: { $0.id == field.id })?.boolValue ?? field.boolValue
            },
            set: { newValue in
                appState.pdfToolboxStore.updateFormDraft(
                    for: url,
                    title: "Toggle \(field.fieldName)"
                ) { draft in
                    guard let idx = draft.fields.firstIndex(where: { $0.id == field.id }), !draft.fields[idx].isReadOnly else { return }
                    draft.fields[idx].boolValue = newValue
                }
            }
        )
    }

    private func radioBinding(for field: PDFFormFieldItem, url: URL) -> Binding<Bool> {
        Binding(
            get: {
                appState.pdfToolboxStore.formDraft(for: url).fields.first(where: { $0.id == field.id })?.boolValue ?? field.boolValue
            },
            set: { newValue in
                appState.pdfToolboxStore.updateFormDraft(
                    for: url,
                    title: "Select \(field.fieldName)"
                ) { draft in
                    let groupName = field.fieldName
                    for idx in draft.fields.indices where draft.fields[idx].kind == .radio && draft.fields[idx].fieldName == groupName && !draft.fields[idx].isReadOnly {
                        draft.fields[idx].boolValue = (draft.fields[idx].id == field.id) ? newValue : false
                    }
                }
            }
        )
    }

    private func choiceBinding(for field: PDFFormFieldItem, url: URL) -> Binding<String> {
        Binding(
            get: {
                appState.pdfToolboxStore.formDraft(for: url).fields.first(where: { $0.id == field.id })?.stringValue ?? field.stringValue
            },
            set: { newValue in
                appState.pdfToolboxStore.updateFormDraft(
                    for: url,
                    title: "Select \(field.fieldName)"
                ) { draft in
                    guard let idx = draft.fields.firstIndex(where: { $0.id == field.id }), !draft.fields[idx].isReadOnly else { return }
                    draft.fields[idx].stringValue = newValue
                }
            }
        )
    }

    private func loadFormFields(url: URL) {
        isLoading = true
        errorMessage = nil
        let pwd = password.isEmpty ? nil : password
        Task.detached {
            do {
                let res = try PDFFormService.inspectForms(url: url, password: pwd)
                await MainActor.run {
                    inspection = res
                    appState.pdfToolboxStore.hydrateScannedFormFields(res.fields, for: url)
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    private func exportJSON(defaultName: String, fields: [PDFFormFieldItem]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(URL(fileURLWithPath: defaultName).deletingPathExtension().lastPathComponent)_form_data.json"
        if panel.runModal() == .OK, let url = panel.url {
            try? PDFFormService.exportFormDataJSON(fields: fields, to: url)
        }
    }

    private func importJSON(for targetPDFURL: URL) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url,
           let imported = try? PDFFormService.importFormDataJSON(from: url) {
            appState.pdfToolboxStore.updateFormDraft(
                for: targetPDFURL,
                title: "Import Form JSON"
            ) { draft in
                for inc in imported {
                    if let idx = draft.fields.firstIndex(where: { $0.id == inc.id || $0.fieldName == inc.fieldName }) {
                        if !draft.fields[idx].isReadOnly {
                            draft.fields[idx].stringValue = inc.stringValue
                            draft.fields[idx].boolValue = inc.boolValue
                        }
                    }
                }
            }
        }
    }
}
