import Foundation
import CoreGraphics

// MARK: - Image Optimization Mode

enum ImageOptimizationMode: String, Codable, CaseIterable, Sendable, Equatable, Hashable {
    case balanced = "Balanced"
    case quality = "High Quality"
    case maximum = "Maximum Quality"
    case smallFile = "Small File"
    case targetFileSize = "Target File Size"
    case lossless = "Lossless Optimization"
    case custom = "Custom"
    
    var displayName: String { rawValue }
}

// MARK: - Image Resize Mode

enum ImageResizeMode: String, Codable, CaseIterable, Sendable, Equatable, Hashable {
    case none = "None"
    case exactWidth = "Exact Width"
    case exactHeight = "Exact Height"
    case exactDimensions = "Width & Height"
    case percentage = "Percentage"
    case longestEdge = "Longest Edge"
    case shortestEdge = "Shortest Edge"
    
    var displayName: String { rawValue }
}

// MARK: - Image Crop Aspect Ratio

enum ImageCropAspectRatio: String, Codable, CaseIterable, Sendable, Equatable, Hashable {
    case original = "Original Ratio"
    case square1x1 = "1:1 (Square)"
    case ratio4x3 = "4:3 (Standard)"
    case ratio3x4 = "3:4 (Portrait)"
    case ratio3x2 = "3:2 (Classic 35mm)"
    case ratio2x3 = "2:3 (Portrait 35mm)"
    case ratio16x9 = "16:9 (Widescreen)"
    case ratio9x16 = "9:16 (Story / Reel)"
    case custom = "Freeform"
    
    var displayName: String { rawValue }
    
    var ratioValue: CGFloat? {
        switch self {
        case .original, .custom:
            return nil
        case .square1x1:
            return 1.0
        case .ratio4x3:
            return 4.0 / 3.0
        case .ratio3x4:
            return 3.0 / 4.0
        case .ratio3x2:
            return 3.0 / 2.0
        case .ratio2x3:
            return 2.0 / 3.0
        case .ratio16x9:
            return 16.0 / 9.0
        case .ratio9x16:
            return 9.0 / 16.0
        }
    }
}

// MARK: - Image Crop Mode

enum ImageCropMode: String, Codable, CaseIterable, Sendable, Equatable, Hashable {
    case none = "None"
    case centerCrop = "Center Crop"
    case customRect = "Custom Rect"
    
    var displayName: String { rawValue }
}

// MARK: - Normalized Rect

struct NormalizedRect: Codable, Sendable, Equatable, Hashable {
    var x: Double // 0.0 ... 1.0
    var y: Double // 0.0 ... 1.0
    var width: Double // 0.0 ... 1.0
    var height: Double // 0.0 ... 1.0
    
    init(x: Double = 0, y: Double = 0, width: Double = 1, height: Double = 1) {
        let clampedX = max(0.0, min(1.0, x))
        let clampedY = max(0.0, min(1.0, y))
        self.x = clampedX
        self.y = clampedY
        self.width = max(0.01, min(1.0 - clampedX, width))
        self.height = max(0.01, min(1.0 - clampedY, height))
    }
    
    init(cgRect: CGRect) {
        self.init(x: Double(cgRect.origin.x), y: Double(cgRect.origin.y), width: Double(cgRect.size.width), height: Double(cgRect.size.height))
    }
    
    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
    
    func pixelRect(for size: CGSize) -> CGRect {
        CGRect(
            x: CGFloat(x) * size.width,
            y: CGFloat(y) * size.height,
            width: CGFloat(width) * size.width,
            height: CGFloat(height) * size.height
        )
    }
}
