import SwiftUI
import AppKit

struct PresetEditView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var presetManager = PresetManager.shared
    
    let originalPreset: SavedPreset?
    
    @State private var name: String = ""
    @State private var presetDescription: String = ""
    @State private var targetFormat: FileFormat = .webp
    @State private var constraintMode: ConstraintMode = .category
    @State private var selectedCategoryConstraint: FormatCategory = .image
    @State private var selectedSourceFormat: FileFormat = .png
    
    @State private var imageQuality: Double = 0.85
    @State private var webpLossless: Bool = false
    @State private var pdfDPI: Double = 150.0
    @State private var mediaQuality: QualityPreset = .high
    @State private var preserveMetadata: Bool = true
    
    @State private var destinationMode: DestinationMode = .defaultLocation
    @State private var customDirectoryPath: String = ""
    
    @State private var namingMode: NamingMode = .standard
    @State private var namingText: String = ""
    
    @State private var errorMessage: String?
    
    enum ConstraintMode: String, CaseIterable, Identifiable {
        case any = "Any Convertible Format"
        case category = "Limit to Category"
        case specific = "Specific Source Format"
        var id: String { rawValue }
    }
    
    enum DestinationMode: String, CaseIterable, Identifiable {
        case defaultLocation = "Default Output Folder"
        case sameAsInput = "Same Folder as Source File"
        case customDirectory = "Custom Folder..."
        var id: String { rawValue }
    }
    
    enum NamingMode: String, CaseIterable, Identifiable {
        case standard = "Standard (filename.ext)"
        case addSuffix = "Add Suffix (e.g. _converted)"
        case addPrefix = "Add Prefix (e.g. converted_)"
        var id: String { rawValue }
    }
    
    init(preset: SavedPreset? = nil) {
        self.originalPreset = preset
        _name = State(initialValue: preset?.name ?? "")
        _presetDescription = State(initialValue: preset?.description ?? "")
        _targetFormat = State(initialValue: preset?.targetFormat ?? .webp)
        
        if let source = preset?.sourceConstraint {
            _constraintMode = State(initialValue: .specific)
            _selectedSourceFormat = State(initialValue: source)
        } else if let cat = preset?.sourceCategoryConstraint {
            _constraintMode = State(initialValue: .category)
            _selectedCategoryConstraint = State(initialValue: cat)
        } else {
            _constraintMode = State(initialValue: .any)
        }
        
        _imageQuality = State(initialValue: preset?.options.imageQuality ?? 0.85)
        _webpLossless = State(initialValue: preset?.options.webpLossless ?? false)
        _pdfDPI = State(initialValue: preset?.options.pdfDPI ?? 150.0)
        _mediaQuality = State(initialValue: preset?.options.mediaQuality ?? .high)
        _preserveMetadata = State(initialValue: preset?.options.preserveMetadata ?? true)
        
        if let dest = preset?.outputDestinationPolicy {
            switch dest {
            case .defaultLocation:
                _destinationMode = State(initialValue: .defaultLocation)
            case .sameAsInput:
                _destinationMode = State(initialValue: .sameAsInput)
            case .customDirectory(let path):
                _destinationMode = State(initialValue: .customDirectory)
                _customDirectoryPath = State(initialValue: path)
            }
        }
        
        if let naming = preset?.outputNamingPolicy {
            switch naming {
            case .standard:
                _namingMode = State(initialValue: .standard)
            case .addSuffix(let suffix):
                _namingMode = State(initialValue: .addSuffix)
                _namingText = State(initialValue: suffix)
            case .addPrefix(let prefix):
                _namingMode = State(initialValue: .addPrefix)
                _namingText = State(initialValue: prefix)
            }
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(originalPreset == nil ? "Create Preset" : "Edit Preset")
                    .font(.headline)
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()
            
            Divider()
            
            Form {
                Section("General") {
                    TextField("Preset Name:", text: $name, prompt: Text("e.g. Web-Optimized WebP"))
                    TextField("Description:", text: $presetDescription, prompt: Text("Optional description"))
                }
                
                Section("Target Format") {
                    Picker("Convert To:", selection: $targetFormat) {
                        ForEach(validTargetFormats, id: \.self) { format in
                            Text("\(format.displayName) (\(format.fileExtension.uppercased()))").tag(format)
                        }
                    }
                }
                
                Section("Source Compatibility") {
                    Picker("Input Files:", selection: $constraintMode) {
                        ForEach(ConstraintMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    
                    if constraintMode == .category {
                        Picker("Category:", selection: $selectedCategoryConstraint) {
                            Text("Image").tag(FormatCategory.image)
                            Text("Video").tag(FormatCategory.video)
                            Text("Audio").tag(FormatCategory.audio)
                            Text("Document").tag(FormatCategory.document)
                        }
                    } else if constraintMode == .specific {
                        Picker("Source Format:", selection: $selectedSourceFormat) {
                            ForEach(validSourceFormats, id: \.self) { format in
                                Text("\(format.displayName) (\(format.fileExtension.uppercased()))").tag(format)
                            }
                        }
                    }
                }
                
                Section("Conversion Options") {
                    Toggle("Preserve Metadata", isOn: $preserveMetadata)
                    
                    if targetFormat.category == .image || targetFormat == .pdf {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Quality:")
                                Spacer()
                                Text("\(Int(imageQuality * 100))%")
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $imageQuality, in: 0.1...1.0, step: 0.05)
                        }
                    }
                    
                    if targetFormat == .webp {
                        Toggle("WebP Lossless", isOn: $webpLossless)
                    }
                    
                    if targetFormat == .pdf {
                        Picker("PDF DPI:", selection: $pdfDPI) {
                            Text("72 DPI (Screen)").tag(72.0)
                            Text("150 DPI (Standard)").tag(150.0)
                            Text("300 DPI (High / Print)").tag(300.0)
                        }
                    }
                    
                    if targetFormat.category == .video || targetFormat.category == .audio {
                        Picker("Media Quality:", selection: $mediaQuality) {
                            ForEach(QualityPreset.allCases, id: \.self) { q in
                                Text(q.rawValue).tag(q)
                            }
                        }
                    }
                }
                
                Section("Output Destination") {
                    Picker("Save To:", selection: $destinationMode) {
                        ForEach(DestinationMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    
                    if destinationMode == .customDirectory {
                        HStack {
                            TextField("Path:", text: $customDirectoryPath)
                                .textFieldStyle(.roundedBorder)
                            Button("Browse...") {
                                chooseCustomDirectory()
                            }
                        }
                    }
                }
                
                Section("Output Naming") {
                    Picker("Filename:", selection: $namingMode) {
                        ForEach(NamingMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    
                    if namingMode == .addSuffix {
                        TextField("Suffix:", text: $namingText, prompt: Text("_converted"))
                    } else if namingMode == .addPrefix {
                        TextField("Prefix:", text: $namingText, prompt: Text("converted_"))
                    }
                }
                
                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .formStyle(.grouped)
            
            Divider()
            
            // Footer Actions
            HStack {
                Spacer()
                Button("Save Preset") {
                    savePreset()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 480, minHeight: 520)
    }
    
    // MARK: - Filtered Formats
    
    private var validTargetFormats: [FileFormat] {
        let registry = ConversionRegistry.shared
        return FileFormat.allCases.filter { target in
            FileFormat.allCases.contains { source in
                registry.canConvert(from: source, to: target)
            }
        }.sorted { $0.displayName < $1.displayName }
    }
    
    private var validSourceFormats: [FileFormat] {
        let registry = ConversionRegistry.shared
        return FileFormat.allCases.filter { source in
            registry.canConvert(from: source, to: targetFormat)
        }.sorted { $0.displayName < $1.displayName }
    }
    
    // MARK: - Actions
    
    private func chooseCustomDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select Output Folder for Preset"
        
        if panel.runModal() == .OK, let url = panel.url {
            customDirectoryPath = url.path
        }
    }
    
    private func savePreset() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "Preset name cannot be empty."
            return
        }
        
        let sourceConstraint: FileFormat? = (constraintMode == .specific) ? selectedSourceFormat : nil
        let categoryConstraint: FormatCategory? = (constraintMode == .category) ? selectedCategoryConstraint : nil
        
        let destinationPolicy: OutputDestinationPolicy
        switch destinationMode {
        case .defaultLocation:
            destinationPolicy = .defaultLocation
        case .sameAsInput:
            destinationPolicy = .sameAsInput
        case .customDirectory:
            destinationPolicy = .customDirectory(path: customDirectoryPath)
        }
        
        let namingPolicy: OutputNamingPolicy
        switch namingMode {
        case .standard:
            namingPolicy = .standard
        case .addSuffix:
            namingPolicy = .addSuffix(suffix: namingText.isEmpty ? "_converted" : namingText)
        case .addPrefix:
            namingPolicy = .addPrefix(prefix: namingText.isEmpty ? "converted_" : namingText)
        }
        
        let options = ConversionOptions(
            preserveMetadata: preserveMetadata,
            imageQuality: imageQuality,
            pdfDPI: pdfDPI,
            webpLossless: webpLossless,
            mediaQuality: mediaQuality
        )
        
        let preset = SavedPreset(
            id: originalPreset?.id ?? UUID(),
            name: trimmedName,
            description: presetDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : presetDescription.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: originalPreset?.createdAt ?? Date(),
            modifiedAt: Date(),
            targetFormat: targetFormat,
            sourceConstraint: sourceConstraint,
            sourceCategoryConstraint: categoryConstraint,
            options: options,
            outputDestinationPolicy: destinationPolicy,
            outputNamingPolicy: namingPolicy,
            isBuiltIn: false
        )
        
        let validation = presetManager.validator.isPresetValid(preset)
        guard validation.isValid else {
            errorMessage = validation.reason ?? "Invalid preset configuration."
            return
        }
        
        presetManager.save(preset: preset)
        dismiss()
    }
}
