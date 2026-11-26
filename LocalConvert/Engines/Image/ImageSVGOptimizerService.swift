import Foundation

// MARK: - Safe SVG Structure Inspector & Sanitizer/Optimizer

struct SVGOptimizationOptions: Sendable, Equatable {
    var removeComments: Bool = true
    var removeMetadataElements: Bool = true
    var removeEditorNamespaces: Bool = true
    var collapseWhitespace: Bool = true
}

struct SVGInspectionReport: Sendable, Equatable {
    let url: URL?
    let originalBytes: Int64
    let isValidXML: Bool
    let hasSVGRoot: Bool
    let widthAttribute: String?
    let heightAttribute: String?
    let viewBox: String?
    let elementCount: Int
    let commentCount: Int
    let metadataElementCount: Int
    let securityWarnings: [String]
    let parseError: String?

    var isSafeToOptimize: Bool {
        isValidXML && hasSVGRoot && securityWarnings.isEmpty
    }
}

struct SVGOptimizationResult: Sendable, Equatable {
    let inspection: SVGInspectionReport
    let optimizedString: String
    let originalBytes: Int64
    let optimizedBytes: Int64
    let wasModified: Bool
    let blockedForSecurity: Bool

    var savedBytes: Int64 { max(0, originalBytes - optimizedBytes) }
    var savingsPercent: Double {
        guard originalBytes > 0 else { return 0 }
        return (Double(originalBytes - optimizedBytes) / Double(originalBytes)) * 100.0
    }
}

enum ImageSVGOptimizerService {

    /// Inspects SVG structure strictly via Foundation `XMLParser` with external entity resolution disabled.
    static func inspect(url: URL) throws -> SVGInspectionReport {
        let data = try Data(contentsOf: url)
        return inspect(data: data, url: url)
    }

    static func inspect(data: Data, url: URL? = nil) -> SVGInspectionReport {
        let rawText = String(data: data, encoding: .utf8) ?? ""
        var securityWarnings = scanSecurityDirectives(in: rawText)

        let delegate = SVGParserDelegate()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate

        let parsed = parser.parse()
        let err = parsed ? nil : parser.parserError?.localizedDescription

        for w in delegate.securityFlags where !securityWarnings.contains(w) {
            securityWarnings.append(w)
        }

        return SVGInspectionReport(
            url: url,
            originalBytes: Int64(data.count),
            isValidXML: parsed,
            hasSVGRoot: delegate.hasSVGRoot,
            widthAttribute: delegate.widthAttribute,
            heightAttribute: delegate.heightAttribute,
            viewBox: delegate.viewBoxAttribute,
            elementCount: delegate.elementCount,
            commentCount: delegate.commentCount,
            metadataElementCount: delegate.metadataElementCount,
            securityWarnings: securityWarnings,
            parseError: err
        )
    }

    /// Safely optimizes SVG markup while preserving vector geometry and blocking unsafe scripts/entities/external refs.
    static func optimize(data: Data, url: URL? = nil, options: SVGOptimizationOptions) -> SVGOptimizationResult {
        let report = inspect(data: data, url: url)
        guard report.isValidXML, report.hasSVGRoot else {
            let orig = String(data: data, encoding: .utf8) ?? ""
            return SVGOptimizationResult(
                inspection: report,
                optimizedString: orig,
                originalBytes: Int64(data.count),
                optimizedBytes: Int64(data.count),
                wasModified: false,
                blockedForSecurity: false
            )
        }

        if !report.securityWarnings.isEmpty {
            let orig = String(data: data, encoding: .utf8) ?? ""
            return SVGOptimizationResult(
                inspection: report,
                optimizedString: orig,
                originalBytes: Int64(data.count),
                optimizedBytes: Int64(data.count),
                wasModified: false,
                blockedForSecurity: true
            )
        }

        var output = String(data: data, encoding: .utf8) ?? ""

        // Do not alter documents containing CDATA/style blocks in ways that could shift rendering semantics
        let hasComplexStyleOrCDATA = output.contains("<![CDATA[")

        if options.removeComments {
            output = replacingRegex(pattern: "<!--[\\s\\S]*?-->", in: output, with: "")
        }

        if options.removeMetadataElements && !hasComplexStyleOrCDATA {
            output = replacingRegex(pattern: "<metadata\\b[^>]*>[\\s\\S]*?</metadata>", in: output, with: "", caseInsensitive: true)
            output = replacingRegex(pattern: "<metadata\\b[^>]*/>", in: output, with: "", caseInsensitive: true)
            output = replacingRegex(pattern: "<(inkscape|sodipodi|adobe|i|dc|cc|rdf):[^>]+>[\\s\\S]*?</\\1:[^>]+>", in: output, with: "", caseInsensitive: true)
            output = replacingRegex(pattern: "<(inkscape|sodipodi|adobe):[^>]+/>", in: output, with: "", caseInsensitive: true)
        }

        if options.removeEditorNamespaces {
            output = replacingRegex(pattern: "\\s+xmlns:(inkscape|sodipodi|dc|cc|rdf|i|x)=\"[^\"]*\"", in: output, with: "", caseInsensitive: true)
            output = replacingRegex(pattern: "\\s+(inkscape|sodipodi):[a-zA-Z0-9_-]+=\"[^\"]*\"", in: output, with: "", caseInsensitive: true)
        }

        if options.collapseWhitespace && !hasComplexStyleOrCDATA {
            // Preserve `<text>` whitespace safely by only collapsing inter-tag newlines/spaces when no `<text` node uses inline spaces
            if !output.lowercased().contains("<text") {
                output = replacingRegex(pattern: ">\\s+<", in: output, with: "><")
            }
            output = replacingRegex(pattern: "\\s{2,}", in: output, with: " ")
            output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Re-validate optimized SVG structurally with XMLParser before accepting
        guard let optData = output.data(using: .utf8) else {
            let orig = String(data: data, encoding: .utf8) ?? ""
            return SVGOptimizationResult(inspection: report, optimizedString: orig, originalBytes: Int64(data.count), optimizedBytes: Int64(data.count), wasModified: false, blockedForSecurity: false)
        }

        let recheck = inspect(data: optData, url: url)
        guard recheck.isValidXML && recheck.hasSVGRoot else {
            let orig = String(data: data, encoding: .utf8) ?? ""
            return SVGOptimizationResult(inspection: report, optimizedString: orig, originalBytes: Int64(data.count), optimizedBytes: Int64(data.count), wasModified: false, blockedForSecurity: false)
        }

        return SVGOptimizationResult(
            inspection: report,
            optimizedString: output,
            originalBytes: Int64(data.count),
            optimizedBytes: Int64(optData.count),
            wasModified: Int64(optData.count) != Int64(data.count),
            blockedForSecurity: false
        )
    }

    // MARK: - XML Safety Screening & Parser Delegate

    private static func scanSecurityDirectives(in text: String) -> [String] {
        var warnings: [String] = []
        let lower = text.lowercased()
        if lower.contains("<!doctype") || lower.contains("<!entity") {
            warnings.append("Blocked DTD / XML <!ENTITY> declarations (XXE safety guard).")
        }
        if lower.contains("<script") {
            warnings.append("Contains embedded <script> tags (active execution blocked).")
        }
        if lower.contains("javascript:") {
            warnings.append("Contains javascript: URI scheme (blocked).")
        }
        return warnings
    }

    private static func replacingRegex(pattern: String, in input: String, with replacement: String, caseInsensitive: Bool = false) -> String {
        let opts: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: opts) else { return input }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return regex.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: replacement)
    }

    private final class SVGParserDelegate: NSObject, XMLParserDelegate {
        var hasSVGRoot = false
        var widthAttribute: String?
        var heightAttribute: String?
        var viewBoxAttribute: String?
        var elementCount = 0
        var commentCount = 0
        var metadataElementCount = 0
        var securityFlags: [String] = []
        private var seenFirstElement = false

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            elementCount += 1
            let lowerName = elementName.lowercased()

            if !seenFirstElement {
                seenFirstElement = true
                if lowerName == "svg" || lowerName.hasSuffix(":svg") {
                    hasSVGRoot = true
                    widthAttribute = attributeDict["width"]
                    heightAttribute = attributeDict["height"]
                    viewBoxAttribute = attributeDict["viewBox"] ?? attributeDict["viewbox"]
                }
            }

            if lowerName == "metadata" {
                metadataElementCount += 1
            }

            if lowerName == "script" || lowerName == "foreignobject" {
                addFlag("Active/executable <\(elementName)> element detected; blocked from modification.")
            }

            for (attrKey, attrVal) in attributeDict {
                let lk = attrKey.lowercased()
                let lv = attrVal.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                if lk.hasPrefix("on") {
                    addFlag("Inline DOM event attribute '\(attrKey)' detected (blocked).")
                }
                if (lk == "href" || lk == "xlink:href" || lk == "src") &&
                    (lv.hasPrefix("http://") || lv.hasPrefix("https://") || lv.hasPrefix("//")) {
                    addFlag("External network reference ('\(attrKey)') detected; external fetching blocked.")
                }
                if lv.contains("javascript:") {
                    addFlag("Executable javascript: attribute URI detected (blocked).")
                }
                if lv.contains("url(http://") || lv.contains("url(https://") {
                    addFlag("External CSS url(...) fetch detected (blocked).")
                }
            }
        }

        func parser(_ parser: XMLParser, foundComment comment: String) {
            commentCount += 1
        }

        private func addFlag(_ msg: String) {
            if !securityFlags.contains(msg) {
                securityFlags.append(msg)
            }
        }
    }
}
