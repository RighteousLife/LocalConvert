// JXLBridge.mm
// C++ implementation bridging LocalConvert Swift layer with official libjxl v0.13.0.
// Copyright © 2026 LocalConvert. All rights reserved.

#define JXL_STATIC_DEFINE 1
#define JXL_THREADS_STATIC_DEFINE 1
#define JXL_CMS_STATIC_DEFINE 1

#include "JXLBridge.h"

#include <jxl/decode.h>
#include <jxl/encode.h>
#include <jxl/codestream_header.h>
#include <jxl/color_encoding.h>
#include <jxl/thread_parallel_runner.h>
#include <jxl/version.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

namespace {

void SetError(char* errBuf, size_t errBufSize, const char* msg) {
    if (errBuf && errBufSize > 0 && msg) {
        std::snprintf(errBuf, errBufSize, "%s", msg);
    }
}

uint8_t* AllocCopy(const uint8_t* src, size_t len) {
    if (!src || len == 0) return nullptr;
    uint8_t* dst = static_cast<uint8_t*>(std::malloc(len));
    if (dst) {
        std::memcpy(dst, src, len);
    }
    return dst;
}

uint32_t RecommendedThreads() {
    size_t n = JxlThreadParallelRunnerDefaultNumWorkerThreads();
    if (n < 1) n = 1;
    if (n > 8) n = 8;
    return static_cast<uint32_t>(n);
}

bool BoxTypeEquals(const JxlBoxType type, const char target[4]) {
    return std::memcmp(type, target, 4) == 0;
}

std::vector<uint8_t> StripExifOffsetIfPresent(const std::vector<uint8_t>& rawBox) {
    // ISO/IEC 18181-2 / ISO BMFF Exif box begins with 4-byte unsigned big-endian tiff_header_offset
    if (rawBox.size() >= 8) {
        uint32_t offset = (static_cast<uint32_t>(rawBox[0]) << 24) |
                          (static_cast<uint32_t>(rawBox[1]) << 16) |
                          (static_cast<uint32_t>(rawBox[2]) << 8) |
                          static_cast<uint32_t>(rawBox[3]);
        if (offset <= rawBox.size() - 8) {
            size_t tiffStart = 4 + static_cast<size_t>(offset);
            const uint8_t* p = rawBox.data() + tiffStart;
            bool isTiffLE = (p[0] == 'I' && p[1] == 'I' && p[2] == 0x2A && p[3] == 0x00);
            bool isTiffBE = (p[0] == 'M' && p[1] == 'M' && p[2] == 0x00 && p[3] == 0x2A);
            if (isTiffLE || isTiffBE) {
                return std::vector<uint8_t>(rawBox.begin() + static_cast<ptrdiff_t>(tiffStart), rawBox.end());
            }
        }
    }
    return rawBox;
}

std::vector<uint8_t> WrapExifWithOffset(const uint8_t* exifData, size_t exifSize) {
    std::vector<uint8_t> out;
    if (!exifData || exifSize == 0) return out;
    bool alreadyHasTiffHeaderDirectly =
        (exifSize >= 4) &&
        ((exifData[0] == 'I' && exifData[1] == 'I' && exifData[2] == 0x2A && exifData[3] == 0x00) ||
         (exifData[0] == 'M' && exifData[1] == 'M' && exifData[2] == 0x00 && exifData[3] == 0x2A));
    if (alreadyHasTiffHeaderDirectly) {
        out.resize(4 + exifSize);
        out[0] = 0; out[1] = 0; out[2] = 0; out[3] = 0;
        std::memcpy(out.data() + 4, exifData, exifSize);
    } else {
        out.assign(exifData, exifData + exifSize);
    }
    return out;
}

uint32_t FrameDurationToMs(uint32_t duration, uint32_t tpsNum, uint32_t tpsDen) {
    if (duration == 0 || tpsNum == 0 || tpsDen == 0) return 0;
    double seconds = (static_cast<double>(duration) * static_cast<double>(tpsDen)) / static_cast<double>(tpsNum);
    long long ms = std::llround(seconds * 1000.0);
    if (ms < 0) return 0;
    return static_cast<uint32_t>(ms);
}

int RunDecodeOrInspect(
    const uint8_t* data,
    size_t size,
    bool decodePixels,
    int prefer_16bit,
    int decode_all_frames,
    JXLBridgeDecodedResult* outResult,
    char* errBuf,
    size_t errBufSize
) {
    if (!data || size == 0 || !outResult) {
        SetError(errBuf, errBufSize, "Invalid input buffer or output pointer.");
        return 0;
    }

    std::memset(outResult, 0, sizeof(*outResult));

    JxlSignature sig = JxlSignatureCheck(data, size);
    if (sig != JXL_SIG_CODESTREAM && sig != JXL_SIG_CONTAINER) {
        SetError(errBuf, errBufSize, "Input is not a valid JPEG XL codestream or container.");
        return 0;
    }
    outResult->info.is_container = (sig == JXL_SIG_CONTAINER) ? 1 : 0;

    std::unique_ptr<JxlDecoder, decltype(&JxlDecoderDestroy)> dec(JxlDecoderCreate(nullptr), JxlDecoderDestroy);
    if (!dec) {
        SetError(errBuf, errBufSize, "Failed to allocate JxlDecoder.");
        return 0;
    }

    std::unique_ptr<void, decltype(&JxlThreadParallelRunnerDestroy)> runner(
        JxlThreadParallelRunnerCreate(nullptr, RecommendedThreads()),
        JxlThreadParallelRunnerDestroy
    );
    if (runner) {
        if (JxlDecoderSetParallelRunner(dec.get(), JxlThreadParallelRunner, runner.get()) != JXL_DEC_SUCCESS) {
            SetError(errBuf, errBufSize, "Failed to configure JxlDecoder parallel runner.");
            return 0;
        }
    }

    // Important: keep orientation automatically applied so UI & conversion match normal orientation.
    JxlDecoderSetKeepOrientation(dec.get(), JXL_FALSE);
    JxlDecoderSetDecompressBoxes(dec.get(), JXL_TRUE);

    int events = JXL_DEC_BASIC_INFO | JXL_DEC_COLOR_ENCODING | JXL_DEC_BOX | JXL_DEC_FRAME;
    if (decodePixels) {
        events |= JXL_DEC_FULL_IMAGE;
    } else {
        events |= JXL_DEC_JPEG_RECONSTRUCTION;
    }
    if (JxlDecoderSubscribeEvents(dec.get(), events) != JXL_DEC_SUCCESS) {
        SetError(errBuf, errBufSize, "Failed to subscribe JxlDecoder events.");
        return 0;
    }

    if (JxlDecoderSetInput(dec.get(), data, size) != JXL_DEC_SUCCESS) {
        SetError(errBuf, errBufSize, "Failed to set input buffer on JxlDecoder.");
        return 0;
    }
    JxlDecoderCloseInput(dec.get());

    JxlBasicInfo basicInfo{};
    bool hasBasicInfo = false;
    std::vector<uint8_t> iccProfile;
    std::vector<uint8_t> exifBox;
    std::vector<uint8_t> xmpBox;
    std::vector<JXLBridgeDecodedFrame> decodedFrames;

    // Active metadata box tracking
    bool collectingBox = false;
    bool collectingExif = false;
    bool collectingXmp = false;
    std::vector<uint8_t> boxBuf;

    auto FlushBoxIfActive = [&]() {
        if (!collectingBox) return;
        size_t remaining = JxlDecoderReleaseBoxBuffer(dec.get());
        size_t written = boxBuf.size() > remaining ? boxBuf.size() - remaining : 0;
        boxBuf.resize(written);
        if (collectingExif && exifBox.empty() && !boxBuf.empty()) {
            exifBox = StripExifOffsetIfPresent(boxBuf);
            outResult->info.has_exif = 1;
        } else if (collectingXmp && xmpBox.empty() && !boxBuf.empty()) {
            xmpBox = boxBuf;
            outResult->info.has_xmp = 1;
        }
        boxBuf.clear();
        collectingBox = false;
        collectingExif = false;
        collectingXmp = false;
    };

    JxlFrameHeader currentFrameHeader{};
    uint32_t currentBitsPerSample = 8;
    std::vector<uint8_t> currentPixelBuf;
    std::vector<uint8_t> dummyJpegBuf;

    auto FailCleanup = [&](const char* msg) -> int {
        for (auto& f : decodedFrames) {
            std::free(f.pixel_data);
        }
        SetError(errBuf, errBufSize, msg);
        return 0;
    };

    for (;;) {
        JxlDecoderStatus status = JxlDecoderProcessInput(dec.get());
        if (status == JXL_DEC_ERROR) {
            return FailCleanup("libjxl decoder encountered a decoding error.");
        } else if (status == JXL_DEC_NEED_MORE_INPUT) {
            return FailCleanup("Unexpected end of JPEG XL input.");
        } else if (status == JXL_DEC_SUCCESS) {
            FlushBoxIfActive();
            break;
        } else if (status == JXL_DEC_BASIC_INFO) {
            if (JxlDecoderGetBasicInfo(dec.get(), &basicInfo) != JXL_DEC_SUCCESS) {
                return FailCleanup("Failed to read JxlBasicInfo.");
            }
            hasBasicInfo = true;
            outResult->info.width = basicInfo.xsize;
            outResult->info.height = basicInfo.ysize;
            outResult->info.bits_per_sample = basicInfo.bits_per_sample;
            outResult->info.exponent_bits_per_sample = basicInfo.exponent_bits_per_sample;
            outResult->info.alpha_bits = basicInfo.alpha_bits;
            outResult->info.num_color_channels = basicInfo.num_color_channels;
            outResult->info.orientation = static_cast<int>(basicInfo.orientation);
            outResult->info.have_animation = basicInfo.have_animation ? 1 : 0;
            outResult->info.tps_numerator = basicInfo.animation.tps_numerator;
            outResult->info.tps_denominator = basicInfo.animation.tps_denominator;
            outResult->info.num_loops = basicInfo.animation.num_loops;
        } else if (status == JXL_DEC_COLOR_ENCODING) {
            size_t iccSize = 0;
            if (JxlDecoderGetICCProfileSize(dec.get(), JXL_COLOR_PROFILE_TARGET_DATA, &iccSize) == JXL_DEC_SUCCESS && iccSize > 0) {
                iccProfile.resize(iccSize);
                if (JxlDecoderGetColorAsICCProfile(dec.get(), JXL_COLOR_PROFILE_TARGET_DATA, iccProfile.data(), iccSize) == JXL_DEC_SUCCESS) {
                    outResult->info.has_icc = 1;
                } else {
                    iccProfile.clear();
                }
            }
        } else if (status == JXL_DEC_JPEG_RECONSTRUCTION) {
            outResult->info.is_jpeg_reconstructable = 1;
            if (!decodePixels) {
                dummyJpegBuf.resize(65536);
                JxlDecoderSetJPEGBuffer(dec.get(), dummyJpegBuf.data(), dummyJpegBuf.size());
            }
        } else if (status == JXL_DEC_JPEG_NEED_MORE_OUTPUT) {
            size_t rem = JxlDecoderReleaseJPEGBuffer(dec.get());
            size_t used = dummyJpegBuf.size() - rem;
            dummyJpegBuf.resize(std::max<size_t>(used * 2, dummyJpegBuf.size() + 65536));
            JxlDecoderSetJPEGBuffer(dec.get(), dummyJpegBuf.data() + used, dummyJpegBuf.size() - used);
        } else if (status == JXL_DEC_BOX) {
            FlushBoxIfActive();
            JxlBoxType btype{};
            if (JxlDecoderGetBoxType(dec.get(), btype, JXL_TRUE) == JXL_DEC_SUCCESS) {
                bool isExif = BoxTypeEquals(btype, "Exif");
                bool isXml = BoxTypeEquals(btype, "xml ");
                if (isExif || isXml) {
                    uint64_t rawSize = 0;
                    JxlDecoderGetBoxSizeRaw(dec.get(), &rawSize);
                    size_t initialCap = rawSize > 0 && rawSize < (16ULL * 1024ULL * 1024ULL)
                        ? std::max<size_t>(static_cast<size_t>(rawSize) * 2, 4096)
                        : 16384;
                    boxBuf.resize(initialCap);
                    if (JxlDecoderSetBoxBuffer(dec.get(), boxBuf.data(), boxBuf.size()) == JXL_DEC_SUCCESS) {
                        collectingBox = true;
                        collectingExif = isExif;
                        collectingXmp = isXml;
                    } else {
                        boxBuf.clear();
                    }
                }
            }
        } else if (status == JXL_DEC_BOX_NEED_MORE_OUTPUT) {
            if (collectingBox) {
                size_t rem = JxlDecoderReleaseBoxBuffer(dec.get());
                size_t used = boxBuf.size() > rem ? boxBuf.size() - rem : 0;
                boxBuf.resize(std::max<size_t>(boxBuf.size() * 2, used + 16384));
                if (JxlDecoderSetBoxBuffer(dec.get(), boxBuf.data() + used, boxBuf.size() - used) != JXL_DEC_SUCCESS) {
                    collectingBox = false;
                    boxBuf.clear();
                }
            }
        } else if (status == JXL_DEC_FRAME) {
            outResult->info.frame_count += 1;
            std::memset(&currentFrameHeader, 0, sizeof(currentFrameHeader));
            JxlDecoderGetFrameHeader(dec.get(), &currentFrameHeader);
        } else if (status == JXL_DEC_NEED_IMAGE_OUT_BUFFER) {
            if (!decodePixels) {
                return FailCleanup("Unexpected image buffer request during inspect.");
            }
            if (!hasBasicInfo) {
                return FailCleanup("Basic info unavailable before pixel decode.");
            }
            bool use16 = (prefer_16bit != 0) && (basicInfo.bits_per_sample > 8);
            currentBitsPerSample = use16 ? 16 : 8;
            JxlPixelFormat fmt{};
            fmt.num_channels = 4;
            fmt.data_type = use16 ? JXL_TYPE_UINT16 : JXL_TYPE_UINT8;
            fmt.endianness = JXL_NATIVE_ENDIAN;
            fmt.align = 0;

            size_t bufferSize = 0;
            if (JxlDecoderImageOutBufferSize(dec.get(), &fmt, &bufferSize) != JXL_DEC_SUCCESS || bufferSize == 0) {
                return FailCleanup("Failed to calculate output pixel buffer size.");
            }
            currentPixelBuf.resize(bufferSize);
            if (JxlDecoderSetImageOutBuffer(dec.get(), &fmt, currentPixelBuf.data(), currentPixelBuf.size()) != JXL_DEC_SUCCESS) {
                return FailCleanup("Failed to bind JXL image output buffer.");
            }
        } else if (status == JXL_DEC_FULL_IMAGE) {
            if (decodePixels && !currentPixelBuf.empty()) {
                JXLBridgeDecodedFrame frame{};
                frame.pixel_size = currentPixelBuf.size();
                frame.pixel_data = AllocCopy(currentPixelBuf.data(), currentPixelBuf.size());
                if (!frame.pixel_data) {
                    return FailCleanup("Out of memory allocating decoded frame buffer.");
                }
                frame.width = basicInfo.xsize;
                frame.height = basicInfo.ysize;
                frame.bits_per_sample = currentBitsPerSample;
                frame.duration_ms = FrameDurationToMs(
                    currentFrameHeader.duration,
                    basicInfo.animation.tps_numerator,
                    basicInfo.animation.tps_denominator
                );
                decodedFrames.push_back(frame);
                currentPixelBuf.clear();

                if (!decode_all_frames) {
                    if (basicInfo.have_animation) {
                        // Unsubscribe pixel events so trailing container metadata boxes (Exif/XMP) still deliver
                        JxlDecoderSubscribeEvents(dec.get(), JXL_DEC_BOX);
                        decodePixels = false;
                    }
                }
            }
        }
    }

    if (!hasBasicInfo) {
        return FailCleanup("No JXL basic info found.");
    }

    if (outResult->info.frame_count == 0) {
        outResult->info.frame_count = static_cast<uint32_t>(std::max<size_t>(1, decodedFrames.size()));
    }

    if (!decodedFrames.empty()) {
        outResult->frame_count = decodedFrames.size();
        outResult->frames = static_cast<JXLBridgeDecodedFrame*>(
            std::calloc(decodedFrames.size(), sizeof(JXLBridgeDecodedFrame))
        );
        if (!outResult->frames) {
            return FailCleanup("Out of memory allocating frames array.");
        }
        std::memcpy(outResult->frames, decodedFrames.data(), decodedFrames.size() * sizeof(JXLBridgeDecodedFrame));
    }

    if (!iccProfile.empty()) {
        outResult->icc_data = AllocCopy(iccProfile.data(), iccProfile.size());
        outResult->icc_size = iccProfile.size();
    }
    if (!exifBox.empty()) {
        outResult->exif_data = AllocCopy(exifBox.data(), exifBox.size());
        outResult->exif_size = exifBox.size();
    }
    if (!xmpBox.empty()) {
        outResult->xmp_data = AllocCopy(xmpBox.data(), xmpBox.size());
        outResult->xmp_size = xmpBox.size();
    }

    return 1;
}

int DrainEncoder(JxlEncoder* enc, std::vector<uint8_t>& out, char* errBuf, size_t errBufSize) {
    out.clear();
    uint8_t chunk[65536];
    for (;;) {
        uint8_t* nextOut = chunk;
        size_t availOut = sizeof(chunk);
        JxlEncoderStatus status = JxlEncoderProcessOutput(enc, &nextOut, &availOut);
        size_t produced = sizeof(chunk) - availOut;
        if (produced > 0) {
            out.insert(out.end(), chunk, chunk + produced);
        }
        if (status == JXL_ENC_NEED_MORE_OUTPUT) {
            continue;
        } else if (status == JXL_ENC_SUCCESS) {
            return 1;
        } else {
            JxlEncoderError err = JxlEncoderGetError(enc);
            char msg[128];
            std::snprintf(msg, sizeof(msg), "libjxl encoder failed (code %d).", static_cast<int>(err));
            SetError(errBuf, errBufSize, msg);
            return 0;
        }
    }
}

} // namespace

extern "C" {

const char* JXLBridgeVersion(void) {
    static char versionBuf[32];
    uint32_t ver = JxlDecoderVersion();
    uint32_t major = ver / 1000000;
    uint32_t minor = (ver / 1000) % 1000;
    uint32_t patch = ver % 1000;
    std::snprintf(versionBuf, sizeof(versionBuf), "%u.%u.%u", major, minor, patch);
    return versionBuf;
}

int JXLBridgeValidate(const uint8_t* data, size_t size) {
    if (!data || size == 0) return 0;
    JxlSignature sig = JxlSignatureCheck(data, size);
    if (sig == JXL_SIG_CODESTREAM) return 1;
    if (sig == JXL_SIG_CONTAINER) return 2;
    return 0;
}

int JXLBridgeInspect(
    const uint8_t* data,
    size_t size,
    JXLBridgeDecodedResult* outResult,
    char* errBuf,
    size_t errBufSize
) {
    return RunDecodeOrInspect(data, size, false, 0, 0, outResult, errBuf, errBufSize);
}

int JXLBridgeDecode(
    const uint8_t* data,
    size_t size,
    int prefer_16bit,
    int decode_all_frames,
    JXLBridgeDecodedResult* outResult,
    char* errBuf,
    size_t errBufSize
) {
    return RunDecodeOrInspect(data, size, true, prefer_16bit, decode_all_frames, outResult, errBuf, errBufSize);
}

void JXLBridgeFreeDecodedResult(JXLBridgeDecodedResult* result) {
    if (!result) return;
    if (result->frames) {
        for (size_t i = 0; i < result->frame_count; ++i) {
            std::free(result->frames[i].pixel_data);
        }
        std::free(result->frames);
    }
    std::free(result->icc_data);
    std::free(result->exif_data);
    std::free(result->xmp_data);
    std::memset(result, 0, sizeof(*result));
}

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
) {
    if (!frames || frame_count == 0 || !outData || !outSize) {
        SetError(errBuf, errBufSize, "Invalid encode parameters.");
        return 0;
    }
    *outData = nullptr;
    *outSize = 0;

    const uint32_t width = frames[0].width;
    const uint32_t height = frames[0].height;
    if (width == 0 || height == 0) {
        SetError(errBuf, errBufSize, "Image dimensions must be greater than zero.");
        return 0;
    }

    const int clampedBits = (bits_per_sample >= 16) ? 16 : 8;
    const int clampedEffort = std::min(9, std::max(1, effort));
    const bool isAnimated = frame_count > 1;

    std::unique_ptr<JxlEncoder, decltype(&JxlEncoderDestroy)> enc(JxlEncoderCreate(nullptr), JxlEncoderDestroy);
    if (!enc) {
        SetError(errBuf, errBufSize, "Failed to create JxlEncoder.");
        return 0;
    }

    std::unique_ptr<void, decltype(&JxlThreadParallelRunnerDestroy)> runner(
        JxlThreadParallelRunnerCreate(nullptr, RecommendedThreads()),
        JxlThreadParallelRunnerDestroy
    );
    if (runner) {
        JxlEncoderSetParallelRunner(enc.get(), JxlThreadParallelRunner, runner.get());
    }

    bool hasBoxes = (exif_data && exif_size > 0) || (xmp_data && xmp_size > 0);
    if (use_container || hasBoxes) {
        if (JxlEncoderUseContainer(enc.get(), JXL_TRUE) != JXL_ENC_SUCCESS) {
            SetError(errBuf, errBufSize, "Failed to enable JXL container format.");
            return 0;
        }
    }
    if (hasBoxes) {
        if (JxlEncoderUseBoxes(enc.get()) != JXL_ENC_SUCCESS) {
            SetError(errBuf, errBufSize, "Failed to enable JXL metadata boxes.");
            return 0;
        }
    }

    JxlBasicInfo basicInfo{};
    JxlEncoderInitBasicInfo(&basicInfo);
    basicInfo.xsize = width;
    basicInfo.ysize = height;
    basicInfo.bits_per_sample = static_cast<uint32_t>(clampedBits);
    basicInfo.exponent_bits_per_sample = 0;
    basicInfo.num_color_channels = 3;
    basicInfo.num_extra_channels = has_alpha ? 1 : 0;
    basicInfo.alpha_bits = has_alpha ? static_cast<uint32_t>(clampedBits) : 0;
    basicInfo.alpha_premultiplied = JXL_FALSE;
    basicInfo.uses_original_profile = lossless ? JXL_TRUE : JXL_FALSE;
    if (isAnimated) {
        basicInfo.have_animation = JXL_TRUE;
        basicInfo.animation.tps_numerator = tps_numerator > 0 ? tps_numerator : 1000;
        basicInfo.animation.tps_denominator = tps_denominator > 0 ? tps_denominator : 1;
        basicInfo.animation.num_loops = num_loops;
        basicInfo.animation.have_timecodes = JXL_FALSE;
    }

    if (JxlEncoderSetBasicInfo(enc.get(), &basicInfo) != JXL_ENC_SUCCESS) {
        SetError(errBuf, errBufSize, "Failed to set JxlBasicInfo.");
        return 0;
    }

    if (icc_data && icc_size > 0) {
        if (JxlEncoderSetICCProfile(enc.get(), icc_data, icc_size) != JXL_ENC_SUCCESS) {
            SetError(errBuf, errBufSize, "Failed to embed ICC profile in JXL.");
            return 0;
        }
    } else {
        JxlColorEncoding colorEncoding{};
        JxlColorEncodingSetToSRGB(&colorEncoding, JXL_FALSE);
        JxlEncoderSetColorEncoding(enc.get(), &colorEncoding);
    }

    JxlPixelFormat pixFmt{};
    pixFmt.num_channels = has_alpha ? 4 : 3;
    pixFmt.data_type = (clampedBits == 16) ? JXL_TYPE_UINT16 : JXL_TYPE_UINT8;
    pixFmt.endianness = JXL_NATIVE_ENDIAN;
    pixFmt.align = 0;

    float resolvedDistance = distance;
    if (lossless) {
        resolvedDistance = 0.0f;
    } else if (resolvedDistance < 0.0f) {
        float q = std::min(100.0f, std::max(0.0f, quality_0_100));
        resolvedDistance = JxlEncoderDistanceFromQuality(q);
        // If quality < 100, ensure not unintentionally distance 0 unless lossless requested
        if (q < 99.9f && resolvedDistance < 0.05f) {
            resolvedDistance = 0.05f;
        }
    }

    for (size_t i = 0; i < frame_count; ++i) {
        const JXLBridgeEncodeFrameInput& f = frames[i];
        if (!f.pixel_data || f.pixel_size == 0) {
            SetError(errBuf, errBufSize, "Frame pixel buffer is null or empty.");
            return 0;
        }
        JxlEncoderFrameSettings* frameOpts = JxlEncoderFrameSettingsCreate(enc.get(), nullptr);
        if (!frameOpts) {
            SetError(errBuf, errBufSize, "Failed to allocate JxlEncoderFrameSettings.");
            return 0;
        }
        JxlEncoderFrameSettingsSetOption(frameOpts, JXL_ENC_FRAME_SETTING_EFFORT, clampedEffort);
        if (lossless) {
            JxlEncoderSetFrameLossless(frameOpts, JXL_TRUE);
            JxlEncoderSetFrameDistance(frameOpts, 0.0f);
        } else {
            JxlEncoderSetFrameLossless(frameOpts, JXL_FALSE);
            JxlEncoderSetFrameDistance(frameOpts, std::min(25.0f, std::max(0.0f, resolvedDistance)));
        }

        if (isAnimated) {
            JxlFrameHeader fh{};
            JxlEncoderInitFrameHeader(&fh);
            fh.duration = f.duration_ms > 0 ? f.duration_ms : 100;
            JxlEncoderSetFrameHeader(frameOpts, &fh);
        }

        if (JxlEncoderAddImageFrame(frameOpts, &pixFmt, f.pixel_data, f.pixel_size) != JXL_ENC_SUCCESS) {
            SetError(errBuf, errBufSize, "Failed to encode JPEG XL frame pixels.");
            return 0;
        }
    }

    if (hasBoxes) {
        if (exif_data && exif_size > 0) {
            std::vector<uint8_t> wrapped = WrapExifWithOffset(exif_data, exif_size);
            JxlBoxType boxType = {'E', 'x', 'i', 'f'};
            if (JxlEncoderAddBox(enc.get(), boxType, wrapped.data(), wrapped.size(), JXL_TRUE) != JXL_ENC_SUCCESS) {
                SetError(errBuf, errBufSize, "Failed to add Exif box to JXL container.");
                return 0;
            }
        }
        if (xmp_data && xmp_size > 0) {
            JxlBoxType boxType = {'x', 'm', 'l', ' '};
            if (JxlEncoderAddBox(enc.get(), boxType, xmp_data, xmp_size, JXL_TRUE) != JXL_ENC_SUCCESS) {
                SetError(errBuf, errBufSize, "Failed to add XMP box to JXL container.");
                return 0;
            }
        }
    }

    JxlEncoderCloseInput(enc.get());

    std::vector<uint8_t> encoded;
    if (!DrainEncoder(enc.get(), encoded, errBuf, errBufSize) || encoded.empty()) {
        return 0;
    }

    uint8_t* heapBuf = AllocCopy(encoded.data(), encoded.size());
    if (!heapBuf) {
        SetError(errBuf, errBufSize, "Out of memory allocating output buffer.");
        return 0;
    }
    *outData = heapBuf;
    *outSize = encoded.size();
    return 1;
}

int JXLBridgeTranscodeJPEG(
    const uint8_t* jpegData,
    size_t jpegSize,
    int effort,
    int store_jpeg_metadata,
    uint8_t** outData,
    size_t* outSize,
    char* errBuf,
    size_t errBufSize
) {
    if (!jpegData || jpegSize < 4 || !outData || !outSize) {
        SetError(errBuf, errBufSize, "Invalid JPEG input for lossless JXL transcoding.");
        return 0;
    }
    *outData = nullptr;
    *outSize = 0;

    std::unique_ptr<JxlEncoder, decltype(&JxlEncoderDestroy)> enc(JxlEncoderCreate(nullptr), JxlEncoderDestroy);
    if (!enc) {
        SetError(errBuf, errBufSize, "Failed to create JxlEncoder.");
        return 0;
    }

    std::unique_ptr<void, decltype(&JxlThreadParallelRunnerDestroy)> runner(
        JxlThreadParallelRunnerCreate(nullptr, RecommendedThreads()),
        JxlThreadParallelRunnerDestroy
    );
    if (runner) {
        JxlEncoderSetParallelRunner(enc.get(), JxlThreadParallelRunner, runner.get());
    }

    JxlEncoderUseContainer(enc.get(), JXL_TRUE);
    if (JxlEncoderStoreJPEGMetadata(enc.get(), store_jpeg_metadata ? JXL_TRUE : JXL_FALSE) != JXL_ENC_SUCCESS) {
        SetError(errBuf, errBufSize, "Failed to enable JPEG metadata storage in JxlEncoder.");
        return 0;
    }

    JxlEncoderFrameSettings* frameOpts = JxlEncoderFrameSettingsCreate(enc.get(), nullptr);
    if (!frameOpts) {
        SetError(errBuf, errBufSize, "Failed to create JxlEncoderFrameSettings.");
        return 0;
    }
    const int clampedEffort = std::min(9, std::max(1, effort));
    JxlEncoderFrameSettingsSetOption(frameOpts, JXL_ENC_FRAME_SETTING_EFFORT, clampedEffort);

    if (JxlEncoderAddJPEGFrame(frameOpts, jpegData, jpegSize) != JXL_ENC_SUCCESS) {
        SetError(errBuf, errBufSize, "JPEG could not be losslessly transcoded by libjxl (for example progressive/arithmetic/CMYK or unsupported SOF).");
        return 0;
    }

    JxlEncoderCloseInput(enc.get());

    std::vector<uint8_t> encoded;
    if (!DrainEncoder(enc.get(), encoded, errBuf, errBufSize) || encoded.empty()) {
        return 0;
    }

    uint8_t* heapBuf = AllocCopy(encoded.data(), encoded.size());
    if (!heapBuf) {
        SetError(errBuf, errBufSize, "Out of memory allocating transcoded JXL buffer.");
        return 0;
    }
    *outData = heapBuf;
    *outSize = encoded.size();
    return 1;
}

int JXLBridgeReconstructJPEG(
    const uint8_t* jxlData,
    size_t jxlSize,
    uint8_t** outData,
    size_t* outSize,
    char* errBuf,
    size_t errBufSize
) {
    if (!jxlData || jxlSize == 0 || !outData || !outSize) {
        SetError(errBuf, errBufSize, "Invalid JXL input.");
        return 0;
    }
    *outData = nullptr;
    *outSize = 0;

    std::unique_ptr<JxlDecoder, decltype(&JxlDecoderDestroy)> dec(JxlDecoderCreate(nullptr), JxlDecoderDestroy);
    if (!dec) {
        SetError(errBuf, errBufSize, "Failed to create JxlDecoder.");
        return 0;
    }

    std::unique_ptr<void, decltype(&JxlThreadParallelRunnerDestroy)> runner(
        JxlThreadParallelRunnerCreate(nullptr, RecommendedThreads()),
        JxlThreadParallelRunnerDestroy
    );
    if (runner) {
        JxlDecoderSetParallelRunner(dec.get(), JxlThreadParallelRunner, runner.get());
    }

    if (JxlDecoderSubscribeEvents(dec.get(), JXL_DEC_JPEG_RECONSTRUCTION | JXL_DEC_FULL_IMAGE) != JXL_DEC_SUCCESS) {
        SetError(errBuf, errBufSize, "Failed to subscribe JPEG reconstruction events.");
        return 0;
    }

    JxlDecoderSetInput(dec.get(), jxlData, jxlSize);
    JxlDecoderCloseInput(dec.get());

    bool sawJpegRecon = false;
    std::vector<uint8_t> jpegOut;
    size_t written = 0;

    for (;;) {
        JxlDecoderStatus status = JxlDecoderProcessInput(dec.get());
        if (status == JXL_DEC_ERROR || status == JXL_DEC_NEED_MORE_INPUT) {
            SetError(errBuf, errBufSize, "Failed during JPEG reconstruction.");
            return 0;
        } else if (status == JXL_DEC_JPEG_RECONSTRUCTION) {
            sawJpegRecon = true;
            jpegOut.resize(std::max<size_t>(jxlSize * 2, 131072));
            if (JxlDecoderSetJPEGBuffer(dec.get(), jpegOut.data(), jpegOut.size()) != JXL_DEC_SUCCESS) {
                SetError(errBuf, errBufSize, "Failed to bind JPEG reconstruction buffer.");
                return 0;
            }
        } else if (status == JXL_DEC_JPEG_NEED_MORE_OUTPUT) {
            size_t rem = JxlDecoderReleaseJPEGBuffer(dec.get());
            written = jpegOut.size() - rem;
            jpegOut.resize(std::max<size_t>(jpegOut.size() * 2, written + 131072));
            if (JxlDecoderSetJPEGBuffer(dec.get(), jpegOut.data() + written, jpegOut.size() - written) != JXL_DEC_SUCCESS) {
                SetError(errBuf, errBufSize, "Failed to grow JPEG reconstruction buffer.");
                return 0;
            }
        } else if (status == JXL_DEC_FULL_IMAGE) {
            if (!sawJpegRecon) {
                SetError(errBuf, errBufSize, "This JPEG XL file does not contain lossless JPEG reconstruction data.");
                return 0;
            }
            size_t rem = JxlDecoderReleaseJPEGBuffer(dec.get());
            written = jpegOut.size() - rem;
            jpegOut.resize(written);
        } else if (status == JXL_DEC_SUCCESS) {
            break;
        }
    }

    if (!sawJpegRecon || jpegOut.empty()) {
        SetError(errBuf, errBufSize, "This JPEG XL file does not support lossless JPEG bitstream reconstruction.");
        return 0;
    }

    uint8_t* heapBuf = AllocCopy(jpegOut.data(), jpegOut.size());
    if (!heapBuf) {
        SetError(errBuf, errBufSize, "Out of memory allocating reconstructed JPEG buffer.");
        return 0;
    }
    *outData = heapBuf;
    *outSize = jpegOut.size();
    return 1;
}

void JXLBridgeFreeBuffer(void* ptr) {
    std::free(ptr);
}

} // extern "C"
