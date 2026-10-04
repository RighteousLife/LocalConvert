// WebPBridge.h
// Thin C shim exposing libwebp encode/decode/validate functions to Swift.
// Copyright © 2026 LocalConvert. All rights reserved.

#ifndef WEBP_BRIDGE_H
#define WEBP_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// MARK: - Version

/// Returns the libwebp encoder version as a string, e.g. "1.6.0".
/// Caller is responsible for freeing the returned buffer using WebPBridgeFreeBuffer().
const char* WebPBridgeEncoderVersion(void);

// MARK: - Encoding

/// Encodes RGBA pixel data to lossy WebP format.
/// @param rgba       Raw RGBA pixel data (4 bytes per pixel, R G B A order)
/// @param width      Image width in pixels
/// @param height     Image height in pixels
/// @param stride     Row stride in bytes (typically width * 4)
/// @param quality    Compression quality 0.0 (worst) ... 100.0 (best)
/// @param outData    On success, set to a malloc'd buffer containing the WebP bitstream. Caller must free with WebPBridgeFreeBuffer().
/// @param outSize    On success, set to the number of bytes in outData.
/// @return 1 on success, 0 on failure.
int WebPBridgeEncodeLossy(
    const uint8_t* rgba,
    int width,
    int height,
    int stride,
    float quality,
    uint8_t** outData,
    size_t* outSize
);

/// Encodes RGBA pixel data to lossless WebP format.
/// @param rgba       Raw RGBA pixel data (4 bytes per pixel, R G B A order)
/// @param width      Image width in pixels
/// @param height     Image height in pixels
/// @param stride     Row stride in bytes (typically width * 4)
/// @param outData    On success, set to a malloc'd buffer. Caller must free with WebPBridgeFreeBuffer().
/// @param outSize    On success, set to the number of bytes in outData.
/// @return 1 on success, 0 on failure.
int WebPBridgeEncodeLossless(
    const uint8_t* rgba,
    int width,
    int height,
    int stride,
    uint8_t** outData,
    size_t* outSize
);

// MARK: - Validation

/// Validates a WebP bitstream by checking RIFF/WEBP header signature.
/// @param data    Pointer to the WebP bitstream bytes.
/// @param size    Number of bytes in the buffer.
/// @return 1 if the buffer appears to be a valid WebP file, 0 otherwise.
int WebPBridgeValidate(const uint8_t* data, size_t size);

/// Retrieves the image dimensions from a WebP bitstream without full decoding.
/// @param data    Pointer to the WebP bitstream bytes.
/// @param size    Number of bytes.
/// @param width   On success, populated with image width.
/// @param height  On success, populated with image height.
/// @return 1 on success, 0 if the data is not a valid WebP stream.
int WebPBridgeGetInfo(const uint8_t* data, size_t size, int* width, int* height);

// MARK: - Alpha Check

/// Returns 1 if the WebP bitstream contains an alpha channel, 0 otherwise.
int WebPBridgeHasAlpha(const uint8_t* data, size_t size);

// MARK: - Memory

/// Frees a buffer previously returned by WebPBridgeEncode* functions.
void WebPBridgeFreeBuffer(uint8_t* data);

#ifdef __cplusplus
}
#endif

#endif /* WEBP_BRIDGE_H */
