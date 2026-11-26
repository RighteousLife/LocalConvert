// JXLBridge.h
// Thin C interface wrapping official libjxl v0.13.0 for Swift interop via bridging header.
// Copyright © 2026 LocalConvert. All rights reserved.

#ifndef JXL_BRIDGE_H
#define JXL_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Returns the bundled libjxl version string (e.g. "0.13.0").
const char* JXLBridgeVersion(void);

/// Checks if data has a valid JPEG XL codestream or ISO BMFF container signature.
/// Returns 0 = invalid/not enough bytes, 1 = raw codestream, 2 = container.
int JXLBridgeValidate(const uint8_t* data, size_t size);

typedef struct JXLBridgeImageInfo {
    uint32_t width;
    uint32_t height;
    uint32_t bits_per_sample;
    uint32_t exponent_bits_per_sample;
    uint32_t alpha_bits;
    uint32_t num_color_channels;
    uint32_t frame_count;
    uint32_t tps_numerator;
    uint32_t tps_denominator;
    uint32_t num_loops;
    int orientation;
    int have_animation;
    int is_jpeg_reconstructable;
    int is_container;
    int has_icc;
    int has_exif;
    int has_xmp;
} JXLBridgeImageInfo;

typedef struct JXLBridgeDecodedFrame {
    uint8_t* pixel_data;
    size_t pixel_size;
    uint32_t duration_ms;
    uint32_t width;
    uint32_t height;
    uint32_t bits_per_sample; // 8 or 16
} JXLBridgeDecodedFrame;

typedef struct JXLBridgeDecodedResult {
    JXLBridgeImageInfo info;
    JXLBridgeDecodedFrame* frames;
    size_t frame_count;
    uint8_t* icc_data;
    size_t icc_size;
    uint8_t* exif_data;
    size_t exif_size;
    uint8_t* xmp_data;
    size_t xmp_size;
} JXLBridgeDecodedResult;

typedef struct JXLBridgeEncodeFrameInput {
    const uint8_t* pixel_data;
    size_t pixel_size;
    uint32_t width;
    uint32_t height;
    uint32_t duration_ms;
} JXLBridgeEncodeFrameInput;

/// Inspects a JPEG XL image without decoding full pixel buffers.
/// Returns 1 on success, 0 on failure (writes diagnostic to errBuf if non-NULL).
int JXLBridgeInspect(
    const uint8_t* data,
    size_t size,
    JXLBridgeDecodedResult* outResult,
    char* errBuf,
    size_t errBufSize
);

/// Decodes a JPEG XL image (single image or all animation frames if decode_all_frames != 0)
/// into RGBA8 or RGBA16 pixel buffers (if prefer_16bit != 0 and image > 8 bpc).
/// Caller must free outResult via JXLBridgeFreeDecodedResult.
/// Returns 1 on success, 0 on failure.
int JXLBridgeDecode(
    const uint8_t* data,
    size_t size,
    int prefer_16bit,
    int decode_all_frames,
    JXLBridgeDecodedResult* outResult,
    char* errBuf,
    size_t errBufSize
);

/// Frees heap memory owned by a JXLBridgeDecodedResult.
void JXLBridgeFreeDecodedResult(JXLBridgeDecodedResult* result);

/// Encodes one or more frames (8-bit or 16-bit per channel; RGB if has_alpha == 0, straight RGBA if has_alpha != 0) to JPEG XL.
/// If lossless != 0, distance is forced to 0 and lossless modular coding is enabled.
/// If distance >= 0, uses explicit Butteraugli distance; otherwise derives from quality_0_100 (0..100).
/// Exif data should be raw TIFF/EXIF bytes (4-byte JXL box offset is prepended automatically if missing).
/// Returns 1 on success, 0 on failure. Caller must free *outData via JXLBridgeFreeBuffer.
int JXLBridgeEncode(
    const JXLBridgeEncodeFrameInput* frames,
    size_t frame_count,
    int lossless,
    float distance,
    float quality_0_100,
    int effort,
    int bits_per_sample,
    int has_alpha,
    int use_container,
    const uint8_t* icc_data,
    size_t icc_size,
    const uint8_t* exif_data,
    size_t exif_size,
    const uint8_t* xmp_data,
    size_t xmp_size,
    uint32_t num_loops,
    uint32_t tps_numerator,
    uint32_t tps_denominator,
    uint8_t** outData,
    size_t* outSize,
    char* errBuf,
    size_t errBufSize
);

/// Losslessly transcodes an existing JPEG byte stream into a JPEG XL container.
/// If store_jpeg_metadata != 0, stores reconstruction box (jbrd) for bit-exact JPEG recovery.
/// Returns 1 on success, 0 on failure. Caller must free *outData via JXLBridgeFreeBuffer.
int JXLBridgeTranscodeJPEG(
    const uint8_t* jpegData,
    size_t jpegSize,
    int effort,
    int store_jpeg_metadata,
    uint8_t** outData,
    size_t* outSize,
    char* errBuf,
    size_t errBufSize
);

/// Losslessly reconstructs original JPEG bytes from a JPEG XL file transcoded with store_jpeg_metadata.
/// Returns 1 on success, 0 on failure (including if the JXL has no JPEG reconstruction data).
/// Caller must free *outData via JXLBridgeFreeBuffer.
int JXLBridgeReconstructJPEG(
    const uint8_t* jxlData,
    size_t jxlSize,
    uint8_t** outData,
    size_t* outSize,
    char* errBuf,
    size_t errBufSize
);

/// Updates Exif and/or XMP metadata boxes inside an existing JXL file while preserving pixel/JPEG reconstruction data
/// if possible, or returns 0 cleanly if modification fails.
/// Note: Caller handles pixel-level re-encode when boxes cannot be patched without touching codestream, or reuses codestream.
void JXLBridgeFreeBuffer(void* ptr);

#ifdef __cplusplus
}
#endif

#endif /* JXL_BRIDGE_H */
