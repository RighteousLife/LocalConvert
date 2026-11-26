import Foundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO

// MARK: - Core Image Non-Destructive Adjustment & Filter Engine

enum ImageAdjustmentsEngine {

    struct RAWLoadOutput {
        let ciImage: CIImage
        let properties: [String: Any]?
        let nativeWidth: Int?
        let nativeHeight: Int?
        let usedCIRAWFilter: Bool
        let statusNote: String?
    }

    // MARK: - Native Camera RAW Loading (CIRAWFilter + Capability Checks)

    /// Attempts native macOS Camera RAW demosaicing via `CIRAWFilter`.
    /// Returns `nil` when the URL is not supported by `CIRAWFilter` so callers fall back explicitly to `CGImageSource`.
    static func loadWithCIRAWFilter(
        url: URL,
        config: ImageRAWDevelopConfig,
        scaleFactor: Double = 1.0
    ) -> RAWLoadOutput? {
        guard config.enabled, config.useRAWFilter else { return nil }
        let clampedScale = Float(max(0.05, min(1.0, scaleFactor)))

        if let scaled = evaluateRAWFilter(url: url, config: config, scaleFactor: clampedScale, draftMode: clampedScale < 0.99) {
            return scaled
        }
        // Some RAW/Linear-DNG drivers reject draft/scaled decode; retry full scale and downsample in Core Image.
        if clampedScale < 0.99,
           let full = evaluateRAWFilter(url: url, config: config, scaleFactor: 1.0, draftMode: false) {
            let s = CGFloat(clampedScale)
            let resized = full.ciImage.transformed(by: CGAffineTransform(scaleX: s, y: s))
            return RAWLoadOutput(
                ciImage: resized,
                properties: full.properties,
                nativeWidth: full.nativeWidth,
                nativeHeight: full.nativeHeight,
                usedCIRAWFilter: true,
                statusNote: nil
            )
        }
        return nil
    }

    private static func evaluateRAWFilter(
        url: URL,
        config: ImageRAWDevelopConfig,
        scaleFactor: Float,
        draftMode: Bool
    ) -> RAWLoadOutput? {
        guard let rawFilter = CIRAWFilter(imageURL: url) else { return nil }

        rawFilter.scaleFactor = scaleFactor
        rawFilter.isDraftModeEnabled = draftMode
        rawFilter.exposure = Float(config.exposureEV)
        if let temp = config.neutralTemperatureKelvin {
            rawFilter.neutralTemperature = Float(temp)
        }
        if let tint = config.neutralTint {
            rawFilter.neutralTint = Float(tint)
        }
        if #available(macOS 26.0, *), rawFilter.isHighlightRecoverySupported {
            rawFilter.isHighlightRecoveryEnabled = config.highlightRecovery > 0.05
        }
        rawFilter.boostAmount = Float(config.boostAmount)
        rawFilter.boostShadowAmount = Float(config.highlightRecovery)
        rawFilter.shadowBias = Float(config.shadowBias)
        rawFilter.isGamutMappingEnabled = config.gamutMappingEnabled
        if rawFilter.isLensCorrectionSupported {
            rawFilter.isLensCorrectionEnabled = config.lensCorrectionEnabled
        }
        if rawFilter.isLuminanceNoiseReductionSupported {
            rawFilter.luminanceNoiseReductionAmount = Float(config.lumaNoiseReduction)
        }
        if rawFilter.isColorNoiseReductionSupported {
            rawFilter.colorNoiseReductionAmount = Float(config.colorNoiseReduction)
        }
        if rawFilter.isSharpnessSupported {
            rawFilter.sharpnessAmount = Float(config.sharpnessAmount)
        }

        guard let output = rawFilter.outputImage,
              !output.extent.isEmpty,
              !output.extent.isInfinite,
              output.extent.width >= 1,
              output.extent.height >= 1 else {
            return nil
        }

        var props: [String: Any] = [:]
        for (k, v) in rawFilter.properties {
            if let ks = k as? String {
                props[ks] = v
            }
        }
        let natW = rawFilter.nativeSize.width > 0 ? Int(rawFilter.nativeSize.width.rounded()) : nil
        let natH = rawFilter.nativeSize.height > 0 ? Int(rawFilter.nativeSize.height.rounded()) : nil

        return RAWLoadOutput(
            ciImage: output,
            properties: props.isEmpty ? nil : props,
            nativeWidth: natW,
            nativeHeight: natH,
            usedCIRAWFilter: true,
            statusNote: nil
        )
    }

    // MARK: - Color & Tone Adjustments DAG

    /// Appends enabled non-destructive color, tone, levels, curves, and color-balance nodes to `ciImage`.
    /// Preserves alpha channel cleanly and compiles into Core Image's lazy GPU graph without intermediate bitmaps.
    static func applyColorAdjustments(
        _ input: CIImage,
        config: ImageColorAdjustmentsConfig,
        workingColorSpace: CGColorSpace
    ) -> CIImage {
        guard config.isEnabled, config.hasActiveAdjustments else {
            return input
        }

        let extent = input.extent
        var current = input

        // 1. White Balance (Temperature & Tint)
        if abs(config.temperatureOffset) > 0.01 || abs(config.tintOffset) > 0.01 {
            if let wb = CIFilter(name: "CITemperatureAndTint") {
                // Moving inputNeutral higher than targetNeutral 6500K shifts output warmer (+temp).
                let neutralK = max(2_000.0, min(14_000.0, 6_500.0 + config.temperatureOffset * 28.0))
                let neutralTint = max(-150.0, min(150.0, -config.tintOffset * 1.1))
                wb.setValue(current, forKey: kCIInputImageKey)
                wb.setValue(CIVector(x: neutralK, y: neutralTint), forKey: "inputNeutral")
                wb.setValue(CIVector(x: 6_500.0, y: 0.0), forKey: "inputTargetNeutral")
                if let out = wb.outputImage { current = out.cropped(to: extent) }
            }
        }

        // 2. Linear Exposure (Stops / EV)
        if abs(config.exposureEV) > 0.001 {
            if let exp = CIFilter(name: "CIExposureAdjust") {
                exp.setValue(current, forKey: kCIInputImageKey)
                exp.setValue(config.exposureEV, forKey: kCIInputEVKey)
                if let out = exp.outputImage { current = out.cropped(to: extent) }
            }
        }

        // 3. Highlights & Shadows (Localized tone compression/lift)
        if abs(config.highlights) > 0.001 || abs(config.shadows) > 0.001 {
            if let hs = CIFilter(name: "CIHighlightShadowAdjust") {
                hs.setValue(current, forKey: kCIInputImageKey)
                // Default neutral inputHighlightAmount is 1.0; pulling highlights slider negative (< 0) compresses bright highlights down toward 0.15;
                // pushing positive lifts upper highlights slightly up to 1.35.
                let hiAmt = max(0.15, min(1.35, 1.0 + config.highlights * 0.65))
                hs.setValue(hiAmt, forKey: "inputHighlightAmount")
                hs.setValue(max(-1.0, min(1.0, config.shadows)), forKey: "inputShadowAmount")
                if let out = hs.outputImage { current = out.cropped(to: extent) }
            }
        }

        // 4. Gamma Power
        if abs(config.gamma - 1.0) > 0.001 {
            if let gam = CIFilter(name: "CIGammaAdjust") {
                gam.setValue(current, forKey: kCIInputImageKey)
                gam.setValue(1.0 / max(0.25, config.gamma), forKey: "inputPower")
                if let out = gam.outputImage { current = out.cropped(to: extent) }
            }
        }

        // 5. Brightness, Contrast, Saturation
        if abs(config.brightness) > 0.001
            || abs(config.contrast - 1.0) > 0.001
            || abs(config.saturation - 1.0) > 0.001 {
            if let cc = CIFilter(name: "CIColorControls") {
                cc.setValue(current, forKey: kCIInputImageKey)
                cc.setValue(config.brightness, forKey: kCIInputBrightnessKey)
                cc.setValue(config.contrast, forKey: kCIInputContrastKey)
                cc.setValue(config.saturation, forKey: kCIInputSaturationKey)
                if let out = cc.outputImage { current = out.cropped(to: extent) }
            }
        }

        // 6. Vibrance (Smart saturation favoring muted tones)
        if abs(config.vibrance) > 0.001 {
            if let vib = CIFilter(name: "CIVibrance") {
                vib.setValue(current, forKey: kCIInputImageKey)
                vib.setValue(config.vibrance, forKey: "inputAmount")
                if let out = vib.outputImage { current = out.cropped(to: extent) }
            }
        }

        // 7. Hue Rotation
        if abs(config.hueDegrees) > 0.05 {
            if let hue = CIFilter(name: "CIHueAdjust") {
                hue.setValue(current, forKey: kCIInputImageKey)
                hue.setValue(config.hueDegrees * (.pi / 180.0), forKey: kCIInputAngleKey)
                if let out = hue.outputImage { current = out.cropped(to: extent) }
            }
        }

        // 8. Combined Float32 1D Per-Channel LUT via CIColorCurves (Whites/Blacks -> Levels -> Master & RGB Curves)
        let needsToneLUT = abs(config.whites) > 0.001
            || abs(config.blacks) > 0.001
            || !config.levels.isNeutral
            || !config.curves.isNeutral

        if needsToneLUT, let lutData = buildCombined1DColorCurvesData(config: config),
           let curveFilter = CIFilter(name: "CIColorCurves") {
            let curveCS = (workingColorSpace.model == .rgb ? workingColorSpace : nil)
                ?? CGColorSpace(name: CGColorSpace.sRGB)!
            curveFilter.setValue(current, forKey: kCIInputImageKey)
            curveFilter.setValue(lutData, forKey: "inputCurvesData")
            curveFilter.setValue(CIVector(x: 0.0, y: 1.0), forKey: "inputCurvesDomain")
            curveFilter.setValue(curveCS, forKey: "inputColorSpace")
            if let out = curveFilter.outputImage {
                current = out.cropped(to: extent)
            }
        }

        // 9. 3-Band Color Balance (Shadows / Midtones / Highlights) via 32^3 ColorCube
        if !config.colorBalance.isNeutral,
           let cubeData = buildColorBalanceCubeData(config.colorBalance, dimension: 32),
           let cube = CIFilter(name: "CIColorCubeWithColorSpace") {
            let cubeCS = (workingColorSpace.model == .rgb ? workingColorSpace : nil)
                ?? CGColorSpace(name: CGColorSpace.sRGB)!
            cube.setValue(32, forKey: "inputCubeDimension")
            cube.setValue(cubeData, forKey: "inputCubeData")
            cube.setValue(cubeCS, forKey: "inputColorSpace")
            cube.setValue(current, forKey: kCIInputImageKey)
            if let out = cube.outputImage {
                current = out.cropped(to: extent)
            }
        }

        return current
    }

    // MARK: - Ordered Effect Stack DAG

    /// Evaluates enabled effects in exact stack order using lazy Core Image nodes.
    static func applyEffectsChain(
        _ input: CIImage,
        slots: [ImageEffectSlot],
        workingColorSpace: CGColorSpace
    ) -> CIImage {
        let active = slots.filter(\.isEnabled)
        guard !active.isEmpty else { return input }

        let extent = input.extent
        var current = input

        for slot in active {
            switch slot.kind {
            case .gaussianBlur:
                let sigma = max(0.05, slot.radius) * max(0.0, min(1.5, slot.intensity))
                guard sigma > 0.05 else { continue }
                let blurred = current
                    .clampedToExtent()
                    .applyingGaussianBlur(sigma: sigma)
                    .cropped(to: extent)
                // Preserve original alpha boundary cleanly
                current = preserveAlpha(from: current, appliedTo: blurred, extent: extent)

            case .sharpen:
                guard slot.intensity > 0.005, let f = CIFilter(name: "CISharpenLuminance") else { continue }
                f.setValue(current, forKey: kCIInputImageKey)
                f.setValue(slot.sharpness * max(0.2, slot.intensity * 1.4), forKey: kCIInputSharpnessKey)
                f.setValue(max(0.5, min(4.0, slot.radius)), forKey: kCIInputRadiusKey)
                if let out = f.outputImage { current = out.cropped(to: extent) }

            case .unsharpMask:
                guard slot.intensity > 0.005, let f = CIFilter(name: "CIUnsharpMask") else { continue }
                f.setValue(current, forKey: kCIInputImageKey)
                f.setValue(max(0.2, slot.radius), forKey: kCIInputRadiusKey)
                f.setValue(max(0.0, min(2.0, slot.intensity)), forKey: kCIInputIntensityKey)
                if let out = f.outputImage { current = out.cropped(to: extent) }

            case .noiseReduction:
                guard slot.intensity > 0.005, let f = CIFilter(name: "CINoiseReduction") else { continue }
                f.setValue(current, forKey: kCIInputImageKey)
                f.setValue(max(0.001, slot.intensity * 0.06), forKey: "inputNoiseLevel")
                f.setValue(slot.sharpness, forKey: kCIInputSharpnessKey)
                if let out = f.outputImage { current = out.cropped(to: extent) }

            case .vignette:
                guard slot.intensity > 0.005 else { continue }
                if let f = CIFilter(name: "CIVignetteEffect") {
                    let diag = hypot(extent.width, extent.height)
                    let center = CIVector(x: extent.midX, y: extent.midY)
                    // radius parameter mapped 0.1...1.5 of half-diagonal
                    let rad = max(10.0, diag * max(0.15, min(0.85, slot.radius / 10.0 + 0.35)))
                    f.setValue(current, forKey: kCIInputImageKey)
                    f.setValue(center, forKey: kCIInputCenterKey)
                    f.setValue(rad, forKey: kCIInputRadiusKey)
                    f.setValue(max(-1.0, min(2.0, slot.intensity * 1.4)), forKey: kCIInputIntensityKey)
                    f.setValue(slot.falloff, forKey: "inputFalloff")
                    if let out = f.outputImage { current = out.cropped(to: extent) }
                }

            case .filmGrain:
                guard slot.intensity > 0.005,
                      let noiseGen = CIFilter(name: "CIRandomGenerator"),
                      let rawNoise = noiseGen.outputImage else { continue }
                var grain = rawNoise.cropped(to: extent.insetBy(dx: -8, dy: -8))
                if slot.grainSize > 0.8 {
                    let gSigma = max(0.15, (slot.grainSize - 0.7) * 0.65)
                    grain = grain.applyingGaussianBlur(sigma: gSigma)
                }
                grain = grain.cropped(to: extent)
                if let mono = CIFilter(name: "CIColorControls") {
                    mono.setValue(grain, forKey: kCIInputImageKey)
                    mono.setValue(0.0, forKey: kCIInputSaturationKey)
                    mono.setValue(1.0 + slot.intensity * 0.6, forKey: kCIInputContrastKey)
                    if let gOut = mono.outputImage { grain = gOut.cropped(to: extent) }
                }
                // Attenuate grain alpha to match intensity so SoftLight applies smoothly without washing contrast
                let alphaStrength = CGFloat(max(0.0, min(0.45, slot.intensity * 0.28)))
                if let alphaScale = CIFilter(name: "CIColorMatrix") {
                    alphaScale.setValue(grain, forKey: kCIInputImageKey)
                    alphaScale.setValue(CIVector(x: 0, y: 0, z: 0, w: alphaStrength), forKey: "inputAVector")
                    if let gAlpha = alphaScale.outputImage { grain = gAlpha.cropped(to: extent) }
                }
                // Clip grain inside source alpha so transparent edges remain clean
                if let maskedGrain = maskToAlpha(sourceAlpha: current, foreground: grain, extent: extent),
                   let blend = CIFilter(name: "CISoftLightBlendMode") {
                    blend.setValue(maskedGrain, forKey: kCIInputImageKey)
                    blend.setValue(current, forKey: kCIInputBackgroundImageKey)
                    if let out = blend.outputImage { current = out.cropped(to: extent) }
                }

            case .monochrome:
                guard slot.intensity > 0.005, let f = CIFilter(name: "CIColorMonochrome") else { continue }
                let tc = slot.tintColor
                f.setValue(current, forKey: kCIInputImageKey)
                f.setValue(CIColor(red: tc.red, green: tc.green, blue: tc.blue, alpha: 1.0), forKey: kCIInputColorKey)
                f.setValue(min(1.0, slot.intensity), forKey: kCIInputIntensityKey)
                if let out = f.outputImage { current = out.cropped(to: extent) }

            case .sepia:
                guard slot.intensity > 0.005, let f = CIFilter(name: "CISepiaTone") else { continue }
                f.setValue(current, forKey: kCIInputImageKey)
                f.setValue(min(1.0, slot.intensity), forKey: kCIInputIntensityKey)
                if let out = f.outputImage { current = out.cropped(to: extent) }

            case .photoFilter:
                let strength = max(0.0, min(1.0, slot.intensity))
                guard strength > 0.005 else { continue }
                let styled: CIImage?
                if let filterName = slot.photoStyle.ciFilterName, let f = CIFilter(name: filterName) {
                    f.setValue(current, forKey: kCIInputImageKey)
                    styled = f.outputImage?.cropped(to: extent)
                } else {
                    styled = applyTintLook(current, style: slot.photoStyle, extent: extent)
                }
                if let lookImg = styled {
                    if strength >= 0.99 {
                        current = preserveAlpha(from: current, appliedTo: lookImg, extent: extent)
                    } else {
                        current = blendByFraction(base: current, filtered: preserveAlpha(from: current, appliedTo: lookImg, extent: extent), fraction: strength, extent: extent)
                    }
                }
            }
        }
        _ = workingColorSpace
        return current
    }

    // MARK: - LUT Builders (Float32 1D Curves + 3D Color Balance)

    private static func buildCombined1DColorCurvesData(
        config: ImageColorAdjustmentsConfig,
        samples: Int = 256
    ) -> Data? {
        let masterLUT = ImageCurvesConfig.buildLUT(points: config.curves.master, sampleCount: samples)
        let rCurveLUT = ImageCurvesConfig.buildLUT(points: config.curves.red, sampleCount: samples)
        let gCurveLUT = ImageCurvesConfig.buildLUT(points: config.curves.green, sampleCount: samples)
        let bCurveLUT = ImageCurvesConfig.buildLUT(points: config.curves.blue, sampleCount: samples)

        var floats = [Float](repeating: 0, count: samples * 3)
        let whites = config.whites
        let blacks = config.blacks

        for i in 0..<samples {
            let x = Double(i) / Double(max(1, samples - 1))

            // 1. Distinct Blacks & Whites endpoint shaping (toe & shoulder without middle-exposure shift)
            var shaped = x
            if abs(blacks) > 0.001 || abs(whites) > 0.001 {
                let blackToe = max(-0.25, min(0.25, blacks * 0.22))
                let whiteShoulder = max(-0.25, min(0.25, whites * 0.22))
                // Map input range [blackShift ... 1 - whiteShift] cleanly
                let inMin = max(0.0, -blackToe)
                let inMax = min(1.0, 1.0 - max(0.0, whiteShoulder))
                let outMin = max(0.0, blackToe)
                let outMax = min(1.0, 1.0 + min(0.0, whiteShoulder))
                let t = min(1.0, max(0.0, (x - inMin) / max(0.05, inMax - inMin)))
                shaped = outMin + t * (outMax - outMin)
            }

            // 2. Master Levels
            let afterMasterLvl = config.levels.master.evaluate(shaped)

            // 3. Per-channel Levels -> Master Curve -> Per-channel Curve
            let rLvl = config.levels.red.evaluate(afterMasterLvl)
            let gLvl = config.levels.green.evaluate(afterMasterLvl)
            let bLvl = config.levels.blue.evaluate(afterMasterLvl)

            let rMaster = sampleLUT(masterLUT, at: rLvl)
            let gMaster = sampleLUT(masterLUT, at: gLvl)
            let bMaster = sampleLUT(masterLUT, at: bLvl)

            floats[i * 3 + 0] = Float(sampleLUT(rCurveLUT, at: rMaster))
            floats[i * 3 + 1] = Float(sampleLUT(gCurveLUT, at: gMaster))
            floats[i * 3 + 2] = Float(sampleLUT(bCurveLUT, at: bMaster))
        }

        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func sampleLUT(_ lut: [Double], at x: Double) -> Double {
        guard !lut.isEmpty else { return x }
        let clamped = min(1.0, max(0.0, x))
        let pos = clamped * Double(lut.count - 1)
        let lo = Int(floor(pos))
        let hi = min(lut.count - 1, lo + 1)
        let frac = pos - Double(lo)
        return lut[lo] * (1.0 - frac) + lut[hi] * frac
    }

    private static func buildColorBalanceCubeData(_ balance: ImageColorBalanceConfig, dimension n: Int) -> Data? {
        var cube = [Float](repeating: 0, count: n * n * n * 4)
        let denom = Double(max(1, n - 1))
        let sh = balance.shadows
        let mid = balance.midtones
        let hi = balance.highlights
        let scale = 0.28 // Subtle natural grading scale (-0.28 ... +0.28 channel delta)

        var idx = 0
        for bIdx in 0..<n {
            let b = Double(bIdx) / denom
            for gIdx in 0..<n {
                let g = Double(gIdx) / denom
                for rIdx in 0..<n {
                    let r = Double(rIdx) / denom
                    let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b

                    // Smooth tonal band masks
                    let wSh = pow(max(0.0, min(1.0, 1.0 - luma / 0.55)), 1.6)
                    let wHi = pow(max(0.0, min(1.0, (luma - 0.45) / 0.55)), 1.6)
                    let wMid = max(0.0, 1.0 - wSh - wHi)

                    let dCR = (sh.cyanRed * wSh + mid.cyanRed * wMid + hi.cyanRed * wHi) * scale
                    let dMG = (sh.magentaGreen * wSh + mid.magentaGreen * wMid + hi.magentaGreen * wHi) * scale
                    let dYB = (sh.yellowBlue * wSh + mid.yellowBlue * wMid + hi.yellowBlue * wHi) * scale

                    var nr = max(0.0, min(1.0, r + dCR - dMG * 0.5 - dYB * 0.5))
                    var ng = max(0.0, min(1.0, g + dMG - dCR * 0.5 - dYB * 0.5))
                    var nb = max(0.0, min(1.0, b + dYB - dCR * 0.5 - dMG * 0.5))

                    if balance.preserveLuminance {
                        let newLuma = 0.2126 * nr + 0.7152 * ng + 0.0722 * nb
                        if newLuma > 0.0001 {
                            let ratio = luma / newLuma
                            nr = max(0.0, min(1.0, nr * ratio))
                            ng = max(0.0, min(1.0, ng * ratio))
                            nb = max(0.0, min(1.0, nb * ratio))
                        }
                    }

                    cube[idx] = Float(nr)
                    cube[idx + 1] = Float(ng)
                    cube[idx + 2] = Float(nb)
                    cube[idx + 3] = 1.0
                    idx += 4
                }
            }
        }
        return cube.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // MARK: - Helpers

    private static func applyTintLook(_ input: CIImage, style: ImagePhotoFilterStyle, extent: CGRect) -> CIImage? {
        let color: CIColor
        switch style {
        case .warmAmber: color = CIColor(red: 0.98, green: 0.72, blue: 0.42, alpha: 0.28)
        case .coolAzure: color = CIColor(red: 0.35, green: 0.62, blue: 0.95, alpha: 0.26)
        case .emerald:   color = CIColor(red: 0.24, green: 0.78, blue: 0.58, alpha: 0.24)
        default: return input
        }
        let wash = CIImage(color: color).cropped(to: extent)
        return wash.composited(over: input).cropped(to: extent)
    }

    private static func preserveAlpha(from source: CIImage, appliedTo filtered: CIImage, extent: CGRect) -> CIImage {
        guard let mask = CIFilter(name: "CISourceInCompositing") else {
            return filtered.cropped(to: extent)
        }
        mask.setValue(filtered, forKey: kCIInputImageKey)
        mask.setValue(source, forKey: kCIInputBackgroundImageKey)
        return mask.outputImage?.cropped(to: extent) ?? filtered.cropped(to: extent)
    }

    private static func maskToAlpha(sourceAlpha: CIImage, foreground: CIImage, extent: CGRect) -> CIImage? {
        guard let mask = CIFilter(name: "CISourceInCompositing") else { return nil }
        mask.setValue(foreground, forKey: kCIInputImageKey)
        mask.setValue(sourceAlpha, forKey: kCIInputBackgroundImageKey)
        return mask.outputImage?.cropped(to: extent)
    }

    private static func blendByFraction(base: CIImage, filtered: CIImage, fraction: Double, extent: CGRect) -> CIImage {
        let a = CGFloat(max(0.0, min(1.0, fraction)))
        guard let alphaMul = CIFilter(name: "CIColorMatrix") else { return filtered }
        alphaMul.setValue(filtered, forKey: kCIInputImageKey)
        alphaMul.setValue(CIVector(x: 0, y: 0, z: 0, w: a), forKey: "inputAVector")
        guard let scaledTop = alphaMul.outputImage?.cropped(to: extent) else { return filtered }
        return scaledTop.composited(over: base).cropped(to: extent)
    }
}
