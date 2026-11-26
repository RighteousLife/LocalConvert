import Foundation
import CoreGraphics
import ImageIO

// MARK: - Image Metadata Inspection & Sanitization Service

struct ImageMetadataPrivacySummary: Sendable, Equatable {
    let hasGPS: Bool
    let hasCameraHardwareInfo: Bool
    let hasAuthorOrCopyright: Bool
    let hasDescriptionOrKeywords: Bool
    let hasICCProfile: Bool
    let iccProfileName: String
    let isJXLContainer: Bool
    let isJPEGReconstructable: Bool
    let document: MetadataDocument

    var hasAnySensitiveMetadata: Bool {
        hasGPS || hasCameraHardwareInfo || hasAuthorOrCopyright || hasDescriptionOrKeywords
    }
}

enum ImageMetadataService {

    private static let provider = ImageMetadataProvider()

    static func inspect(url: URL) async throws -> ImageMetadataPrivacySummary {
        let doc = try await provider.readMetadata(from: url)
        let colorInfo = ImageColorManagementService.inspectColorProfile(url: url)
        let jxlInfo = (doc.format == .jxl) ? (try? JPEGXLCodec.inspect(url: url)) : nil

        let hasCamera = !(doc.common.cameraMake ?? "").isEmpty
            || !(doc.common.cameraModel ?? "").isEmpty
            || !(doc.common.lensModel ?? "").isEmpty
            || doc.common.iso != nil
            || doc.common.aperture != nil
            || doc.common.focalLength != nil

        let hasRights = !(doc.common.artist ?? "").isEmpty
            || !(doc.common.author ?? "").isEmpty
            || !(doc.common.copyright ?? "").isEmpty
            || !(doc.common.title ?? "").isEmpty

        let hasDesc = !(doc.common.description ?? "").isEmpty
            || !(doc.common.keywords?.isEmpty ?? true)

        return ImageMetadataPrivacySummary(
            hasGPS: doc.gps != nil,
            hasCameraHardwareInfo: hasCamera,
            hasAuthorOrCopyright: hasRights,
            hasDescriptionOrKeywords: hasDesc,
            hasICCProfile: colorInfo.hasEmbeddedICC,
            iccProfileName: colorInfo.profileName,
            isJXLContainer: jxlInfo?.isContainer ?? false,
            isJPEGReconstructable: jxlInfo?.isJPEGReconstructable ?? false,
            document: doc
        )
    }

    /// Applies an ImageMetadataEditPayload in-place to an existing image file (ImageIO or lossless JXL container rewrite).
    static func writePrivacyCleaned(url: URL, payload: ImageMetadataEditPayload) async throws {
        var doc = try await provider.readMetadata(from: url)
        switch payload.policy {
        case .preserveAll:
            if payload.stripGPS { doc.gps = nil }
            if payload.stripCamera {
                doc.common.cameraMake = nil
                doc.common.cameraModel = nil
                doc.common.lensModel = nil
                doc.common.iso = nil
                doc.common.aperture = nil
                doc.common.focalLength = nil
            }
            if payload.stripRights {
                doc.common.author = nil
                doc.common.artist = nil
                doc.common.copyright = nil
            }
        case .stripAll:
            doc.common = CommonMetadata()
            doc.gps = nil
            doc.artwork = nil
            doc.customFields = [:]
            doc.isStrippedAll = true
        case .stripGPSOnly:
            doc.gps = nil
        case .stripCameraInfo:
            doc.common.cameraMake = nil
            doc.common.cameraModel = nil
            doc.common.lensModel = nil
            doc.common.iso = nil
            doc.common.aperture = nil
            doc.common.focalLength = nil
        case .stripAuthorCopyright:
            doc.common.author = nil
            doc.common.artist = nil
            doc.common.copyright = nil
        case .applyEditedMetadata:
            if payload.stripGPS { doc.gps = nil }
            if payload.stripCamera {
                doc.common.cameraMake = nil
                doc.common.cameraModel = nil
                doc.common.lensModel = nil
                doc.common.iso = nil
                doc.common.aperture = nil
                doc.common.focalLength = nil
            }
            if payload.stripRights {
                doc.common.author = nil
                doc.common.artist = nil
                doc.common.copyright = nil
            }
            doc.common.title = payload.title
            doc.common.author = payload.author
            doc.common.artist = payload.author
            doc.common.copyright = payload.copyright
            doc.common.description = payload.description
            if let kwCSV = payload.keywordsCSV {
                let parts = kwCSV.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                doc.common.keywords = parts.isEmpty ? nil : parts
            } else {
                doc.common.keywords = nil
            }
            doc.common.cameraMake = payload.cameraMake
            doc.common.cameraModel = payload.cameraModel
        }
        _ = try await provider.writeMetadata(doc, to: url)
    }

    /// Builds an updated CGImageProperties dictionary applying an ImageMetadataEditPayload (for both ImageIO and JXL boxes).
    static func applyPolicyToProperties(
        existing: [String: Any]?,
        payload: ImageMetadataEditPayload
    ) -> [String: Any]? {
        switch payload.policy {
        case .preserveAll:
            let anyGranular = payload.stripGPS || payload.stripCamera || payload.stripRights
                || payload.stripEXIF || payload.stripIPTC || payload.stripXMP || payload.stripSoftware
            if !anyGranular {
                return existing
            }
            var copy = existing ?? [:]
            if payload.stripGPS { copy.removeValue(forKey: kCGImagePropertyGPSDictionary as String) }
            if payload.stripCamera { stripCameraKeys(in: &copy) }
            if payload.stripEXIF { copy.removeValue(forKey: kCGImagePropertyExifDictionary as String); copy.removeValue(forKey: kCGImagePropertyExifAuxDictionary as String) }
            if payload.stripRights { stripRightsKeys(in: &copy) }
            if payload.stripIPTC { copy.removeValue(forKey: kCGImagePropertyIPTCDictionary as String) }
            if payload.stripSoftware, var tiff = copy[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
                tiff.removeValue(forKey: kCGImagePropertyTIFFSoftware as String)
                if tiff.isEmpty { copy.removeValue(forKey: kCGImagePropertyTIFFDictionary as String) } else { copy[kCGImagePropertyTIFFDictionary as String] = tiff }
            }
            return copy

        case .stripAll:
            return nil

        case .stripGPSOnly:
            var copy = existing ?? [:]
            copy.removeValue(forKey: kCGImagePropertyGPSDictionary as String)
            return copy

        case .stripCameraInfo:
            var copy = existing ?? [:]
            stripCameraKeys(in: &copy)
            return copy

        case .stripAuthorCopyright:
            var copy = existing ?? [:]
            stripRightsKeys(in: &copy)
            return copy

        case .applyEditedMetadata:
            var copy = existing ?? [:]
            if payload.stripGPS { copy.removeValue(forKey: kCGImagePropertyGPSDictionary as String) }
            if payload.stripCamera { stripCameraKeys(in: &copy) }
            if payload.stripEXIF { copy.removeValue(forKey: kCGImagePropertyExifDictionary as String); copy.removeValue(forKey: kCGImagePropertyExifAuxDictionary as String) }
            if payload.stripRights { stripRightsKeys(in: &copy) }
            if payload.stripIPTC { copy.removeValue(forKey: kCGImagePropertyIPTCDictionary as String) }
            if payload.stripSoftware, var tiff = copy[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
                tiff.removeValue(forKey: kCGImagePropertyTIFFSoftware as String)
                copy[kCGImagePropertyTIFFDictionary as String] = tiff
            }

            var tiff = (copy[kCGImagePropertyTIFFDictionary as String] as? [String: Any]) ?? [:]
            var iptc = (copy[kCGImagePropertyIPTCDictionary as String] as? [String: Any]) ?? [:]

            func update(_ value: String?, key: CFString, dict: inout [String: Any]) {
                guard let value else { return }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    dict.removeValue(forKey: key as String)
                } else {
                    dict[key as String] = trimmed
                }
            }

            update(payload.title, key: kCGImagePropertyIPTCHeadline, dict: &iptc)
            update(payload.author, key: kCGImagePropertyTIFFArtist, dict: &tiff)
            update(payload.author, key: kCGImagePropertyIPTCByline, dict: &iptc)
            update(payload.copyright, key: kCGImagePropertyTIFFCopyright, dict: &tiff)
            update(payload.copyright, key: kCGImagePropertyIPTCCopyrightNotice, dict: &iptc)
            update(payload.description, key: kCGImagePropertyTIFFImageDescription, dict: &tiff)
            update(payload.description, key: kCGImagePropertyIPTCCaptionAbstract, dict: &iptc)
            update(payload.cameraMake, key: kCGImagePropertyTIFFMake, dict: &tiff)
            update(payload.cameraModel, key: kCGImagePropertyTIFFModel, dict: &tiff)

            if let kwCSV = payload.keywordsCSV {
                let parts = kwCSV.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                if parts.isEmpty {
                    iptc.removeValue(forKey: kCGImagePropertyIPTCKeywords as String)
                } else {
                    iptc[kCGImagePropertyIPTCKeywords as String] = parts
                }
            }

            if tiff.isEmpty { copy.removeValue(forKey: kCGImagePropertyTIFFDictionary as String) } else { copy[kCGImagePropertyTIFFDictionary as String] = tiff }
            if iptc.isEmpty { copy.removeValue(forKey: kCGImagePropertyIPTCDictionary as String) } else { copy[kCGImagePropertyIPTCDictionary as String] = iptc }
            return copy
        }
    }

    private static func stripCameraKeys(in dict: inout [String: Any]) {
        dict.removeValue(forKey: kCGImagePropertyExifDictionary as String)
        dict.removeValue(forKey: kCGImagePropertyExifAuxDictionary as String)
        dict.removeValue(forKey: kCGImagePropertyMakerAppleDictionary as String)
        dict.removeValue(forKey: kCGImagePropertyMakerNikonDictionary as String)
        dict.removeValue(forKey: kCGImagePropertyMakerCanonDictionary as String)
        if var tiff = dict[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff.removeValue(forKey: kCGImagePropertyTIFFMake as String)
            tiff.removeValue(forKey: kCGImagePropertyTIFFModel as String)
            tiff.removeValue(forKey: kCGImagePropertyTIFFSoftware as String)
            if tiff.isEmpty {
                dict.removeValue(forKey: kCGImagePropertyTIFFDictionary as String)
            } else {
                dict[kCGImagePropertyTIFFDictionary as String] = tiff
            }
        }
    }

    private static func stripRightsKeys(in dict: inout [String: Any]) {
        if var tiff = dict[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff.removeValue(forKey: kCGImagePropertyTIFFArtist as String)
            tiff.removeValue(forKey: kCGImagePropertyTIFFCopyright as String)
            if tiff.isEmpty { dict.removeValue(forKey: kCGImagePropertyTIFFDictionary as String) } else { dict[kCGImagePropertyTIFFDictionary as String] = tiff }
        }
        if var iptc = dict[kCGImagePropertyIPTCDictionary as String] as? [String: Any] {
            iptc.removeValue(forKey: kCGImagePropertyIPTCByline as String)
            iptc.removeValue(forKey: kCGImagePropertyIPTCCopyrightNotice as String)
            iptc.removeValue(forKey: kCGImagePropertyIPTCCredit as String)
            iptc.removeValue(forKey: kCGImagePropertyIPTCHeadline as String)
            if iptc.isEmpty { dict.removeValue(forKey: kCGImagePropertyIPTCDictionary as String) } else { dict[kCGImagePropertyIPTCDictionary as String] = iptc }
        }
    }
}
