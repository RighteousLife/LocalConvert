import Foundation

// MARK: - Apple Data & Structured Text Format Converter

enum AppleDataFormatConverter {

    /// Maximum input payload accepted for in-memory text/data conversions (100 MB).
    static let maxInputFileBytes: Int64 = 100 * 1024 * 1024

    /// Maximum XML element nesting depth to guard against malicious deeply nested XML.
    static let maxXMLNestingDepth: Int = 512

    // MARK: - Models

    struct WeblocDocument: Sendable, Equatable {
        let url: String
        let title: String?
        let metadata: [String: String]
        let rawMetadataJSON: [String: AnySendableValue]
    }

    /// Strongly-typed Sendable wrapper for JSON-compatible metadata values.
    enum AnySendableValue: Sendable, Equatable {
        case string(String)
        case int(Int64)
        case double(Double)
        case bool(Bool)
        case null
        case array([AnySendableValue])
        case object([String: AnySendableValue])

        var foundationValue: Any {
            switch self {
            case .string(let s): return s
            case .int(let i): return i
            case .double(let d): return d
            case .bool(let b): return b
            case .null: return NSNull()
            case .array(let arr): return arr.map { $0.foundationValue }
            case .object(let dict): return dict.mapValues { $0.foundationValue }
            }
        }

        var displayString: String {
            switch self {
            case .string(let s): return s
            case .int(let i): return String(i)
            case .double(let d): return String(d)
            case .bool(let b): return b ? "true" : "false"
            case .null: return ""
            case .array(let arr): return arr.map { $0.displayString }.joined(separator: ", ")
            case .object(let dict):
                return dict.keys.sorted().map { "\($0): \(dict[$0]?.displayString ?? "")" }.joined(separator: "; ")
            }
        }
    }

    struct ICalendarEvent: Sendable, Equatable {
        let component: String
        let uid: String?
        let summary: String?
        let start: String?
        let end: String?
        let due: String?
        let completed: String?
        let location: String?
        let description: String?
        let status: String?
        let organizer: String?
        let attendees: [String]
        let rrule: String?
        let categories: [String]
        let properties: [String: String]
        let alarms: [[String: String]]
    }

    struct ICalendarDocument: Sendable, Equatable {
        let prodID: String?
        let version: String?
        let calendarName: String?
        let timezone: String?
        let calendarProperties: [String: String]
        let events: [ICalendarEvent]
        let todos: [ICalendarEvent]
        let journals: [ICalendarEvent]
        let freeBusy: [ICalendarEvent]

        var allItems: [ICalendarEvent] {
            events + todos + journals + freeBusy
        }
    }

    struct VCardLabeledValue: Sendable, Equatable {
        let value: String
        let types: [String]
    }

    struct VCardStructuredName: Sendable, Equatable {
        let family: String?
        let given: String?
        let additional: String?
        let prefix: String?
        let suffix: String?
    }

    struct VCardContact: Sendable, Equatable {
        let fullName: String?
        let structuredName: VCardStructuredName?
        let organization: String?
        let title: String?
        let emails: [VCardLabeledValue]
        let phones: [VCardLabeledValue]
        let addresses: [VCardLabeledValue]
        let urls: [VCardLabeledValue]
        let birthday: String?
        let note: String?
        let uid: String?
        let version: String?
        let hasEmbeddedPhoto: Bool
    }

    // MARK: - Property List / JSON / XML

    static func convertPlist(
        data: Data,
        to outputFormat: FileFormat,
        plistOutputFormat: PropertyListSerialization.PropertyListFormat = .xml
    ) throws -> Data {
        guard !data.isEmpty else {
            throw ConversionError.invalidInput("The property list file is empty.")
        }

        var detectedFormat = PropertyListSerialization.PropertyListFormat.xml
        let plistObject: Any
        do {
            plistObject = try PropertyListSerialization.propertyList(from: data, options: [], format: &detectedFormat)
        } catch {
            throw ConversionError.invalidInput("Malformed property list: \(error.localizedDescription)")
        }

        if detectedFormat == .openStep,
           !(plistObject is [AnyHashable: Any]),
           !(plistObject is [Any]) {
            throw ConversionError.invalidInput("Malformed property list: OpenStep property list must have a dictionary or array root.")
        }

        switch outputFormat {
        case .json:
            let jsonCompatible = sanitizeForJSON(plistObject)
            return try serializeJSONObject(jsonCompatible)
        case .xml:
            do {
                return try PropertyListSerialization.data(fromPropertyList: plistObject, format: .xml, options: 0)
            } catch {
                throw ConversionError.engineExecutionFailed(
                    "Failed to serialize property list as XML.",
                    underlyingError: error.localizedDescription
                )
            }
        case .plist:
            do {
                return try PropertyListSerialization.data(fromPropertyList: plistObject, format: plistOutputFormat, options: 0)
            } catch {
                throw ConversionError.engineExecutionFailed(
                    "Failed to serialize property list.",
                    underlyingError: error.localizedDescription
                )
            }
        default:
            throw ConversionError.unsupportedConversion(from: .plist, to: outputFormat)
        }
    }

    static func convertJSON(
        data: Data,
        to outputFormat: FileFormat,
        plistOutputFormat: PropertyListSerialization.PropertyListFormat = .xml
    ) throws -> Data {
        guard !data.isEmpty else {
            throw ConversionError.invalidInput("The JSON file is empty.")
        }

        let jsonObject: Any
        do {
            jsonObject = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw ConversionError.invalidInput("Malformed JSON: \(error.localizedDescription)")
        }

        switch outputFormat {
        case .plist:
            if jsonObject is NSNull {
                throw ConversionError.invalidInput("Top-level JSON 'null' cannot be converted to a Property List.")
            }
            let plistSafe = sanitizeForPlist(jsonObject)
            do {
                return try PropertyListSerialization.data(fromPropertyList: plistSafe, format: plistOutputFormat, options: 0)
            } catch {
                throw ConversionError.invalidInput("JSON content could not be represented as a Property List: \(error.localizedDescription)")
            }
        case .xml:
            let xmlString = serializeToGenericXML(jsonObject, rootElementName: "root")
            guard let xmlData = xmlString.data(using: .utf8) else {
                throw ConversionError.engineExecutionFailed("Failed to encode XML output as UTF-8.", underlyingError: nil)
            }
            return xmlData
        default:
            throw ConversionError.unsupportedConversion(from: .json, to: outputFormat)
        }
    }

    static func convertXML(
        data: Data,
        to outputFormat: FileFormat,
        plistOutputFormat: PropertyListSerialization.PropertyListFormat = .xml
    ) throws -> Data {
        guard !data.isEmpty else {
            throw ConversionError.invalidInput("The XML file is empty.")
        }

        // If the XML input is actually an Apple XML Property List, preserve native plist types (Date, Data, Bool, Int, Double).
        var detectedFormat = PropertyListSerialization.PropertyListFormat.xml
        if let plistObject = try? PropertyListSerialization.propertyList(from: data, options: [], format: &detectedFormat),
           detectedFormat == .xml {
            switch outputFormat {
            case .json:
                return try serializeJSONObject(sanitizeForJSON(plistObject))
            case .plist:
                do {
                    return try PropertyListSerialization.data(fromPropertyList: plistObject, format: plistOutputFormat, options: 0)
                } catch {
                    throw ConversionError.engineExecutionFailed(
                        "Failed to serialize property list.",
                        underlyingError: error.localizedDescription
                    )
                }
            default:
                throw ConversionError.unsupportedConversion(from: .xml, to: outputFormat)
            }
        }

        let parsedTree = try parseGenericXML(data: data)
        switch outputFormat {
        case .json:
            return try serializeJSONObject(sanitizeForJSON(parsedTree))
        case .plist:
            let plistSafe = sanitizeForPlist(parsedTree)
            do {
                return try PropertyListSerialization.data(fromPropertyList: plistSafe, format: plistOutputFormat, options: 0)
            } catch {
                throw ConversionError.invalidInput("XML structure could not be represented as a Property List: \(error.localizedDescription)")
            }
        default:
            throw ConversionError.unsupportedConversion(from: .xml, to: outputFormat)
        }
    }

    // MARK: - Webloc

    static func parseWebloc(data: Data, sourceURL: URL? = nil) throws -> WeblocDocument {
        guard !data.isEmpty else {
            throw ConversionError.invalidInput("The .webloc file is empty.")
        }

        let plistObject: Any
        do {
            plistObject = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            throw ConversionError.invalidInput("Malformed .webloc property list: \(error.localizedDescription)")
        }

        guard let dict = plistObject as? [String: Any] else {
            throw ConversionError.invalidInput("Malformed .webloc file: root property list must be a dictionary.")
        }

        guard let rawURL = dict["URL"] as? String else {
            throw ConversionError.invalidInput("Malformed .webloc file: missing required 'URL' string.")
        }
        let trimmedURL = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            throw ConversionError.invalidInput("Malformed .webloc file: 'URL' value is empty.")
        }

        let candidateTitle = (dict["title"] as? String)
            ?? (dict["Title"] as? String)
            ?? (dict["URLName"] as? String)
            ?? (dict["name"] as? String)
            ?? (dict["Name"] as? String)
        let cleanedTitle = candidateTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = (cleanedTitle?.isEmpty == false)
            ? cleanedTitle
            : sourceURL.map { FileFormat.baseNameByStrippingExtension(from: $0) }.flatMap { $0.isEmpty ? nil : $0 }

        var metadataStrings: [String: String] = [:]
        var rawMetadata: [String: AnySendableValue] = [:]
        for (key, value) in dict where key != "URL" {
            let sendable = toSendableValue(value)
            rawMetadata[key] = sendable
            metadataStrings[key] = sendable.displayString
        }

        return WeblocDocument(
            url: trimmedURL,
            title: resolvedTitle,
            metadata: metadataStrings,
            rawMetadataJSON: rawMetadata
        )
    }

    static func exportWebloc(
        _ doc: WeblocDocument,
        sourceFilename: String?,
        to outputFormat: FileFormat
    ) throws -> Data {
        let displayTitle = doc.title ?? doc.url

        switch outputFormat {
        case .txt:
            var lines: [String] = []
            if let title = doc.title, !title.isEmpty {
                lines.append("Title: \(title)")
            }
            lines.append("URL: \(doc.url)")
            if let sourceFilename, !sourceFilename.isEmpty {
                lines.append("Source: \(sourceFilename)")
            }
            for key in doc.metadata.keys.sorted() {
                if let val = doc.metadata[key], !val.isEmpty {
                    lines.append("\(key): \(val)")
                }
            }
            let text = lines.joined(separator: "\n") + "\n"
            guard let data = text.data(using: .utf8) else {
                throw ConversionError.engineExecutionFailed("Failed to encode .webloc text output.", underlyingError: nil)
            }
            return data

        case .md:
            let escapedTitle = escapeMarkdownText(displayTitle)
            let escapedLinkTarget = escapeMarkdownLinkDestination(doc.url)
            var lines: [String] = [
                "# \(escapedTitle)",
                "",
                "[\(escapedTitle)](\(escapedLinkTarget))",
                "",
                "- **URL**: `\(doc.url)`"
            ]
            if let sourceFilename, !sourceFilename.isEmpty {
                lines.append("- **Source**: \(escapeMarkdownText(sourceFilename))")
            }
            for key in doc.metadata.keys.sorted() {
                if let val = doc.metadata[key], !val.isEmpty {
                    lines.append("- **\(escapeMarkdownText(key))**: \(escapeMarkdownText(val))")
                }
            }
            let md = lines.joined(separator: "\n") + "\n"
            guard let data = md.data(using: .utf8) else {
                throw ConversionError.engineExecutionFailed("Failed to encode .webloc Markdown output.", underlyingError: nil)
            }
            return data

        case .json:
            var root: [String: Any] = [
                "url": doc.url
            ]
            if let title = doc.title {
                root["title"] = title
            }
            if let sourceFilename {
                root["sourceFile"] = sourceFilename
            }
            if !doc.rawMetadataJSON.isEmpty {
                root["metadata"] = doc.rawMetadataJSON.mapValues { $0.foundationValue }
            }
            return try serializeJSONObject(root)

        case .csv:
            let metadataSummary = doc.metadata.keys.sorted()
                .compactMap { key -> String? in
                    guard let val = doc.metadata[key], !val.isEmpty else { return nil }
                    return "\(key)=\(val)"
                }
                .joined(separator: "; ")
            let rows: [[String]] = [
                ["title", "url", "source_file", "metadata"],
                [doc.title ?? "", doc.url, sourceFilename ?? "", metadataSummary]
            ]
            let csv = generateRFC4180CSV(rows: rows)
            guard let data = csv.data(using: .utf8) else {
                throw ConversionError.engineExecutionFailed("Failed to encode .webloc CSV output.", underlyingError: nil)
            }
            return data

        default:
            throw ConversionError.unsupportedConversion(from: .webloc, to: outputFormat)
        }
    }

    // MARK: - iCalendar (.ics)

    static func parseICalendar(data: Data) throws -> ICalendarDocument {
        guard !data.isEmpty else {
            throw ConversionError.invalidInput("The iCalendar (.ics) file is empty.")
        }

        guard let text = decodeTextData(data) else {
            throw ConversionError.invalidInput("Malformed iCalendar file: unable to decode text.")
        }

        let lines = unfoldRFC5545Lines(text)

        var componentStack: [String] = []
        var sawCalendar = false
        var closedCalendar = false

        var calendarProperties: [String: String] = [:]

        struct MutableComponent {
            let name: String
            var properties: [String: String] = [:]
            var attendees: [String] = []
            var categories: [String] = []
            var alarms: [[String: String]] = []
        }

        var activeTopComponent: MutableComponent?
        var activeAlarm: [String: String]?
        var inIgnoredSubcomponentDepth = 0

        var events: [ICalendarEvent] = []
        var todos: [ICalendarEvent] = []
        var journals: [ICalendarEvent] = []
        var freeBusy: [ICalendarEvent] = []

        func finalizeComponent(_ comp: MutableComponent) {
            let item = ICalendarEvent(
                component: comp.name,
                uid: comp.properties["UID"],
                summary: comp.properties["SUMMARY"],
                start: comp.properties["DTSTART"],
                end: comp.properties["DTEND"],
                due: comp.properties["DUE"],
                completed: comp.properties["COMPLETED"],
                location: comp.properties["LOCATION"],
                description: comp.properties["DESCRIPTION"],
                status: comp.properties["STATUS"],
                organizer: comp.properties["ORGANIZER"],
                attendees: comp.attendees,
                rrule: comp.properties["RRULE"],
                categories: comp.categories,
                properties: comp.properties,
                alarms: comp.alarms
            )
            switch comp.name {
            case "VEVENT": events.append(item)
            case "VTODO": todos.append(item)
            case "VJOURNAL": journals.append(item)
            case "VFREEBUSY": freeBusy.append(item)
            default: break
            }
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .newlines)
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                continue
            }

            guard let parsed = parseContentLine(line) else {
                throw ConversionError.invalidInput("Malformed iCalendar content line: '\(line.prefix(80))'")
            }

            let propName = stripGroupPrefix(parsed.name).uppercased()
            let rawValue = parsed.value

            if propName == "BEGIN" {
                let compName = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                guard !compName.isEmpty else {
                    throw ConversionError.invalidInput("Malformed iCalendar: empty BEGIN component.")
                }
                if compName == "VCALENDAR" {
                    if sawCalendar && !componentStack.isEmpty {
                        throw ConversionError.invalidInput("Malformed iCalendar: nested VCALENDAR block.")
                    }
                    sawCalendar = true
                    closedCalendar = false
                    componentStack.append(compName)
                } else {
                    guard sawCalendar, !componentStack.isEmpty else {
                        throw ConversionError.invalidInput("Malformed iCalendar: '\(compName)' appeared outside VCALENDAR.")
                    }
                    componentStack.append(compName)
                    if ["VEVENT", "VTODO", "VJOURNAL", "VFREEBUSY"].contains(compName),
                       componentStack.count == 2 {
                        activeTopComponent = MutableComponent(name: compName)
                    } else if compName == "VALARM" && activeTopComponent != nil {
                        activeAlarm = [:]
                    } else {
                        inIgnoredSubcomponentDepth += 1
                    }
                }
                continue
            }

            if propName == "END" {
                let compName = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                guard let expected = componentStack.popLast(), expected == compName else {
                    throw ConversionError.invalidInput("Malformed iCalendar: mismatched END:\(compName).")
                }
                if compName == "VCALENDAR" {
                    closedCalendar = true
                } else if compName == "VALARM", let alarm = activeAlarm {
                    activeTopComponent?.alarms.append(alarm)
                    activeAlarm = nil
                } else if inIgnoredSubcomponentDepth > 0 {
                    inIgnoredSubcomponentDepth -= 1
                } else if let comp = activeTopComponent, comp.name == compName {
                    finalizeComponent(comp)
                    activeTopComponent = nil
                }
                continue
            }

            guard sawCalendar, !componentStack.isEmpty else {
                throw ConversionError.invalidInput("Malformed iCalendar: content found outside VCALENDAR.")
            }

            let unescapedValue = unescapeRFC5545Text(rawValue)

            if activeAlarm != nil {
                activeAlarm?[propName] = unescapedValue
                continue
            }

            if inIgnoredSubcomponentDepth > 0 {
                continue
            }

            if var comp = activeTopComponent {
                if propName == "ATTENDEE" {
                    let cn = parsed.parameters["CN"]
                    let formatted = formatAttendee(value: unescapedValue, commonName: cn)
                    comp.attendees.append(formatted)
                } else if propName == "ORGANIZER" {
                    let cn = parsed.parameters["CN"]
                    comp.properties[propName] = formatAttendee(value: unescapedValue, commonName: cn)
                } else if propName == "CATEGORIES" {
                    let split = splitEscaped(rawValue, delimiter: ",").map { unescapeRFC5545Text($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    comp.categories.append(contentsOf: split)
                    comp.properties[propName] = comp.categories.joined(separator: ", ")
                } else {
                    comp.properties[propName] = unescapedValue
                }
                activeTopComponent = comp
            } else if componentStack.last == "VCALENDAR" {
                calendarProperties[propName] = unescapedValue
            }
        }

        guard sawCalendar, closedCalendar, componentStack.isEmpty else {
            throw ConversionError.invalidInput("Malformed iCalendar: missing BEGIN:VCALENDAR or unclosed component.")
        }

        return ICalendarDocument(
            prodID: calendarProperties["PRODID"],
            version: calendarProperties["VERSION"],
            calendarName: calendarProperties["X-WR-CALNAME"] ?? calendarProperties["NAME"],
            timezone: calendarProperties["X-WR-TIMEZONE"],
            calendarProperties: calendarProperties,
            events: events,
            todos: todos,
            journals: journals,
            freeBusy: freeBusy
        )
    }

    static func exportICalendar(_ doc: ICalendarDocument, to outputFormat: FileFormat) throws -> Data {
        switch outputFormat {
        case .json:
            var calMeta: [String: Any] = [:]
            if let name = doc.calendarName { calMeta["name"] = name }
            if let version = doc.version { calMeta["version"] = version }
            if let prodID = doc.prodID { calMeta["prodId"] = prodID }
            if let tz = doc.timezone { calMeta["timezone"] = tz }

            func encodeItem(_ item: ICalendarEvent) -> [String: Any] {
                var dict: [String: Any] = ["component": item.component]
                if let v = item.uid { dict["uid"] = v }
                if let v = item.summary { dict["summary"] = v }
                if let v = item.start { dict["start"] = v }
                if let v = item.end { dict["end"] = v }
                if let v = item.due { dict["due"] = v }
                if let v = item.completed { dict["completed"] = v }
                if let v = item.location { dict["location"] = v }
                if let v = item.description { dict["description"] = v }
                if let v = item.status { dict["status"] = v }
                if let v = item.organizer { dict["organizer"] = v }
                if !item.attendees.isEmpty { dict["attendees"] = item.attendees }
                if let v = item.rrule { dict["rrule"] = v }
                if !item.categories.isEmpty { dict["categories"] = item.categories }
                if !item.alarms.isEmpty { dict["alarms"] = item.alarms }
                if !item.properties.isEmpty { dict["properties"] = item.properties }
                return dict
            }

            var root: [String: Any] = [
                "calendar": calMeta,
                "events": doc.events.map(encodeItem),
                "todos": doc.todos.map(encodeItem)
            ]
            if !doc.journals.isEmpty {
                root["journals"] = doc.journals.map(encodeItem)
            }
            if !doc.freeBusy.isEmpty {
                root["freeBusy"] = doc.freeBusy.map(encodeItem)
            }
            return try serializeJSONObject(root)

        case .csv:
            var rows: [[String]] = [
                ["type", "uid", "summary", "start", "end", "location", "description", "status", "organizer", "attendees", "rrule"]
            ]
            for item in doc.allItems {
                let effectiveEnd = item.end ?? item.due ?? item.completed ?? ""
                rows.append([
                    item.component,
                    item.uid ?? "",
                    item.summary ?? "",
                    item.start ?? "",
                    effectiveEnd,
                    item.location ?? "",
                    item.description ?? "",
                    item.status ?? "",
                    item.organizer ?? "",
                    item.attendees.joined(separator: "; "),
                    item.rrule ?? ""
                ])
            }
            let csv = generateRFC4180CSV(rows: rows)
            guard let data = csv.data(using: .utf8) else {
                throw ConversionError.engineExecutionFailed("Failed to encode iCalendar CSV output.", underlyingError: nil)
            }
            return data

        case .txt:
            var lines: [String] = []
            if let name = doc.calendarName, !name.isEmpty {
                lines.append("Calendar: \(name)")
            } else {
                lines.append("Calendar")
            }
            if let tz = doc.timezone, !tz.isEmpty {
                lines.append("Timezone: \(tz)")
            }
            lines.append("Items: \(doc.allItems.count)")
            lines.append("")

            if doc.allItems.isEmpty {
                lines.append("(No calendar events or tasks)")
            } else {
                for (index, item) in doc.allItems.enumerated() {
                    if index > 0 {
                        lines.append("---")
                    }
                    let title = item.summary ?? "(Untitled \(item.component))"
                    lines.append("[\(item.component)] \(title)")
                    if let start = item.start { lines.append("Start: \(start)") }
                    if let end = item.end { lines.append("End: \(end)") }
                    if let due = item.due { lines.append("Due: \(due)") }
                    if let location = item.location, !location.isEmpty { lines.append("Location: \(location)") }
                    if let status = item.status, !status.isEmpty { lines.append("Status: \(status)") }
                    if let organizer = item.organizer, !organizer.isEmpty { lines.append("Organizer: \(organizer)") }
                    if !item.attendees.isEmpty { lines.append("Attendees: \(item.attendees.joined(separator: ", "))") }
                    if let rrule = item.rrule, !rrule.isEmpty { lines.append("Recurrence: \(rrule)") }
                    if let description = item.description, !description.isEmpty { lines.append("Description: \(description)") }
                    if let uid = item.uid, !uid.isEmpty { lines.append("UID: \(uid)") }
                }
            }
            let text = lines.joined(separator: "\n") + "\n"
            guard let data = text.data(using: .utf8) else {
                throw ConversionError.engineExecutionFailed("Failed to encode iCalendar text output.", underlyingError: nil)
            }
            return data

        default:
            throw ConversionError.unsupportedConversion(from: .ics, to: outputFormat)
        }
    }

    // MARK: - vCard (.vcf)

    static func parseVCard(data: Data) throws -> [VCardContact] {
        guard !data.isEmpty else {
            throw ConversionError.invalidInput("The vCard (.vcf) file is empty.")
        }

        guard let text = decodeTextData(data) else {
            throw ConversionError.invalidInput("Malformed vCard file: unable to decode text.")
        }

        let lines = unfoldVCardLines(text)

        var contacts: [VCardContact] = []
        var inVCard = false
        var sawVCard = false

        var fullName: String?
        var structuredName: VCardStructuredName?
        var organization: String?
        var title: String?
        var emails: [VCardLabeledValue] = []
        var phones: [VCardLabeledValue] = []
        var addresses: [VCardLabeledValue] = []
        var urls: [VCardLabeledValue] = []
        var birthday: String?
        var note: String?
        var uid: String?
        var version: String?
        var hasEmbeddedPhoto = false

        func resetCardState() {
            fullName = nil
            structuredName = nil
            organization = nil
            title = nil
            emails = []
            phones = []
            addresses = []
            urls = []
            birthday = nil
            note = nil
            uid = nil
            version = nil
            hasEmbeddedPhoto = false
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .newlines)
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                continue
            }

            guard let parsed = parseContentLine(line) else {
                throw ConversionError.invalidInput("Malformed vCard content line: '\(line.prefix(80))'")
            }

            let propName = stripGroupPrefix(parsed.name).uppercased()
            let rawValue = parsed.value

            if propName == "BEGIN" {
                let blockName = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                guard blockName == "VCARD" else {
                    throw ConversionError.invalidInput("Malformed vCard: unexpected BEGIN:\(blockName).")
                }
                guard !inVCard else {
                    throw ConversionError.invalidInput("Malformed vCard: nested BEGIN:VCARD without END:VCARD.")
                }
                inVCard = true
                sawVCard = true
                resetCardState()
                continue
            }

            if propName == "END" {
                let blockName = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                guard inVCard, blockName == "VCARD" else {
                    throw ConversionError.invalidInput("Malformed vCard: unexpected END:\(blockName).")
                }
                inVCard = false

                // Compute fallback full name from structured name if FN is absent
                let resolvedFullName: String? = {
                    if let fn = fullName, !fn.isEmpty { return fn }
                    if let n = structuredName {
                        let parts = [n.prefix, n.given, n.additional, n.family, n.suffix]
                            .compactMap { $0 }
                            .filter { !$0.isEmpty }
                        if !parts.isEmpty { return parts.joined(separator: " ") }
                    }
                    return nil
                }()

                contacts.append(VCardContact(
                    fullName: resolvedFullName,
                    structuredName: structuredName,
                    organization: organization,
                    title: title,
                    emails: emails,
                    phones: phones,
                    addresses: addresses,
                    urls: urls,
                    birthday: birthday,
                    note: note,
                    uid: uid,
                    version: version,
                    hasEmbeddedPhoto: hasEmbeddedPhoto
                ))
                resetCardState()
                continue
            }

            guard inVCard else {
                throw ConversionError.invalidInput("Malformed vCard: property '\(propName)' found outside BEGIN:VCARD.")
            }

            let decodedRawValue: String
            if parsed.parameters["ENCODING"]?.uppercased() == "QUOTED-PRINTABLE" {
                decodedRawValue = decodeQuotedPrintable(rawValue)
            } else {
                decodedRawValue = rawValue
            }

            let types = extractVCardTypes(from: parsed.parameters)

            switch propName {
            case "FN":
                fullName = unescapeRFC5545Text(decodedRawValue)
            case "N":
                let parts = splitEscaped(decodedRawValue, delimiter: ";").map { unescapeRFC5545Text($0) }
                func part(_ idx: Int) -> String? {
                    guard idx < parts.count else { return nil }
                    let trimmed = parts[idx].trimmingCharacters(in: .whitespaces)
                    return trimmed.isEmpty ? nil : trimmed
                }
                structuredName = VCardStructuredName(
                    family: part(0),
                    given: part(1),
                    additional: part(2),
                    prefix: part(3),
                    suffix: part(4)
                )
            case "ORG":
                let parts = splitEscaped(decodedRawValue, delimiter: ";")
                    .map { unescapeRFC5545Text($0).trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                organization = parts.isEmpty ? nil : parts.joined(separator: " — ")
            case "TITLE":
                title = unescapeRFC5545Text(decodedRawValue)
            case "EMAIL":
                let val = unescapeRFC5545Text(decodedRawValue).trimmingCharacters(in: .whitespaces)
                if !val.isEmpty {
                    emails.append(VCardLabeledValue(value: val, types: types))
                }
            case "TEL":
                let val = unescapeRFC5545Text(decodedRawValue).trimmingCharacters(in: .whitespaces)
                if !val.isEmpty {
                    phones.append(VCardLabeledValue(value: val, types: types))
                }
            case "ADR":
                let parts = splitEscaped(decodedRawValue, delimiter: ";")
                    .map { unescapeRFC5545Text($0).trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                if !parts.isEmpty {
                    addresses.append(VCardLabeledValue(value: parts.joined(separator: ", "), types: types))
                }
            case "URL":
                let val = unescapeRFC5545Text(decodedRawValue).trimmingCharacters(in: .whitespaces)
                if !val.isEmpty {
                    urls.append(VCardLabeledValue(value: val, types: types))
                }
            case "BDAY":
                birthday = unescapeRFC5545Text(decodedRawValue).trimmingCharacters(in: .whitespaces)
            case "NOTE":
                note = unescapeRFC5545Text(decodedRawValue)
            case "UID":
                uid = unescapeRFC5545Text(decodedRawValue)
            case "VERSION":
                version = decodedRawValue.trimmingCharacters(in: .whitespaces)
            case "PHOTO":
                hasEmbeddedPhoto = true
            default:
                break
            }
        }

        guard sawVCard, !inVCard else {
            throw ConversionError.invalidInput("Malformed vCard: missing BEGIN:VCARD or unclosed VCARD block.")
        }

        return contacts
    }

    static func exportVCards(_ contacts: [VCardContact], to outputFormat: FileFormat) throws -> Data {
        switch outputFormat {
        case .json:
            let encodedContacts: [[String: Any]] = contacts.map { contact in
                var dict: [String: Any] = [:]
                if let v = contact.fullName { dict["fullName"] = v }
                if let n = contact.structuredName {
                    var nameDict: [String: String] = [:]
                    if let f = n.family { nameDict["family"] = f }
                    if let g = n.given { nameDict["given"] = g }
                    if let a = n.additional { nameDict["additional"] = a }
                    if let p = n.prefix { nameDict["prefix"] = p }
                    if let s = n.suffix { nameDict["suffix"] = s }
                    if !nameDict.isEmpty { dict["name"] = nameDict }
                }
                if let v = contact.organization { dict["organization"] = v }
                if let v = contact.title { dict["title"] = v }
                if !contact.emails.isEmpty {
                    dict["emails"] = contact.emails.map { ["value": $0.value, "types": $0.types] as [String: Any] }
                }
                if !contact.phones.isEmpty {
                    dict["phones"] = contact.phones.map { ["value": $0.value, "types": $0.types] as [String: Any] }
                }
                if !contact.addresses.isEmpty {
                    dict["addresses"] = contact.addresses.map { ["value": $0.value, "types": $0.types] as [String: Any] }
                }
                if !contact.urls.isEmpty {
                    dict["urls"] = contact.urls.map { ["value": $0.value, "types": $0.types] as [String: Any] }
                }
                if let v = contact.birthday { dict["birthday"] = v }
                if let v = contact.note { dict["note"] = v }
                if let v = contact.uid { dict["uid"] = v }
                if let v = contact.version { dict["version"] = v }
                if contact.hasEmbeddedPhoto { dict["hasEmbeddedPhoto"] = true }
                return dict
            }
            return try serializeJSONObject(["contacts": encodedContacts])

        case .csv:
            var rows: [[String]] = [
                ["full_name", "first_name", "last_name", "organization", "title", "emails", "phones", "addresses", "urls", "birthday", "note"]
            ]
            for contact in contacts {
                rows.append([
                    contact.fullName ?? "",
                    contact.structuredName?.given ?? "",
                    contact.structuredName?.family ?? "",
                    contact.organization ?? "",
                    contact.title ?? "",
                    contact.emails.map(\.value).joined(separator: "; "),
                    contact.phones.map(\.value).joined(separator: "; "),
                    contact.addresses.map(\.value).joined(separator: "; "),
                    contact.urls.map(\.value).joined(separator: "; "),
                    contact.birthday ?? "",
                    contact.note ?? ""
                ])
            }
            let csv = generateRFC4180CSV(rows: rows)
            guard let data = csv.data(using: .utf8) else {
                throw ConversionError.engineExecutionFailed("Failed to encode vCard CSV output.", underlyingError: nil)
            }
            return data

        case .txt:
            var blocks: [String] = []
            for contact in contacts {
                var lines: [String] = []
                lines.append("Name: \(contact.fullName ?? "(Unnamed Contact)")")
                if let org = contact.organization, !org.isEmpty {
                    lines.append("Organization: \(org)")
                }
                if let title = contact.title, !title.isEmpty {
                    lines.append("Title: \(title)")
                }
                for email in contact.emails {
                    let label = email.types.isEmpty ? "Email" : "Email (\(email.types.joined(separator: ", ")))"
                    lines.append("\(label): \(email.value)")
                }
                for phone in contact.phones {
                    let label = phone.types.isEmpty ? "Phone" : "Phone (\(phone.types.joined(separator: ", ")))"
                    lines.append("\(label): \(phone.value)")
                }
                for adr in contact.addresses {
                    let label = adr.types.isEmpty ? "Address" : "Address (\(adr.types.joined(separator: ", ")))"
                    lines.append("\(label): \(adr.value)")
                }
                for url in contact.urls {
                    let label = url.types.isEmpty ? "URL" : "URL (\(url.types.joined(separator: ", ")))"
                    lines.append("\(label): \(url.value)")
                }
                if let bday = contact.birthday, !bday.isEmpty {
                    lines.append("Birthday: \(bday)")
                }
                if let note = contact.note, !note.isEmpty {
                    lines.append("Note: \(note)")
                }
                blocks.append(lines.joined(separator: "\n"))
            }
            let text = blocks.joined(separator: "\n\n---\n\n") + "\n"
            guard let data = text.data(using: .utf8) else {
                throw ConversionError.engineExecutionFailed("Failed to encode vCard text output.", underlyingError: nil)
            }
            return data

        default:
            throw ConversionError.unsupportedConversion(from: .vcf, to: outputFormat)
        }
    }

    // MARK: - RFC 4180 CSV Helper

    static func generateRFC4180CSV(rows: [[String]], separator: Character = ",") -> String {
        rows.map { row in
            row.map { field in
                let needsQuotes = field.contains(separator)
                    || field.contains("\"")
                    || field.contains("\n")
                    || field.contains("\r")
                if needsQuotes {
                    let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
                    return "\"\(escaped)\""
                }
                return field
            }.joined(separator: String(separator))
        }.joined(separator: "\n") + "\n"
    }

    // MARK: - Private Helpers: JSON & Plist Sanitization

    private static func serializeJSONObject(_ object: Any) throws -> Data {
        let sanitized = sanitizeForJSON(object)
        guard JSONSerialization.isValidJSONObject(sanitized) || sanitized is String || sanitized is NSNumber || sanitized is Bool || sanitized is NSNull else {
            throw ConversionError.engineExecutionFailed("Data could not be represented as valid JSON.", underlyingError: nil)
        }
        do {
            return try JSONSerialization.data(withJSONObject: sanitized, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
        } catch {
            throw ConversionError.engineExecutionFailed("Failed to serialize JSON output.", underlyingError: error.localizedDescription)
        }
    }

    private static func formatISO8601Date(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func sanitizeForJSON(_ value: Any) -> Any {
        switch value {
        case let date as Date:
            return formatISO8601Date(date)
        case let data as Data:
            return data.base64EncodedString()
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue
            }
            let d = number.doubleValue
            if !d.isFinite {
                return String(describing: d)
            }
            return number
        case let bool as Bool:
            return bool
        case let str as String:
            return str
        case let arr as [Any]:
            return arr.map { sanitizeForJSON($0) }
        case let dict as [AnyHashable: Any]:
            var result: [String: Any] = [:]
            for (k, v) in dict {
                let key = (k as? String) ?? String(describing: k)
                result[key] = sanitizeForJSON(v)
            }
            return result
        case is NSNull:
            return NSNull()
        default:
            return String(describing: value)
        }
    }

    private static func sanitizeForPlist(_ value: Any) -> Any {
        switch value {
        case is NSNull:
            return ""
        case let arr as [Any]:
            return arr.map { sanitizeForPlist($0) }
        case let dict as [AnyHashable: Any]:
            var result: [String: Any] = [:]
            for (k, v) in dict {
                if v is NSNull {
                    continue
                }
                let key = (k as? String) ?? String(describing: k)
                result[key] = sanitizeForPlist(v)
            }
            return result
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue
            }
            return number
        case let bool as Bool:
            return bool
        case let str as String:
            return str
        case let date as Date:
            return date
        case let data as Data:
            return data
        default:
            return String(describing: value)
        }
    }

    private static func toSendableValue(_ value: Any) -> AnySendableValue {
        switch value {
        case let date as Date:
            return .string(formatISO8601Date(date))
        case let data as Data:
            return .string(data.base64EncodedString())
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            let d = number.doubleValue
            if !d.isFinite {
                return .string(String(describing: d))
            }
            let objCType = String(cString: number.objCType)
            if objCType == "d" || objCType == "f" {
                return .double(d)
            }
            return .int(number.int64Value)
        case let bool as Bool:
            return .bool(bool)
        case let str as String:
            return .string(str)
        case let arr as [Any]:
            return .array(arr.map { toSendableValue($0) })
        case let dict as [AnyHashable: Any]:
            var out: [String: AnySendableValue] = [:]
            for (k, v) in dict {
                let key = (k as? String) ?? String(describing: k)
                out[key] = toSendableValue(v)
            }
            return .object(out)
        case is NSNull:
            return .null
        default:
            return .string(String(describing: value))
        }
    }

    // MARK: - Private Helpers: Generic XML Parser & Serializer

    private final class XMLTreeParserDelegate: NSObject, XMLParserDelegate {
        final class Node {
            let name: String
            let attributes: [String: String]
            var children: [(String, Node)] = []
            var textBuffer: String = ""

            init(name: String, attributes: [String: String]) {
                self.name = name
                self.attributes = attributes
            }

            func toFoundationObject() -> Any {
                let trimmedText = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)

                if children.isEmpty && attributes.isEmpty {
                    return trimmedText
                }

                var dict: [String: Any] = [:]
                if !attributes.isEmpty {
                    dict["@attributes"] = attributes
                }
                if !trimmedText.isEmpty {
                    dict["#text"] = trimmedText
                }

                for (childName, childNode) in children {
                    let childValue = childNode.toFoundationObject()
                    if let existing = dict[childName] {
                        if var arr = existing as? [Any] {
                            arr.append(childValue)
                            dict[childName] = arr
                        } else {
                            dict[childName] = [existing, childValue]
                        }
                    } else {
                        dict[childName] = childValue
                    }
                }
                return dict
            }
        }

        private let maxDepth: Int
        private var stack: [Node] = []
        var rootNode: Node?
        var parseFailureMessage: String?

        init(maxDepth: Int) {
            self.maxDepth = maxDepth
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String]
        ) {
            if stack.count >= maxDepth {
                parseFailureMessage = "XML nesting exceeds maximum depth of \(maxDepth)."
                parser.abortParsing()
                return
            }
            let node = Node(name: elementName, attributes: attributeDict)
            stack.append(node)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.textBuffer.append(string)
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if let text = String(data: CDATABlock, encoding: .utf8) {
                stack.last?.textBuffer.append(text)
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            guard let finished = stack.popLast() else { return }
            if let parent = stack.last {
                parent.children.append((elementName, finished))
            } else {
                rootNode = finished
            }
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
            if parseFailureMessage == nil {
                parseFailureMessage = parseError.localizedDescription
            }
        }
    }

    private static func parseGenericXML(data: Data) throws -> [String: Any] {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false

        let delegate = XMLTreeParserDelegate(maxDepth: maxXMLNestingDepth)
        parser.delegate = delegate

        let success = parser.parse()
        guard success, let root = delegate.rootNode, delegate.parseFailureMessage == nil else {
            let reason = delegate.parseFailureMessage ?? parser.parserError?.localizedDescription ?? "Unknown XML parse error."
            throw ConversionError.invalidInput("Malformed XML: \(reason)")
        }

        return [root.name: root.toFoundationObject()]
    }

    private static func serializeToGenericXML(_ value: Any, rootElementName: String) -> String {
        var lines: [String] = ["<?xml version=\"1.0\" encoding=\"UTF-8\"?>"]
        appendXML(value: value, elementName: rootElementName, keyAttribute: nil, indentLevel: 0, lines: &lines)
        return lines.joined(separator: "\n") + "\n"
    }

    private static func appendXML(
        value: Any,
        elementName: String,
        keyAttribute: String?,
        indentLevel: Int,
        lines: inout [String]
    ) {
        let indent = String(repeating: "  ", count: indentLevel)
        let tag = sanitizeXMLTagName(elementName)
        let attrClause = keyAttribute.map { " key=\"\(escapeXMLAttribute($0))\"" } ?? ""

        switch value {
        case let dict as [AnyHashable: Any]:
            if dict.isEmpty {
                lines.append("\(indent)<\(tag)\(attrClause)/>")
                return
            }
            lines.append("\(indent)<\(tag)\(attrClause)>")
            let sortedKeys = dict.keys.map { ($0 as? String) ?? String(describing: $0) }.sorted()
            for rawKey in sortedKeys {
                guard let childVal = dict[rawKey] else { continue }
                let childTag = isValidXMLName(rawKey) ? rawKey : "entry"
                let childAttr = isValidXMLName(rawKey) ? nil : rawKey
                appendXML(value: childVal, elementName: childTag, keyAttribute: childAttr, indentLevel: indentLevel + 1, lines: &lines)
            }
            lines.append("\(indent)</\(tag)>")

        case let arr as [Any]:
            if arr.isEmpty {
                lines.append("\(indent)<\(tag)\(attrClause)/>")
                return
            }
            lines.append("\(indent)<\(tag)\(attrClause)>")
            for item in arr {
                appendXML(value: item, elementName: "item", keyAttribute: nil, indentLevel: indentLevel + 1, lines: &lines)
            }
            lines.append("\(indent)</\(tag)>")

        case is NSNull:
            lines.append("\(indent)<\(tag)\(attrClause) nil=\"true\"/>")

        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                lines.append("\(indent)<\(tag)\(attrClause)>\(number.boolValue ? "true" : "false")</\(tag)>")
            } else {
                lines.append("\(indent)<\(tag)\(attrClause)>\(escapeXMLText(number.stringValue))</\(tag)>")
            }

        case let bool as Bool:
            lines.append("\(indent)<\(tag)\(attrClause)>\(bool ? "true" : "false")</\(tag)>")

        case let str as String:
            lines.append("\(indent)<\(tag)\(attrClause)>\(escapeXMLText(str))</\(tag)>")

        default:
            lines.append("\(indent)<\(tag)\(attrClause)>\(escapeXMLText(String(describing: value)))</\(tag)>")
        }
    }

    private static func isValidXMLName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first else { return false }
        let isFirstValid = CharacterSet.letters.contains(first) || first == "_"
        guard isFirstValid else { return false }
        if name.lowercased().hasPrefix("xml") { return false }
        for scalar in name.unicodeScalars.dropFirst() {
            let valid = CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-" || scalar == "."
            if !valid { return false }
        }
        return true
    }

    private static func sanitizeXMLTagName(_ name: String) -> String {
        isValidXMLName(name) ? name : "item"
    }

    private static func stripInvalidXML10Scalars(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.count)
        for scalar in string.unicodeScalars {
            let v = scalar.value
            let valid = v == 0x9 || v == 0xA || v == 0xD
                || (v >= 0x20 && v <= 0xD7FF)
                || (v >= 0xE000 && v <= 0xFFFD)
                || (v >= 0x10000 && v <= 0x10FFFF)
            if valid {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private static func escapeXMLText(_ string: String) -> String {
        stripInvalidXML10Scalars(string)
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeXMLAttribute(_ string: String) -> String {
        escapeXMLText(string)
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    // MARK: - Private Helpers: RFC 5545 / vCard Parsing

    private struct ParsedContentLine {
        let name: String
        let parameters: [String: String]
        let value: String
    }

    private static func decodeTextData(_ data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8.hasPrefix("\u{FEFF}") ? String(utf8.dropFirst()) : utf8
        }
        if let utf16 = String(data: data, encoding: .utf16) {
            return utf16
        }
        if let latin1 = String(data: data, encoding: .isoLatin1) {
            return latin1
        }
        return nil
    }

    private static func unfoldRFC5545Lines(_ text: String) -> [String] {
        // Normalize CRLF -> LF, then remove LF + single SPACE or HTAB folding sequences.
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var unfolded = ""
        unfolded.reserveCapacity(normalized.count)

        var idx = normalized.startIndex
        while idx < normalized.endIndex {
            let ch = normalized[idx]
            if ch == "\n" {
                let next = normalized.index(after: idx)
                if next < normalized.endIndex && (normalized[next] == " " || normalized[next] == "\t") {
                    idx = normalized.index(after: next)
                    continue
                }
            }
            unfolded.append(ch)
            idx = normalized.index(after: idx)
        }

        return unfolded.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private static func unfoldVCardLines(_ text: String) -> [String] {
        // Handle standard RFC 2426/6350 folding (LF + space/tab) and vCard 2.1 QUOTED-PRINTABLE soft breaks (`=\n`)
        // strictly when the active line declares QUOTED-PRINTABLE before its value colon.
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let rawLines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var logicalLines: [String] = []

        for rawLine in rawLines {
            if let first = rawLine.first, (first == " " || first == "\t"), !logicalLines.isEmpty {
                logicalLines[logicalLines.count - 1].append(contentsOf: rawLine.dropFirst())
                continue
            }

            if let last = logicalLines.last,
               last.hasSuffix("="),
               isQuotedPrintableContinuationActive(in: last) {
                logicalLines[logicalLines.count - 1] = String(last.dropLast()) + rawLine
                continue
            }

            logicalLines.append(rawLine)
        }

        return logicalLines
    }

    private static func isQuotedPrintableContinuationActive(in line: String) -> Bool {
        guard let colonIdx = line.firstIndex(of: ":") else { return false }
        let header = line[..<colonIdx].uppercased()
        return header.contains("QUOTED-PRINTABLE")
    }

    private static func parseContentLine(_ line: String) -> ParsedContentLine? {
        var inQuotes = false
        var colonIndex: String.Index?

        var idx = line.startIndex
        while idx < line.endIndex {
            let ch = line[idx]
            if ch == "\"" {
                inQuotes.toggle()
            } else if ch == ":" && !inQuotes {
                colonIndex = idx
                break
            }
            idx = line.index(after: idx)
        }

        guard let colonIdx = colonIndex else { return nil }
        let left = String(line[..<colonIdx])
        let value = String(line[line.index(after: colonIdx)...])

        let segments = splitOutsideQuotes(left, delimiter: ";")
        guard let rawName = segments.first?.trimmingCharacters(in: .whitespaces), !rawName.isEmpty else {
            return nil
        }

        var params: [String: String] = [:]
        for paramSeg in segments.dropFirst() {
            let trimmedParam = paramSeg.trimmingCharacters(in: .whitespaces)
            guard !trimmedParam.isEmpty else { continue }
            if let eqIdx = trimmedParam.firstIndex(of: "=") {
                let key = String(trimmedParam[..<eqIdx]).trimmingCharacters(in: .whitespaces).uppercased()
                var val = String(trimmedParam[trimmedParam.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)
                if val.hasPrefix("\""), val.hasSuffix("\""), val.count >= 2 {
                    val = String(val.dropFirst().dropLast())
                }
                if let existing = params[key], !existing.isEmpty {
                    params[key] = "\(existing),\(val)"
                } else {
                    params[key] = val
                }
            } else {
                // vCard 2.1 bare type parameters (e.g. TEL;WORK;VOICE:...)
                let upper = trimmedParam.uppercased()
                if let existing = params["TYPE"], !existing.isEmpty {
                    params["TYPE"] = "\(existing),\(upper)"
                } else {
                    params["TYPE"] = upper
                }
            }
        }

        return ParsedContentLine(name: rawName, parameters: params, value: value)
    }

    private static func splitOutsideQuotes(_ text: String, delimiter: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        for ch in text {
            if ch == "\"" {
                inQuotes.toggle()
                current.append(ch)
            } else if ch == delimiter && !inQuotes {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        parts.append(current)
        return parts
    }

    private static func splitEscaped(_ text: String, delimiter: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var escaping = false

        for ch in text {
            if escaping {
                current.append("\\")
                current.append(ch)
                escaping = false
            } else if ch == "\\" {
                escaping = true
            } else if ch == delimiter {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        if escaping {
            current.append("\\")
        }
        parts.append(current)
        return parts
    }

    private static func stripGroupPrefix(_ name: String) -> String {
        if let dot = name.lastIndex(of: ".") {
            let afterDot = name[name.index(after: dot)...]
            if !afterDot.isEmpty {
                return String(afterDot)
            }
        }
        return name
    }

    private static func unescapeRFC5545Text(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var idx = text.startIndex
        while idx < text.endIndex {
            let ch = text[idx]
            if ch == "\\" {
                let next = text.index(after: idx)
                if next < text.endIndex {
                    let escaped = text[next]
                    switch escaped {
                    case "n", "N":
                        out.append("\n")
                    case ",", ";", "\\":
                        out.append(escaped)
                    default:
                        out.append(escaped)
                    }
                    idx = text.index(after: next)
                    continue
                }
            }
            out.append(ch)
            idx = text.index(after: idx)
        }
        return out
    }

    private static func decodeQuotedPrintable(_ input: String) -> String {
        var bytes: [UInt8] = []
        let chars = Array(input)
        var i = 0
        while i < chars.count {
            if chars[i] == "=", i + 2 < chars.count,
               let byte = UInt8(String([chars[i + 1], chars[i + 2]]), radix: 16) {
                bytes.append(byte)
                i += 3
            } else {
                bytes.append(contentsOf: String(chars[i]).utf8)
                i += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func formatAttendee(value: String, commonName: String?) -> String {
        let stripped = value.lowercased().hasPrefix("mailto:") ? String(value.dropFirst(7)) : value
        if let cn = commonName?.trimmingCharacters(in: .whitespacesAndNewlines), !cn.isEmpty {
            return "\(cn) <\(stripped)>"
        }
        return stripped
    }

    private static func extractVCardTypes(from parameters: [String: String]) -> [String] {
        guard let rawType = parameters["TYPE"], !rawType.isEmpty else { return [] }
        return rawType
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && $0 != "pref" && $0 != "internet" }
    }

    // MARK: - Private Helpers: Markdown Escaping

    private static func escapeMarkdownText(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    private static func escapeMarkdownLinkDestination(_ url: String) -> String {
        if url.contains(" ") || url.contains("(") || url.contains(")") {
            return "<\(url.replacingOccurrences(of: ">", with: "%3E"))>"
        }
        return url
    }
}
