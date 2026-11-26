import XCTest
import Foundation
@testable import LocalConvert

final class Milestone8CAppleDataFormatsTests: XCTestCase {

    private var workspaceDir: URL!
    private var inputDir: URL!
    private var outputDir: URL!
    private var engine: TextConversionEngine!

    override func setUpWithError() throws {
        try super.setUpWithError()
        ConversionManager.clearReservedOutputURLs()
        workspaceDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-M8C-Data-\(UUID().uuidString)", isDirectory: true)
        inputDir = workspaceDir.appendingPathComponent("input", isDirectory: true)
        outputDir = workspaceDir.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: inputDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        engine = TextConversionEngine()
    }

    override func tearDownWithError() throws {
        ConversionManager.clearReservedOutputURLs()
        if let workspaceDir {
            try? FileManager.default.removeItem(at: workspaceDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func convert(
        _ inputURL: URL,
        to outputFormat: FileFormat,
        options: ConversionOptions = .default
    ) async throws -> ConversionResult {
        try await engine.convert(
            inputs: [inputURL],
            to: outputFormat,
            outputDirectory: outputDir,
            options: options,
            progress: { _ in }
        )
    }

    // MARK: - 1. Capabilities & Format Contract

    func testEngineSupportedFormatsAndCapabilities() {
        XCTAssertTrue(engine.supportedInputFormats.isSuperset(of: [.csv, .tsv, .plist, .json, .xml, .webloc, .ics, .vcf]))
        XCTAssertTrue(engine.supportedOutputFormats.isSuperset(of: [.csv, .tsv, .plist, .json, .xml, .txt, .md]))

        // Read-only formats must never be advertised as writable outputs
        XCTAssertFalse(engine.supportedOutputFormats.contains(.webloc))
        XCTAssertFalse(engine.supportedOutputFormats.contains(.ics))
        XCTAssertFalse(engine.supportedOutputFormats.contains(.vcf))

        XCTAssertEqual(engine.availableOutputFormats(for: .plist), [.json, .xml])
        XCTAssertEqual(engine.availableOutputFormats(for: .json), [.plist, .xml])
        XCTAssertEqual(engine.availableOutputFormats(for: .xml), [.plist, .json])
        XCTAssertEqual(engine.availableOutputFormats(for: .webloc), [.json, .txt, .md, .csv])
        XCTAssertEqual(engine.availableOutputFormats(for: .ics), [.json, .csv, .txt])
        XCTAssertEqual(engine.availableOutputFormats(for: .vcf), [.json, .csv, .txt])
        XCTAssertEqual(engine.availableOutputFormats(for: .csv), [.tsv])
        XCTAssertEqual(engine.availableOutputFormats(for: .tsv), [.csv])
    }

    // MARK: - 2. Property Lists (.plist <-> .json / .xml)

    func testBinaryPlistToJSONPreservesDateDataAndBoolSafely() async throws {
        let sampleDate = Date(timeIntervalSince1970: 1_760_000_000.25)
        let sampleData = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02])
        let plistDict: [String: Any] = [
            "appName": "LocalConvert",
            "version": 1,
            "zero": 0,
            "ratio": 0.95,
            "enabled": true,
            "disabled": false,
            "createdAt": sampleDate,
            "payload": sampleData,
            "tags": ["apple", "swift6"],
            "nested": [
                "timestamp": sampleDate,
                "blob": sampleData
            ] as [String: Any]
        ]

        let binaryPlistData = try PropertyListSerialization.data(fromPropertyList: plistDict, format: .binary, options: 0)
        let inputURL = inputDir.appendingPathComponent("binary_sample.plist")
        try binaryPlistData.write(to: inputURL)

        XCTAssertEqual(FileDetector.detectFormat(url: inputURL), .plist)

        let result = try await convert(inputURL, to: .json)
        XCTAssertEqual(result.outputFormat, .json)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputURL.path))

        let jsonData = try Data(contentsOf: result.outputURL)
        let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: jsonData) as? [String: Any])

        XCTAssertEqual(parsed["appName"] as? String, "LocalConvert")
        let versionNum = try XCTUnwrap(parsed["version"] as? NSNumber)
        XCTAssertNotEqual(CFGetTypeID(versionNum), CFBooleanGetTypeID())
        XCTAssertEqual(versionNum.intValue, 1)
        let zeroNum = try XCTUnwrap(parsed["zero"] as? NSNumber)
        XCTAssertNotEqual(CFGetTypeID(zeroNum), CFBooleanGetTypeID())
        XCTAssertEqual(zeroNum.intValue, 0)
        let enabledNum = try XCTUnwrap(parsed["enabled"] as? NSNumber)
        XCTAssertEqual(CFGetTypeID(enabledNum), CFBooleanGetTypeID())
        XCTAssertEqual(enabledNum.boolValue, true)
        let disabledNum = try XCTUnwrap(parsed["disabled"] as? NSNumber)
        XCTAssertEqual(CFGetTypeID(disabledNum), CFBooleanGetTypeID())
        XCTAssertEqual(disabledNum.boolValue, false)
        XCTAssertEqual(parsed["payload"] as? String, sampleData.base64EncodedString())

        let createdAtStr = try XCTUnwrap(parsed["createdAt"] as? String)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let roundTrippedDate = try XCTUnwrap(iso.date(from: createdAtStr))
        XCTAssertEqual(roundTrippedDate.timeIntervalSince1970, sampleDate.timeIntervalSince1970, accuracy: 0.01)

        let nested = try XCTUnwrap(parsed["nested"] as? [String: Any])
        XCTAssertEqual(nested["blob"] as? String, sampleData.base64EncodedString())
    }

    func testXMLPlistToJSONAndBinaryPlistToXML() async throws {
        let sampleDate = Date(timeIntervalSince1970: 1_700_000_000)
        let sampleData = Data("hello-plist".utf8)
        let dict: [String: Any] = [
            "title": "Settings",
            "count": 42,
            "updated": sampleDate,
            "secret": sampleData
        ]

        // 1. XML plist -> JSON
        let xmlData = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        let xmlPlistURL = inputDir.appendingPathComponent("xml_sample.plist")
        try xmlData.write(to: xmlPlistURL)

        let jsonResult = try await convert(xmlPlistURL, to: .json)
        let jsonObj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: jsonResult.outputURL)) as? [String: Any])
        XCTAssertEqual(jsonObj["title"] as? String, "Settings")
        XCTAssertEqual(jsonObj["count"] as? Int, 42)
        XCTAssertEqual(jsonObj["secret"] as? String, sampleData.base64EncodedString())

        // 2. Binary plist -> XML
        let binData = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
        let binPlistURL = inputDir.appendingPathComponent("bin_to_xml.plist")
        try binData.write(to: binPlistURL)

        let xmlResult = try await convert(binPlistURL, to: .xml)
        let outXMLData = try Data(contentsOf: xmlResult.outputURL)
        let xmlString = try XCTUnwrap(String(data: outXMLData, encoding: .utf8))
        XCTAssertTrue(xmlString.contains("<plist"))

        var format = PropertyListSerialization.PropertyListFormat.binary
        let reloaded = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: outXMLData, options: [], format: &format) as? [String: Any]
        )
        XCTAssertEqual(format, .xml)
        XCTAssertEqual(reloaded["title"] as? String, "Settings")
        XCTAssertEqual(reloaded["secret"] as? Data, sampleData)
    }

    func testJSONToPlistAndXMLRoundTrip() async throws {
        let jsonString = """
        {
          "name": "LocalConvert",
          "active": true,
          "count": 7,
          "nullableField": null,
          "items": ["alpha", null, "beta & <gamma>"]
        }
        """
        let jsonURL = inputDir.appendingPathComponent("config.json")
        try Data(jsonString.utf8).write(to: jsonURL)

        // JSON -> XML plist
        let plistResult = try await convert(jsonURL, to: .plist)
        var fmt = PropertyListSerialization.PropertyListFormat.binary
        let plistObj = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: Data(contentsOf: plistResult.outputURL), options: [], format: &fmt) as? [String: Any]
        )
        XCTAssertEqual(fmt, .xml)
        XCTAssertEqual(plistObj["name"] as? String, "LocalConvert")
        XCTAssertEqual(plistObj["active"] as? Bool, true)
        XCTAssertEqual(plistObj["count"] as? Int, 7)
        XCTAssertNil(plistObj["nullableField"])

        // JSON -> Binary plist via customOption
        var binOptions = ConversionOptions.default
        binOptions.customOptions["plist_format"] = "binary"
        let binPlistResult = try await convert(jsonURL, to: .plist, options: binOptions)
        var binFmt = PropertyListSerialization.PropertyListFormat.xml
        let binObj = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: Data(contentsOf: binPlistResult.outputURL), options: [], format: &binFmt) as? [String: Any]
        )
        XCTAssertEqual(binFmt, .binary)
        XCTAssertEqual(binObj["name"] as? String, "LocalConvert")

        // JSON -> generic XML -> JSON
        let xmlResult = try await convert(jsonURL, to: .xml)
        let xmlText = try String(contentsOf: xmlResult.outputURL, encoding: .utf8)
        XCTAssertTrue(xmlText.contains("beta &amp; &lt;gamma&gt;"))

        let jsonRoundTrip = try await convert(xmlResult.outputURL, to: .json)
        let roundTripObj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: jsonRoundTrip.outputURL)) as? [String: Any]
        )
        let root = try XCTUnwrap(roundTripObj["root"] as? [String: Any])
        XCTAssertEqual(root["name"] as? String, "LocalConvert")
    }

    func testXMLFileContainingPlistPreservesNativeTypes() async throws {
        let dataBlob = Data([1, 2, 3, 4])
        let plistXML = try PropertyListSerialization.data(
            fromPropertyList: ["blob": dataBlob, "flag": true],
            format: .xml,
            options: 0
        )
        let xmlURL = inputDir.appendingPathComponent("wrapped_plist.xml")
        try plistXML.write(to: xmlURL)

        let jsonRes = try await convert(xmlURL, to: .json)
        let parsed = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: jsonRes.outputURL)) as? [String: Any]
        )
        XCTAssertEqual(parsed["blob"] as? String, dataBlob.base64EncodedString())
        XCTAssertEqual(parsed["flag"] as? Bool, true)
    }

    // MARK: - 3. Webloc (.webloc -> .txt, .json, .md, .csv)

    func testXMLWeblocToTXTJSONMarkdownAndCSV() async throws {
        let weblocDict: [String: Any] = [
            "URL": "https://developer.apple.com/documentation/swift?q=concurrency&lang=6",
            "title": "Swift Concurrency [Docs]",
            "author": "Apple"
        ]
        let xmlData = try PropertyListSerialization.data(fromPropertyList: weblocDict, format: .xml, options: 0)
        let weblocURL = inputDir.appendingPathComponent("swift_docs.webloc")
        try xmlData.write(to: weblocURL)

        XCTAssertEqual(FileDetector.detectFormat(url: weblocURL), .webloc)

        let txtResult = try await convert(weblocURL, to: .txt)
        let txt = try String(contentsOf: txtResult.outputURL, encoding: .utf8)
        XCTAssertTrue(txt.contains("Title: Swift Concurrency [Docs]"))
        XCTAssertTrue(txt.contains("URL: https://developer.apple.com/documentation/swift?q=concurrency&lang=6"))
        XCTAssertTrue(txt.contains("author: Apple"))

        let mdResult = try await convert(weblocURL, to: .md)
        let md = try String(contentsOf: mdResult.outputURL, encoding: .utf8)
        XCTAssertTrue(md.contains("# Swift Concurrency \\[Docs\\]"))
        XCTAssertTrue(md.contains("[Swift Concurrency \\[Docs\\]](https://developer.apple.com/documentation/swift?q=concurrency&lang=6)"))

        let jsonResult = try await convert(weblocURL, to: .json)
        let jsonObj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: jsonResult.outputURL)) as? [String: Any]
        )
        XCTAssertEqual(jsonObj["url"] as? String, "https://developer.apple.com/documentation/swift?q=concurrency&lang=6")
        XCTAssertEqual(jsonObj["title"] as? String, "Swift Concurrency [Docs]")
        let meta = try XCTUnwrap(jsonObj["metadata"] as? [String: Any])
        XCTAssertEqual(meta["author"] as? String, "Apple")

        let csvResult = try await convert(weblocURL, to: .csv)
        let csv = try String(contentsOf: csvResult.outputURL, encoding: .utf8)
        XCTAssertTrue(csv.hasPrefix("title,url,source_file,metadata\n"))
        XCTAssertTrue(csv.contains("https://developer.apple.com/documentation/swift?q=concurrency&lang=6"))
    }

    func testBinaryWeblocWithoutExplicitTitleFallsBackToFilename() async throws {
        let binData = try PropertyListSerialization.data(
            fromPropertyList: ["URL": "https://example.org/apple-ecosystem"],
            format: .binary,
            options: 0
        )
        let weblocURL = inputDir.appendingPathComponent("Bookmark Alias.webloc")
        try binData.write(to: weblocURL)

        XCTAssertEqual(FileDetector.detectFormat(url: weblocURL), .webloc)

        let jsonRes = try await convert(weblocURL, to: .json)
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: jsonRes.outputURL)) as? [String: Any]
        )
        XCTAssertEqual(obj["url"] as? String, "https://example.org/apple-ecosystem")
        XCTAssertEqual(obj["title"] as? String, "Bookmark Alias")

        let mdRes = try await convert(weblocURL, to: .md)
        let md = try String(contentsOf: mdRes.outputURL, encoding: .utf8)
        XCTAssertTrue(md.contains("[Bookmark Alias](https://example.org/apple-ecosystem)"))
    }

    // MARK: - 4. iCalendar (.ics -> .json, .csv, .txt)

    func testICalendarWithFoldedLinesEscapedTextAndNestedAlarmExportsCleanly() async throws {
        let ics = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//LocalConvert//Test Calendar//EN",
            "X-WR-CALNAME:Team Schedule",
            "X-WR-TIMEZONE:America/New_York",
            "BEGIN:VTIMEZONE",
            "TZID:America/New_York",
            "BEGIN:STANDARD",
            "DTSTART:19701101T020000",
            "END:STANDARD",
            "END:VTIMEZONE",
            "BEGIN:VEVENT",
            "UID:evt-1001@localconvert.test",
            "DTSTART;TZID=\"America/New_York\":20261201T090000",
            "DTEND;TZID=\"America/New_York\":20261201T103000",
            "SUMMARY:Quarterly Review\\, Part 1\\; Engineering",
            "LOCATION:Room 402\\, Building B",
            "DESCRIPTION:Agenda line 1\\nAgenda ",
            " continued line\\nEscaped backslash: \\\\",
            "STATUS:CONFIRMED",
            "ORGANIZER;CN=\"Alice Smith\":mailto:alice@example.com",
            "ATTENDEE;CN=\"Bob, Jr.\";PARTSTAT=ACCEPTED:mailto:bob@example.com",
            "RRULE:FREQ=WEEKLY;COUNT=4",
            "BEGIN:VALARM",
            "ACTION:DISPLAY",
            "DESCRIPTION:Reminder should NOT overwrite VEVENT description",
            "TRIGGER:-PT15M",
            "END:VALARM",
            "END:VEVENT",
            "BEGIN:VTODO",
            "UID:todo-2002@localconvert.test",
            "SUMMARY:Ship Milestone 8C",
            "DUE:20261205T170000Z",
            "STATUS:NEEDS-ACTION",
            "END:VTODO",
            "END:VCALENDAR"
        ].joined(separator: "\r\n")

        let icsURL = inputDir.appendingPathComponent("schedule.ics")
        try Data(ics.utf8).write(to: icsURL)
        XCTAssertEqual(FileDetector.detectFormat(url: icsURL), .ics)

        // JSON
        let jsonRes = try await convert(icsURL, to: .json)
        let jsonObj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: jsonRes.outputURL)) as? [String: Any]
        )
        let cal = try XCTUnwrap(jsonObj["calendar"] as? [String: Any])
        XCTAssertEqual(cal["name"] as? String, "Team Schedule")
        XCTAssertEqual(cal["version"] as? String, "2.0")

        let events = try XCTUnwrap(jsonObj["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        let evt = events[0]
        XCTAssertEqual(evt["summary"] as? String, "Quarterly Review, Part 1; Engineering")
        XCTAssertEqual(evt["location"] as? String, "Room 402, Building B")
        XCTAssertEqual(evt["description"] as? String, "Agenda line 1\nAgenda continued line\nEscaped backslash: \\")
        XCTAssertEqual(evt["organizer"] as? String, "Alice Smith <alice@example.com>")
        XCTAssertEqual(evt["attendees"] as? [String], ["Bob, Jr. <bob@example.com>"])

        let todos = try XCTUnwrap(jsonObj["todos"] as? [[String: Any]])
        XCTAssertEqual(todos.count, 1)
        XCTAssertEqual(todos[0]["summary"] as? String, "Ship Milestone 8C")

        // CSV (RFC 4180 escaping for commas & newlines)
        let csvRes = try await convert(icsURL, to: .csv)
        let csv = try String(contentsOf: csvRes.outputURL, encoding: .utf8)
        XCTAssertTrue(csv.hasPrefix("type,uid,summary,start,end,location,description,status,organizer,attendees,rrule\n"))
        XCTAssertTrue(csv.contains("\"Quarterly Review, Part 1; Engineering\""))
        XCTAssertTrue(csv.contains("\"Agenda line 1\nAgenda continued line\nEscaped backslash: \\\""))
        XCTAssertTrue(csv.contains("VTODO,todo-2002@localconvert.test,Ship Milestone 8C"))

        // TXT
        let txtRes = try await convert(icsURL, to: .txt)
        let txt = try String(contentsOf: txtRes.outputURL, encoding: .utf8)
        XCTAssertTrue(txt.contains("Calendar: Team Schedule"))
        XCTAssertTrue(txt.contains("[VEVENT] Quarterly Review, Part 1; Engineering"))
        XCTAssertTrue(txt.contains("[VTODO] Ship Milestone 8C"))
    }

    // MARK: - 5. vCard (.vcf -> .json, .csv, .txt)

    func testVCardMultiContactWithFoldedLinesGroupPrefixesAndEscapes() async throws {
        let vcf = [
            "BEGIN:VCARD",
            "VERSION:3.0",
            "N:Appleseed;John;Q.;Mr.;Jr.",
            "FN:John Appleseed",
            "ORG:Apple Inc.;Developer Tools",
            "TITLE:Staff Engineer",
            "item1.EMAIL;type=INTERNET;type=WORK;type=pref:john@apple.example",
            "TEL;TYPE=CELL:+1-555-0100",
            "item2.ADR;type=HOME:;;1 Infinite Loop;Cupertino;CA;95014;USA",
            "URL:https://example.com/?token=",
            "NOTE:Met at WWDC\\, discussed \"Swift 6\"\\nand concurrency\\; follow up.",
            "BDAY:1985-04-01",
            "END:VCARD",
            "BEGIN:VCARD",
            "VERSION:4.0",
            "FN:Jane ",
            " Doe",
            "EMAIL;TYPE=HOME:jane@example.org",
            "NOTE;ENCODING=QUOTED-PRINTABLE:Line1=0ALine2=",
            "Continued",
            "END:VCARD"
        ].joined(separator: "\r\n")

        let vcfURL = inputDir.appendingPathComponent("contacts.vcf")
        try Data(vcf.utf8).write(to: vcfURL)
        XCTAssertEqual(FileDetector.detectFormat(url: vcfURL), .vcf)

        // JSON
        let jsonRes = try await convert(vcfURL, to: .json)
        let jsonObj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: jsonRes.outputURL)) as? [String: Any]
        )
        let contacts = try XCTUnwrap(jsonObj["contacts"] as? [[String: Any]])
        XCTAssertEqual(contacts.count, 2)

        let john = contacts[0]
        XCTAssertEqual(john["fullName"] as? String, "John Appleseed")
        XCTAssertEqual(john["organization"] as? String, "Apple Inc. — Developer Tools")
        XCTAssertEqual((john["urls"] as? [[String: Any]])?.first?["value"] as? String, "https://example.com/?token=")
        XCTAssertEqual(john["note"] as? String, "Met at WWDC, discussed \"Swift 6\"\nand concurrency; follow up.")
        XCTAssertEqual((john["addresses"] as? [[String: Any]])?.first?["value"] as? String, "1 Infinite Loop, Cupertino, CA, 95014, USA")

        let jane = contacts[1]
        XCTAssertEqual(jane["fullName"] as? String, "Jane Doe")
        XCTAssertEqual(jane["note"] as? String, "Line1\nLine2Continued")

        // CSV (RFC 4180 quotes around embedded double-quotes, commas, and newlines)
        let csvRes = try await convert(vcfURL, to: .csv)
        let csv = try String(contentsOf: csvRes.outputURL, encoding: .utf8)
        XCTAssertTrue(csv.hasPrefix("full_name,first_name,last_name,organization,title,emails,phones,addresses,urls,birthday,note\n"))
        XCTAssertTrue(csv.contains("\"\"Swift 6\"\""))
        XCTAssertTrue(csv.contains("Jane Doe"))

        // TXT
        let txtRes = try await convert(vcfURL, to: .txt)
        let txt = try String(contentsOf: txtRes.outputURL, encoding: .utf8)
        XCTAssertTrue(txt.contains("Name: John Appleseed"))
        XCTAssertTrue(txt.contains("Name: Jane Doe"))
        XCTAssertTrue(txt.contains("Email (work): john@apple.example"))
    }

    // MARK: - 6. Malformed Input Rejection & Atomic Commit Guarantees

    func testMalformedInputsThrowInvalidInputWithoutLeavingOutputsOrTempFiles() async throws {
        let cases: [(filename: String, content: Data, target: FileFormat)] = [
            ("empty.plist", Data(), .json),
            ("corrupt.plist", Data("not-a-valid-plist-at-all".utf8), .json),
            ("truncated_xml.plist", Data("<?xml version=\"1.0\"?><plist><dict><key>broken</key>".utf8), .json),
            ("json_in_plist.plist", Data("{\"hello\": \"world\"}".utf8), .json),
            ("corrupt.json", Data("{bad json".utf8), .plist),
            ("null_root.json", Data("null".utf8), .plist),
            ("corrupt.xml", Data("<root><unclosed></root>".utf8), .json),
            ("missing_url.webloc", try PropertyListSerialization.data(fromPropertyList: ["Title": "No URL"], format: .xml, options: 0), .txt),
            ("empty_url.webloc", try PropertyListSerialization.data(fromPropertyList: ["URL": "   "], format: .xml, options: 0), .json),
            ("garbage.ics", Data("HELLO WORLD NOT ICS".utf8), .json),
            ("unclosed.ics", Data("BEGIN:VCALENDAR\nBEGIN:VEVENT\nSUMMARY:Oops\nEND:VCALENDAR".utf8), .csv),
            ("garbage.vcf", Data("NOT A VCARD".utf8), .json),
            ("unclosed.vcf", Data("BEGIN:VCARD\nFN:Incomplete".utf8), .txt)
        ]

        let tempBefore = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path))?
                .filter { $0.hasPrefix("LocalConvert-Text-") } ?? []
        )

        for testCase in cases {
            let url = inputDir.appendingPathComponent(testCase.filename)
            try testCase.content.write(to: url)

            do {
                _ = try await convert(url, to: testCase.target)
                XCTFail("Expected malformed input '\(testCase.filename)' to fail")
            } catch let error as ConversionError {
                guard case .invalidInput = error else {
                    XCTFail("Expected ConversionError.invalidInput for '\(testCase.filename)', got \(error)")
                    continue
                }
            }
        }

        let outputFiles = try FileManager.default.contentsOfDirectory(atPath: outputDir.path)
        XCTAssertTrue(outputFiles.isEmpty, "Malformed inputs must not create any output files: \(outputFiles)")

        let tempAfter = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path))?
                .filter { $0.hasPrefix("LocalConvert-Text-") } ?? []
        )
        XCTAssertEqual(tempBefore, tempAfter, "No LocalConvert-Text-* temp files should leak after errors")
    }

    func testAtomicPublishRespectsSkipCreateUniqueAndOverwritePolicies() async throws {
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: ["key": "updated-value"],
            format: .xml,
            options: 0
        )
        let inputURL = inputDir.appendingPathComponent("atomic.plist")
        try plistData.write(to: inputURL)

        let existingDest = outputDir.appendingPathComponent("atomic.json")
        let sentinelBytes = Data("DO-NOT-CORRUPT-SENTINEL".utf8)
        try sentinelBytes.write(to: existingDest)

        // 1. Skip policy throws outputFileAlreadyExists and preserves existing bytes
        var skipOptions = ConversionOptions.default
        skipOptions.customOptions["existing_file_handling"] = ExistingFileHandling.skip.rawValue
        do {
            _ = try await convert(inputURL, to: .json, options: skipOptions)
            XCTFail("Expected outputFileAlreadyExists when policy is .skip")
        } catch let error as ConversionError {
            XCTAssertEqual(error, .outputFileAlreadyExists(existingDest))
        }
        XCTAssertEqual(try Data(contentsOf: existingDest), sentinelBytes)

        // 2. Default createUnique preserves sentinel and creates a unique file
        let uniqueRes = try await convert(inputURL, to: .json, options: .default)
        XCTAssertNotEqual(uniqueRes.outputURL.standardizedFileURL, existingDest.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: existingDest), sentinelBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: uniqueRes.outputURL.path))

        // 3. Overwrite policy atomically replaces existingDest without leaving .stage-/.bak- artifacts
        var overwriteOptions = ConversionOptions.default
        overwriteOptions.overwriteExisting = true
        let overwriteRes = try await convert(inputURL, to: .json, options: overwriteOptions)
        XCTAssertEqual(overwriteRes.outputURL.standardizedFileURL, existingDest.standardizedFileURL)

        let overwrittenObj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: existingDest)) as? [String: Any]
        )
        XCTAssertEqual(overwrittenObj["key"] as? String, "updated-value")

        let dirEntries = try FileManager.default.contentsOfDirectory(atPath: outputDir.path)
        XCTAssertFalse(dirEntries.contains { $0.contains(".stage-") || $0.contains(".bak-") })
    }

    func testCSVToTSVAtomicCommitPreservesExistingBehavior() async throws {
        let csvContent = "Name,Notes\nAlice,\"Hello, world\"\nBob,\"Has\ttab and \"\"quote\"\"\""
        let csvURL = inputDir.appendingPathComponent("table.csv")
        try Data(csvContent.utf8).write(to: csvURL)

        let res = try await convert(csvURL, to: .tsv)
        let tsv = try String(contentsOf: res.outputURL, encoding: .utf8)
        XCTAssertEqual(tsv, "Name\tNotes\nAlice\tHello, world\nBob\t\"Has\ttab and \"\"quote\"\"\"")
    }
}
