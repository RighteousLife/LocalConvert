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

static int WebPBridgeProgressCallback(int percent, const WebPPicture* picture) {
    (void)percent;
    if (!picture || !picture->user_data) {
        return 1;
    }
    const int* cancelFlag = (const int*)picture->user_data;
    if (__atomic_load_n(cancelFlag, __ATOMIC_RELAXED) != 0) {
        return 0; // Abort encode cleanly -> VP8_ENC_ERROR_USER_ABORT
    }
    return 1;
}

int WebPBridgeEncodePixelsEx(
    const uint8_t* pixels,
    int width,
    int height,
    int stride,
    int pixelFormat,
    int lossless,
    float quality,
    int freePixelsAfterImport,
    const int* cancelFlag,
    uint8_t** outData,
    size_t* outSize,
    int* outWasCancelled
) {
    if (outWasCancelled) {
        *outWasCancelled = 0;
    }
    if (!pixels || !outData || !outSize || width <= 0 || height <= 0 || stride <= 0) {
        if (freePixelsAfterImport && pixels) {
            free((void*)pixels);
        }
        return 0;
    }
    if (cancelFlag && __atomic_load_n(cancelFlag, __ATOMIC_RELAXED) != 0) {
        if (freePixelsAfterImport) {
            free((void*)pixels);
        }
        if (outWasCancelled) {
            *outWasCancelled = 1;
        }
        return 0;
    }

    WebPConfig config;
    if (lossless) {
        if (!WebPConfigInit(&config) || !WebPConfigLosslessPreset(&config, 6)) {
            if (freePixelsAfterImport) {
                free((void*)pixels);
            }
            return 0;
        }
    } else {
        if (!WebPConfigPreset(&config, WEBP_PRESET_DEFAULT, quality)) {
            if (freePixelsAfterImport) {
                free((void*)pixels);
            }
            return 0;
        }
    }
    if (!WebPValidateConfig(&config)) {
        if (freePixelsAfterImport) {
            free((void*)pixels);
        }
        return 0;
    }

    WebPPicture pic;
    if (!WebPPictureInit(&pic)) {
        if (freePixelsAfterImport) {
            free((void*)pixels);
        }
        return 0;
    }
    pic.width = width;
    pic.height = height;
    pic.use_argb = lossless ? 1 : 0;

    int imported = 0;
    switch (pixelFormat) {
        case 0: imported = WebPPictureImportRGB(&pic, pixels, stride); break;
        case 1: imported = WebPPictureImportRGBA(&pic, pixels, stride); break;
        case 2: imported = WebPPictureImportRGBX(&pic, pixels, stride); break;
        case 3: imported = WebPPictureImportBGRX(&pic, pixels, stride); break;
        case 4: imported = WebPPictureImportBGRA(&pic, pixels, stride); break;
        default: imported = 0; break;
    }

    // libwebp has copied pixels into pic->y/u/v or pic->argb; release caller's owned RGBA buffer
    // before WebPEncode allocates internal encoder structures so large images avoid double peaks.
    if (freePixelsAfterImport) {
        free((void*)pixels);
    }

    if (!imported) {
        WebPPictureFree(&pic);
        return 0;
    }
    if (cancelFlag) {
        if (__atomic_load_n(cancelFlag, __ATOMIC_RELAXED) != 0) {
            WebPPictureFree(&pic);
            if (outWasCancelled) {
                *outWasCancelled = 1;
            }
            return 0;
        }
        pic.progress_hook = WebPBridgeProgressCallback;
        pic.user_data = (void*)cancelFlag;
    }

    WebPMemoryWriter writer;
    WebPMemoryWriterInit(&writer);
    pic.writer = WebPMemoryWrite;
    pic.custom_ptr = &writer;

    int ok = WebPEncode(&config, &pic);
    WebPEncodingError err = pic.error_code;
    WebPPictureFree(&pic);
    if (!ok || writer.mem == NULL || writer.size == 0) {
        WebPMemoryWriterClear(&writer);
        if (outWasCancelled && (err == VP8_ENC_ERROR_USER_ABORT || (cancelFlag && __atomic_load_n(cancelFlag, __ATOMIC_RELAXED) != 0))) {
            *outWasCancelled = 1;
        }
        return 0;
    }

    *outData = writer.mem;
    *outSize = writer.size;
    return 1;
}

int WebPBridgeEncodePixels(
    const uint8_t* pixels,
    int width,
    int height,
    int stride,
    int pixelFormat,
    int lossless,
    float quality,
    uint8_t** outData,
    size_t* outSize
) {
    return WebPBridgeEncodePixelsEx(
        pixels,
        width,
        height,
        stride,
        pixelFormat,
        lossless,
        quality,
        0,
        NULL,
        outData,
        outSize,
        NULL
    );
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

// MARK: - Memory & Cancellation

void WebPBridgeSetCancelFlag(int* cancelFlag, int cancelled) {
    if (cancelFlag) {
        __atomic_store_n(cancelFlag, cancelled, __ATOMIC_RELAXED);
    }
}

void WebPBridgeFreeBuffer(uint8_t* data) {
    WebPFree(data);
}
