import Foundation

// MARK: - Machine-Readable Conversion Route Descriptor

struct ConversionRouteDescriptor: Codable, Sendable, Equatable, Identifiable {
    let source: String
    let target: String
    let sourceCategory: String
    let targetCategory: String
    let engineName: String
    let warning: String?
    
    var id: String { "\(source)->\(target)" }
}

struct ConversionMatrixSnapshot: Codable, Sendable {
    let generatedAt: String
    let totalFormats: Int
    let totalRoutes: Int
    let capabilities: [FormatCapability]
    let routes: [ConversionRouteDescriptor]
}

// MARK: - Conversion Matrix Exporter

enum ConversionMatrix {
    
    static func routeWarning(from input: FileFormat, to output: FileFormat) -> String? {
        // Macro-enabled OOXML to non-macro formats
        if [.docm, .xlsm, .pptm].contains(input) && ![.docm, .xlsm, .pptm].contains(output) {
            return "Macros (VBA) in \(input.shortExtensionLabel) files are not preserved in \(output.shortExtensionLabel)."
        }
        
        // Animated image converted to static image format
        let capIn = FormatCapabilityRegistry.shared.capability(for: input)
        let capOut = FormatCapabilityRegistry.shared.capability(for: output)
        if capIn.supportsAnimation && input.category == .image && output.category == .image && !capOut.supportsAnimation {
            return "Animated \(input.shortExtensionLabel) frames will be flattened to the first frame for static \(output.shortExtensionLabel) output."
        }
        
        // Alpha-less raster targets
        if capIn.supportsTransparency && output.category == .image && !capOut.supportsTransparency {
            return "\(output.shortExtensionLabel) does not support transparency; transparent areas will be flattened."
        }
        
        // Video-only elementary stream
        if output == .m2v {
            return "M2V is a video-only elementary stream; audio and subtitle tracks are omitted."
        }
        
        // Multi-sheet spreadsheet to CSV/TSV
        if [.xlsx, .xls, .ods, .xlsm, .xlsb, .xltx].contains(input) && (output == .csv || output == .tsv) {
            return "Exports tabular data from the active/first worksheet."
        }
        
        // Legacy binary Office to ODF/OOXML note
        if [.doc, .xls, .ppt].contains(input) || [.doc, .xls, .ppt].contains(output) {
            return "Complex layout/animations may vary slightly when converting legacy Office formats."
        }
        
        return nil
    }
    
    @MainActor
    static func snapshot(registry: ConversionRegistry = .shared) -> ConversionMatrixSnapshot {
        var routes: [ConversionRouteDescriptor] = []
        for source in FileFormat.allCases {
            let targets = registry.supportedOutputFormats(for: source)
                .sorted { $0.rawValue < $1.rawValue }
            for target in targets {
                let engineName = registry.findEngine(from: source, to: target)?.name ?? "Unknown"
                routes.append(ConversionRouteDescriptor(
                    source: source.rawValue,
                    target: target.rawValue,
                    sourceCategory: source.category.rawValue,
                    targetCategory: target.category.rawValue,
                    engineName: engineName,
                    warning: routeWarning(from: source, to: target)
                ))
            }
        }
        
        let formatter = ISO8601DateFormatter()
        return ConversionMatrixSnapshot(
            generatedAt: formatter.string(from: Date()),
            totalFormats: FileFormat.allCases.count,
            totalRoutes: routes.count,
            capabilities: FormatCapabilityRegistry.shared.allCapabilities,
            routes: routes
        )
    }
    
    @MainActor
    static func exportJSON(registry: ConversionRegistry = .shared) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(snapshot(registry: registry))
    }
}
