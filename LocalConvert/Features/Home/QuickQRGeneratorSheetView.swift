import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Quick QR Generator Controller

@MainActor
final class QuickQRGeneratorController: ObservableObject {
    static let shared = QuickQRGeneratorController()

    @Published var isPresented: Bool = false

    init(isPresented: Bool = false) {
        self.isPresented = isPresented
    }

    func open() {
        isPresented = true
    }

    func dismiss() {
        isPresented = false
    }

    func toggle() {
        isPresented.toggle()
    }
}

// MARK: - Pure Testable QR Generator Engine

enum QuickQRGenerator: Sendable {

    enum PayloadKind: String, CaseIterable, Identifiable, Sendable {
        case url = "URL"
        case text = "Text"
        case wifi = "Wi-Fi"

        var id: String { rawValue }
    }

    enum WiFiEncryption: String, CaseIterable, Identifiable, Sendable {
        case wpa = "WPA"
        case wep = "WEP"
        case none = "None"

        var id: String { rawValue }

        var qrToken: String {
            switch self {
            case .wpa: return "WPA"
            case .wep: return "WEP"
            case .none: return "nopass"
            }
        }
    }

    static func escapeWiFiField(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count)
        for ch in value {
            switch ch {
            case "\\", ";", ",", "\"", ":":
                escaped.append("\\")
                escaped.append(ch)
            default:
                escaped.append(ch)
            }
        }
        return escaped
    }

    static func makeWiFiPayload(
        ssid: String,
        password: String,
        encryption: WiFiEncryption,
        isHidden: Bool = false
    ) -> String {
        let trimmedSSID = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSSID.isEmpty else { return "" }
        let safeSSID = escapeWiFiField(trimmedSSID)
        let safePass = encryption == .none ? "" : escapeWiFiField(password)
        let hiddenFlag = isHidden ? "true" : "false"
        return "WIFI:T:\(encryption.qrToken);S:\(safeSSID);P:\(safePass);H:\(hiddenFlag);;"
    }

    static func makePayload(
        kind: PayloadKind,
        urlOrText: String,
        wifiSSID: String,
        wifiPassword: String,
        wifiEncryption: WiFiEncryption,
        wifiHidden: Bool
    ) -> String {
        switch kind {
        case .url, .text:
            return urlOrText.trimmingCharacters(in: .whitespacesAndNewlines)
        case .wifi:
            return makeWiFiPayload(
                ssid: wifiSSID,
                password: wifiPassword,
                encryption: wifiEncryption,
                isHidden: wifiHidden
            )
        }
    }

    static func renderQRCodeCGImage(
        payload: String,
        scale: CGFloat = 12,
        quietZoneModules: CGFloat = 2
    ) -> CGImage? {
        guard !payload.isEmpty, let data = payload.data(using: .utf8) else {
            return nil
        }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else {
            return nil
        }

        let ciContext = CIContext(options: [.useSoftwareRenderer: false])
        guard let rawQR = ciContext.createCGImage(outputImage, from: outputImage.extent) else {
            return nil
        }

        let clampedScale = max(1, min(scale, 40))
        let moduleWidth = CGFloat(rawQR.width)
        let moduleHeight = CGFloat(rawQR.height)
        let padding = max(0, Int((quietZoneModules * clampedScale).rounded()))
        let pixelWidth = max(1, Int((moduleWidth * clampedScale).rounded()) + padding * 2)
        let pixelHeight = max(1, Int((moduleHeight * clampedScale).rounded()) + padding * 2)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil,
                  width: pixelWidth,
                  height: pixelHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        ctx.interpolationQuality = .none
        let drawRect = CGRect(
            x: padding,
            y: padding,
            width: pixelWidth - padding * 2,
            height: pixelHeight - padding * 2
        )
        ctx.draw(rawQR, in: drawRect)
        return ctx.makeImage()
    }

    static func renderQRCodePNGData(
        payload: String,
        scale: CGFloat = 12,
        quietZoneModules: CGFloat = 2
    ) -> Data? {
        guard let cgImage = renderQRCodeCGImage(
            payload: payload,
            scale: scale,
            quietZoneModules: quietZoneModules
        ) else {
            return nil
        }

        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return mutableData as Data
    }

    static func savePNGAtomically(data: Data, to destinationURL: URL) throws {
        let parentDir = destinationURL.deletingLastPathComponent()
        let tempURL = parentDir.appendingPathComponent(".LocalConvert-qr-\(UUID().uuidString).png")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }
        try data.write(to: tempURL, options: .atomic)
        _ = try OutputReservationCoordinator.moveOrReplaceTempFile(
            tempURL,
            to: destinationURL,
            policy: .overwrite
        )
    }
}

// MARK: - Quick QR Generator Sheet View

struct QuickQRGeneratorSheetView: View {
    @ObservedObject var controller: QuickQRGeneratorController

    @State private var payloadKind: QuickQRGenerator.PayloadKind = .url
    @State private var urlOrText: String = "https://"
    @State private var wifiSSID: String = ""
    @State private var wifiPassword: String = ""
    @State private var wifiEncryption: QuickQRGenerator.WiFiEncryption = .wpa
    @State private var wifiHidden: Bool = false
    @State private var showWiFiPassword: Bool = false
    @State private var exportScale: CGFloat = 14
    @State private var statusBanner: String? = nil
    @State private var errorMessage: String? = nil

    init(controller: QuickQRGeneratorController = .shared) {
        self.controller = controller
    }

    private var activePayload: String {
        QuickQRGenerator.makePayload(
            kind: payloadKind,
            urlOrText: urlOrText,
            wifiSSID: wifiSSID,
            wifiPassword: wifiPassword,
            wifiEncryption: wifiEncryption,
            wifiHidden: wifiHidden
        )
    }

    private var previewCGImage: CGImage? {
        QuickQRGenerator.renderQRCodeCGImage(payload: activePayload, scale: 10, quietZoneModules: 2)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            AppDivider()

            HStack(alignment: .top, spacing: AppTheme.Spacing.lg) {
                inputColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                previewColumn
                    .frame(width: 230)
            }
            .padding(AppTheme.Spacing.xl)

            if let errorMessage {
                AppInfoBanner(
                    style: .error,
                    message: errorMessage,
                    onDismiss: { self.errorMessage = nil }
                )
                .padding(.horizontal, AppTheme.Spacing.xl)
                .padding(.bottom, AppTheme.Spacing.md)
            } else if let statusBanner {
                AppInfoBanner(
                    style: .success,
                    message: statusBanner,
                    onDismiss: { self.statusBanner = nil }
                )
                .padding(.horizontal, AppTheme.Spacing.xl)
                .padding(.bottom, AppTheme.Spacing.md)
            }

            AppDivider()
            footerBar
        }
        .frame(minWidth: 560, idealWidth: 620, maxWidth: 680, minHeight: 430, idealHeight: 470, maxHeight: 540)
        .appWorkspaceSurface()
        .onExitCommand {
            controller.dismiss()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quickQR.sheet")
    }

    private var headerBar: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(AppTheme.Colors.accentTint)
                    .frame(width: 32, height: 32)
                Image(systemName: "qrcode")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.accent)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text("Quick QR Generator")
                    .font(AppTheme.Typography.pageTitle)
                    .foregroundStyle(.primary)

                Text("Generate crisp 100% offline QR codes for URLs, text, or Wi-Fi")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: AppTheme.Spacing.sm)

            Button("Done") {
                controller.dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("quickQR.doneButton")
        }
        .padding(.horizontal, AppTheme.Spacing.xl)
        .padding(.vertical, AppTheme.Spacing.md)
        .background(AppTheme.Colors.subtleSurface)
    }

    private var inputColumn: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Picker("QR Type", selection: $payloadKind) {
                ForEach(QuickQRGenerator.PayloadKind.allCases) { kind in
                    Text(LocalizedStringKey(kind.rawValue)).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("QR Payload Type")
            .accessibilityIdentifier("quickQR.typePicker")

            switch payloadKind {
            case .url:
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text("Website URL")
                        .font(AppTheme.Typography.cardTitle)
                    TextField("https://example.com", text: $urlOrText)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("quickQR.urlField")
                }

            case .text:
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text("Plain Text")
                        .font(AppTheme.Typography.cardTitle)
                    TextEditor(text: $urlOrText)
                        .font(AppTheme.Typography.body)
                        .frame(minHeight: 110, maxHeight: 145)
                        .padding(AppTheme.Spacing.xs)
                        .background(AppTheme.Colors.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                        .overlay(
                            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                                .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
                        )
                        .accessibilityIdentifier("quickQR.textEditor")
                }

            case .wifi:
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        Text("Network Name (SSID)")
                            .font(AppTheme.Typography.cardTitle)
                        TextField("MyNetwork", text: $wifiSSID)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("quickQR.wifiSSIDField")
                    }

                    HStack(spacing: AppTheme.Spacing.md) {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                            Text("Security")
                                .font(AppTheme.Typography.cardTitle)
                            Picker("Security", selection: $wifiEncryption) {
                                ForEach(QuickQRGenerator.WiFiEncryption.allCases) { enc in
                                    Text(LocalizedStringKey(enc.rawValue)).tag(enc)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 110)
                            .accessibilityIdentifier("quickQR.wifiSecurityPicker")
                        }

                        Toggle("Hidden Network", isOn: $wifiHidden)
                            .padding(.top, AppTheme.Spacing.md)
                            .accessibilityIdentifier("quickQR.wifiHiddenToggle")
                    }

                    if wifiEncryption != .none {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                            Text("Password")
                                .font(AppTheme.Typography.cardTitle)
                            HStack(spacing: AppTheme.Spacing.xs) {
                                if showWiFiPassword {
                                    TextField("Wi-Fi Password", text: $wifiPassword)
                                        .textFieldStyle(.roundedBorder)
                                } else {
                                    SecureField("Wi-Fi Password", text: $wifiPassword)
                                        .textFieldStyle(.roundedBorder)
                                }
                                Button {
                                    showWiFiPassword.toggle()
                                } label: {
                                    Image(systemName: showWiFiPassword ? "eye.slash" : "eye")
                                }
                                .buttonStyle(.bordered)
                                .accessibilityLabel(showWiFiPassword ? "Hide Password" : "Show Password")
                            }
                            .accessibilityIdentifier("quickQR.wifiPasswordField")
                        }
                    }
                }
            }

            HStack(spacing: AppTheme.Spacing.sm) {
                Text("Export Resolution")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(.secondary)
                Picker("Export Resolution", selection: $exportScale) {
                    Text("Standard").tag(CGFloat(10))
                    Text("High-Res").tag(CGFloat(14))
                    Text("Print").tag(CGFloat(22))
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
                .accessibilityLabel("Export Resolution")
            }

            Spacer(minLength: 0)
        }
    }

    private var previewColumn: some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            ZStack {
                RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                    .fill(Color.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                            .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
                    )

                if let cgImage = previewCGImage {
                    Image(decorative: cgImage, scale: 1.0)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .padding(AppTheme.Spacing.md)
                        .accessibilityLabel("QR Code Preview")
                } else {
                    VStack(spacing: AppTheme.Spacing.xs) {
                        Image(systemName: "qrcode")
                            .font(.system(size: 36))
                            .foregroundStyle(Color.secondary)
                        Text("Enter content to generate QR")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(Color.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(AppTheme.Spacing.md)
                }
            }
            .frame(width: 210, height: 210)
            .accessibilityIdentifier("quickQR.previewBox")

            if !activePayload.isEmpty {
                Text("\(activePayload.count) characters")
                    .font(AppTheme.Typography.monoCaption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footerBar: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Label("100% On-Device", systemImage: "lock.shield")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Button {
                copyPNGToClipboard()
            } label: {
                Label("Copy PNG", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(.bordered)
            .disabled(activePayload.isEmpty)
            .accessibilityIdentifier("quickQR.copyPNGButton")

            Button {
                savePNGWithPanel()
            } label: {
                Label("Save PNG...", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .disabled(activePayload.isEmpty)
            .accessibilityIdentifier("quickQR.savePNGButton")
        }
        .padding(.horizontal, AppTheme.Spacing.xl)
        .padding(.vertical, AppTheme.Spacing.md)
        .background(AppTheme.Colors.subtleSurface)
    }

    private func copyPNGToClipboard() {
        errorMessage = nil
        guard let pngData = QuickQRGenerator.renderQRCodePNGData(payload: activePayload, scale: exportScale) else {
            errorMessage = String(localized: "Unable to render QR code image.")
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(pngData, forType: .png)
        if let nsImage = NSImage(data: pngData) {
            pasteboard.writeObjects([nsImage])
        }
        statusBanner = String(localized: "QR code PNG copied to clipboard.")
    }

    private func savePNGWithPanel() {
        errorMessage = nil
        guard let pngData = QuickQRGenerator.renderQRCodePNGData(payload: activePayload, scale: exportScale) else {
            errorMessage = String(localized: "Unable to render QR code image.")
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "LocalConvert-QR.png"
        panel.prompt = String(localized: "Save")

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            return
        }

        do {
            try QuickQRGenerator.savePNGAtomically(data: pngData, to: destinationURL)
            statusBanner = String(localized: "Saved QR code PNG.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
