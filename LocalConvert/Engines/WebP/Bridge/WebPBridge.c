// WebPBridge.c
// Thin C shim implementing WebPBridge.h by delegating to libwebp.
// Copyright © 2026 LocalConvert. All rights reserved.

#include "WebPBridge.h"
#include <webp/encode.h>
#include <webp/decode.h>
#include <webp/demux.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

// MARK: - Version

const char* WebPBridgeEncoderVersion(void) {
    int version = WebPGetEncoderVersion();
    int major = (version >> 16) & 0xFF;
    int minor = (version >> 8) & 0xFF;
    int patch = version & 0xFF;
    // Static buffer — adequate for version string, single-threaded init.
    static char buf[32];
    snprintf(buf, sizeof(buf), "%d.%d.%d", major, minor, patch);
    return buf;
}

// MARK: - Encoding

int WebPBridgeEncodeLossy(
    const uint8_t* rgba,
    int width,
    int height,
    int stride,
    float quality,
    uint8_t** outData,
    size_t* outSize
) {
    if (!rgba || !outData || !outSize || width <= 0 || height <= 0) {
        return 0;
    }
    
    size_t outputSize = WebPEncodeRGBA(rgba, width, height, stride, quality, outData);
    if (outputSize == 0 || *outData == NULL) {
        return 0;
    }
    *outSize = outputSize;
    return 1;
}

int WebPBridgeEncodeLossless(
    const uint8_t* rgba,
    int width,
    int height,
    int stride,
    uint8_t** outData,
    size_t* outSize
) {
    if (!rgba || !outData || !outSize || width <= 0 || height <= 0) {
        return 0;
    }
    
    size_t outputSize = WebPEncodeLosslessRGBA(rgba, width, height, stride, outData);
    if (outputSize == 0 || *outData == NULL) {
        return 0;
    }
    *outSize = outputSize;
    return 1;
}

// MARK: - Validation

int WebPBridgeValidate(const uint8_t* data, size_t size) {
    if (!data || size < 12) {
        return 0;
    }
    // Check RIFF signature (bytes 0-3) and WEBP signature (bytes 8-11)
    if (memcmp(data, "RIFF", 4) == 0 && memcmp(data + 8, "WEBP", 4) == 0) {
        return 1;
    }
    return 0;
}

int WebPBridgeGetInfo(const uint8_t* data, size_t size, int* width, int* height) {
    if (!data || !width || !height) {
        return 0;
    }
    return WebPGetInfo(data, size, width, height);
}

// MARK: - Alpha Check

int WebPBridgeHasAlpha(const uint8_t* data, size_t size) {
    if (!data || size < 12) {
        return 0;
    }
    WebPBitstreamFeatures features;
    VP8StatusCode status = WebPGetFeatures(data, size, &features);
    if (status != VP8_STATUS_OK) {
        return 0;
    }
    return features.has_alpha;
}

// MARK: - Memory

void WebPBridgeFreeBuffer(uint8_t* data) {
    WebPFree(data);
}
