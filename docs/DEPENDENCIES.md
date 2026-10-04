# LocalConvert — External Dependencies & Licensing Guide

This document provides a factual, verified inventory of all external runtimes, binary components, and dynamic libraries integrated with or bundled into **LocalConvert**.

---

## 1. libwebp

- **Component**: `libwebp`
- **Version**: 1.6.0
- **Purpose**: WebP raster image encoding backend for `* → WEBP` conversions (macOS native ImageIO decodes WebP but lacks encoding capability).
- **License**: BSD 3-Clause License (Google LLC)
- **Distribution Status**: Bundled dynamic library (`LocalConvert/Frameworks/libwebp.dylib`, copied into `Contents/Frameworks/`).
- **Source / Provenance**: Google WebP upstream source (`https://chromium.googlesource.com/webm/libwebp`), built for arm64 with install name `@rpath/libwebp.dylib`.
- **License File Location**: Bundled at [`LocalConvert/Frameworks/LICENSE.webp`](../LocalConvert/Frameworks/LICENSE.webp) and documented in [`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md).
- **Notes**: Links dynamically to `@rpath/libsharpyuv.dylib` and `/usr/lib/libSystem.B.dylib`. Completely decoupled from Homebrew (`otool -L` confirms zero `/opt/homebrew` references). Communicates with Swift via `WebPBridge.c`/`WebPBridge.h`. Straight-alpha unpremultiplication applied prior to calling `WebPEncodeRGBA`.

---

## 2. libsharpyuv

- **Component**: `libsharpyuv`
- **Version**: 0.1.2 (internal compatibility version 2.2.0)
- **Purpose**: High-quality RGB-to-YUV color conversion helper library required by `libwebp`.
- **License**: BSD 3-Clause License (Google LLC)
- **Distribution Status**: Bundled dynamic library (`LocalConvert/Frameworks/libsharpyuv.dylib`, copied into `Contents/Frameworks/`).
- **Source / Provenance**: Google WebP repository sub-library, built for arm64 with install name `@rpath/libsharpyuv.dylib`.
- **License File Location**: Bundled at [`LocalConvert/Frameworks/LICENSE.webp`](../LocalConvert/Frameworks/LICENSE.webp).
- **Notes**: Direct dependency of `libwebp.dylib`. Embedded and codesigned during Xcode build.

---

## 3. FFmpeg & ffprobe

- **Component**: `FFmpeg` / `ffprobe`
- **Version**: 9.0.2
- **Purpose**: Audio & video decoding, encoding, container repackaging, audio extraction, and stream metadata inspection.
- **License**: GNU Lesser General Public License version 3.0 or later (LGPLv3+)
- **Distribution Status**: Bundled standalone static executable (`LocalConvert/Resources/ffmpeg/ffmpeg`, `LocalConvert/Resources/ffmpeg/ffprobe`, copied into `Contents/Resources/ffmpeg/`).
- **Source / Provenance**: FFmpeg official release 9.0.2 (`https://ffmpeg.org`). Compiled from source targeting Apple Silicon (`arm64`).
- **License File Location**: Bundled at [`LocalConvert/Resources/ffmpeg/FFmpeg-LICENSE.txt`](../LocalConvert/Resources/ffmpeg/FFmpeg-LICENSE.txt) and [`LocalConvert/Resources/ffmpeg/FFmpeg-BUILDCONF.txt`](../LocalConvert/Resources/ffmpeg/FFmpeg-BUILDCONF.txt).
- **Notes**:
  - **Configure Flags (Verified from binary via `-buildconf`)**:
    `--prefix=/tmp/LocalConvert-FFmpeg --enable-static --disable-shared --pkg-config-flags=--static --enable-pthreads --enable-version3 --cc=clang --extra-cflags=-I/opt/homebrew/include --extra-ldflags=-L/tmp/static-libs --extra-libs=-lmpg123 --enable-videotoolbox --enable-audiotoolbox --enable-neon --enable-libmp3lame --enable-libopus --enable-libvpx --disable-ffplay --disable-doc --disable-debug`
  - **GPL Status**: `--enable-gpl` is **NOT** enabled. No GPL modules or filters are present in the build.
  - **Nonfree Status**: `--enable-nonfree` is **NOT** enabled.
  - **Version 3 Status**: `--enable-version3` was specified, upgrading licensing terms to LGPLv3+.
  - **Process Isolation**: Invoked strictly via `Foundation.Process()` with separate argument vectors. No shell evaluation (`sh -c`) is used.
  - **Statically Linked Third-Party Codec Libraries**:
    1. `libmp3lame` (v3.100 / 4.0): LGPLv2+ (MP3 encoding)
    2. `libmpg123` (v1.33.7): LGPLv2.1 (MPEG audio decoding)
    3. `libopus` (v1.6.1): BSD 3-Clause (Opus audio encoding/decoding)
    4. `libvpx` (v1.17.0): BSD 3-Clause (VP8/VP9 video encoding/decoding)
  - **Apple System Frameworks**: Hardware acceleration via `VideoToolbox.framework` (`h264_videotoolbox`, `hevc_videotoolbox`) and `AudioToolbox.framework`. Dynamic linkage verified via `otool -L` (exclusively macOS system frameworks; zero Homebrew paths).

---

## 4. LibreOffice Runtime

- **Component**: `LibreOffice` (Headless Runtime)
- **Version**: 26.8.0.3 (Build: `bce0998afefdbc355585ca324285661a2170ba77`)
- **Purpose**: Headless conversion backend for Office document formats (`DOCX`, `XLSX`, `PPTX`, `ODT`, `ODS`, `ODP`, etc. → `PDF`) and PDF-to-Office document conversions (`PDF` → `DOCX`, `PDF` → `PPTX`, `PDF` → `XLSX`).
- **License**: Mozilla Public License 2.0 (MPL 2.0) primary license, with various subcomponent notices (including Poppler data, Python PSF, and ICU).
- **Distribution Status**: Bundled headless runtime directory in local working tree (`LocalConvert/Resources/LibreOffice/Contents/MacOS/soffice`). Distributed externally via GitHub Release archive due to size (~720 MB total; `libmergedlo.dylib` is 137 MB).
- **Source / Provenance**: The Document Foundation official macOS arm64 release (`https://www.libreoffice.org/`).
- **License File Location**: Bundled notice file at [`LocalConvert/Resources/LibreOffice/Contents/Resources/readmes/README_en-US`](../LocalConvert/Resources/LibreOffice/Contents/Resources/readmes/README_en-US). Additional upstream copyright and license documentation: `https://www.libreoffice.org/about-us/licenses/` and `https://git.libreoffice.org/core/tree/master/COPYING`.
- **Notes**:
  - **Process Sandboxing**: Every invocation is supplied with an isolated temporary user profile (`-env:UserInstallation=file://<temp_dir>`) to ensure no user lockups or settings corruption.
  - **Subprocess Execution**: Communicates strictly across standard macOS process boundaries via `Process()`. LocalConvert contains no direct linking to LibreOffice C/C++ libraries.
  - **Non-Headless Pruning**: Graphical clipart and offline help packages were pruned to reduce size while retaining full CLI conversion capabilities.
  - **Bytecode Hygiene**: Copied with `PYTHONDONTWRITEBYTECODE=1` and post-build pruning to prevent `.pyc` creation from invalidating code signatures.

---

## 5. Summary Table of Dependencies

| Component | Version | License | Distribution |
|---|---:|---|---|
| FFmpeg | 9.0.2 | LGPLv3+ | Bundled |
| libmp3lame | 3.100 / 4.0 | LGPLv2+ | Statically linked into FFmpeg |
| libmpg123 | 1.33.7 | LGPLv2.1 | Statically linked into FFmpeg |
| libopus | 1.6.1 | BSD 3-Clause | Statically linked into FFmpeg |
| libvpx | 1.17.0 | BSD 3-Clause | Statically linked into FFmpeg |
| libwebp | 1.6.0 | BSD 3-Clause | Bundled |
| libsharpyuv | 0.1.2 | BSD 3-Clause | Bundled |
| LibreOffice | 26.8.0.3 | MPL 2.0 + third-party components | Bundled |
| ImageIO / PDFKit | macOS 15.0+ | Apple Proprietary System Frameworks | Native System Frameworks |

