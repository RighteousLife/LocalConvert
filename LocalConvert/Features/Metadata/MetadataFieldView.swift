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
        HStack(alignment: .center, spacing: 12) {
            Text(descriptor.name)
                .font(.callout)
                .foregroundColor(.secondary)
                .frame(width: 140, alignment: .trailing)
            
            if descriptor.isWritable {
                TextField(descriptor.placeholder ?? descriptor.name, text: $textBuffer)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: textBuffer) { _, newValue in
                        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty {
                            onValueChanged(nil)
                        } else {
                            onValueChanged(.string(trimmed))
                        }
                    }
                    .accessibilityLabel("\(descriptor.name) field")
            } else {
                Text(value?.stringValue ?? "—")
                    .font(.callout)
                    .foregroundColor(value == nil ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("\(descriptor.name): \(value?.stringValue ?? "None")")
            }
        }
        .padding(.vertical, 2)
    }
}
