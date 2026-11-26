import SwiftUI

struct MetadataFieldView: View {
    let descriptor: MetadataFieldDescriptor
    let value: MetadataValue?
    let onValueChanged: (MetadataValue?) -> Void
    
    @State private var textBuffer: String = ""
    
    init(
        descriptor: MetadataFieldDescriptor,
        value: MetadataValue?,
        onValueChanged: @escaping (MetadataValue?) -> Void
    ) {
        self.descriptor = descriptor
        self.value = value
        self.onValueChanged = onValueChanged
        self._textBuffer = State(initialValue: value?.stringValue ?? "")
    }
    
    var body: some View {
        HStack(alignment: .center, spacing: AppTheme.Spacing.md) {
            Text(descriptor.name)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .trailing)
            
            if descriptor.isWritable {
                writableTextField
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: textBuffer) { _, newValue in
                        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty {
                            onValueChanged(nil)
                        } else {
                            onValueChanged(.string(trimmed))
                        }
                    }
                    .onChange(of: value) { _, externalValue in
                        let str = externalValue?.stringValue ?? ""
                        if str != textBuffer {
                            textBuffer = str
                        }
                    }
            } else {
                Text(value?.stringValue ?? "—")
                    .font(.callout)
                    .foregroundColor(value == nil ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var writableTextField: some View {
        if descriptor.id == "lyrics" || descriptor.id == "comment" {
            TextField(descriptor.placeholder ?? descriptor.name, text: $textBuffer, axis: .vertical)
                .lineLimit(descriptor.id == "lyrics" ? 3...8 : 1...4)
                .accessibilityLabel("\(descriptor.name) field")
        } else {
            TextField(descriptor.placeholder ?? descriptor.name, text: $textBuffer)
                .accessibilityLabel("\(descriptor.name) field")
        }
    }
}
