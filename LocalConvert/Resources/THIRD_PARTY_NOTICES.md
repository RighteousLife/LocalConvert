# Third-Party Software Notices & Acknowledgements

LocalConvert incorporates and interacts with third-party software components under various open-source licenses. 

**Important Notice Regarding Licensing Independence**:  
The original application code of LocalConvert is licensed under the [MIT License](LICENSE). The third-party libraries, static tools, and runtimes documented below are **independent works** and are governed solely by their respective licenses (such as LGPL, MPL, and BSD). LocalConvert's MIT License does **not** alter, replace, or supersede the licensing terms of any third-party software.

---

## 1. libwebp & libsharpyuv

- **Component Name**: `libwebp` & `libsharpyuv`
- **Version**: 1.6.0 (`libwebp`), 0.1.2 (`libsharpyuv`)
- **License**: BSD 3-Clause License
- **Role in LocalConvert**: High-performance WebP raster encoding backend (`* → WEBP` conversions) and RGB-to-YUV color conversion helper.
- **Distribution Status**: Bundled dynamic libraries (`LocalConvert/Frameworks/libwebp.dylib` and `libsharpyuv.dylib`, copied into `LocalConvert.app/Contents/Frameworks/`).
- **Relevant Notice / License Location**: [`LocalConvert/Frameworks/LICENSE.webp`](LocalConvert/Frameworks/LICENSE.webp)
- **Upstream Project**: Google LLC (https://chromium.googlesource.com/webm/libwebp)

### License Text:
```text
Copyright (c) 2010, Google Inc. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

  * Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.

  * Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in
    the documentation and/or other materials provided with the
    distribution.

  * Neither the name of Google nor the names of its contributors may
    be used to endorse or promote products derived from this software
    without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

---

## 2. FFmpeg & ffprobe

- **Component Name**: `FFmpeg` / `ffprobe`
- **Version**: 9.0.2 (arm64 static executable)
- **License**: GNU Lesser General Public License version 3 or later (**LGPLv3+**)
- **Role in LocalConvert**: Audio and video decoding, encoding, container repackaging, audio extraction, and media stream probing.
- **Distribution Status**: Bundled standalone static executables (`LocalConvert/Resources/ffmpeg/ffmpeg` and `ffprobe`, copied into `LocalConvert.app/Contents/Resources/ffmpeg/`).
- **Build Configuration & License Boundary**:
  - Configured with: `--enable-version3`, `--enable-videotoolbox`, `--enable-audiotoolbox`, `--enable-neon`, `--enable-libmp3lame`, `--enable-libopus`, `--enable-libvpx`.
  - **GPL Status**: Neither `--enable-gpl` nor any GPL codecs (`libx264`, `libx265`) are enabled.
  - **Nonfree Status**: `--enable-nonfree` is not enabled.
- **Relevant Notice / License Location**:
  - License details: [`LocalConvert/Resources/ffmpeg/FFmpeg-LICENSE.txt`](LocalConvert/Resources/ffmpeg/FFmpeg-LICENSE.txt)
  - Build configuration: [`LocalConvert/Resources/ffmpeg/FFmpeg-BUILDCONF.txt`](LocalConvert/Resources/ffmpeg/FFmpeg-BUILDCONF.txt)
- **Upstream Project**: FFmpeg Project (https://ffmpeg.org)

### Statically Linked External Codec Libraries in FFmpeg:
1. **LAME (`libmp3lame`)**:
   - **Version**: 3.100 / 4.0
   - **License**: GNU Lesser General Public License v2.0 or later (LGPLv2+)
   - **Role**: MP3 audio encoding.
   - **Upstream**: https://lame.sourceforge.io/
2. **mpg123 (`libmpg123`)**:
   - **Version**: 1.33.7
   - **License**: GNU Lesser General Public License v2.1 (LGPLv2.1)
   - **Role**: MPEG 1.0/2.0/2.5 audio decoding.
   - **Upstream**: https://www.mpg123.de/
3. **Opus (`libopus`)**:
   - **Version**: 1.6.1
   - **License**: BSD 3-Clause License
   - **Role**: Opus interactive audio encoding/decoding.
   - **Upstream**: https://opus-codec.org/
4. **libvpx**:
   - **Version**: 1.17.0
   - **License**: BSD 3-Clause License
   - **Role**: VP8 and VP9 video encoding/decoding.
   - **Upstream**: https://chromium.googlesource.com/webm/libvpx/

---

## 3. LibreOffice Runtime

- **Component Name**: `LibreOffice` (Headless Runtime)
- **Version**: 26.8.0.3 (Build: `bce0998afefdbc355585ca324285661a2170ba77`)
- **Primary License**: Mozilla Public License 2.0 (**MPL 2.0**)
- **Role in LocalConvert**: Headless document conversion backend for Microsoft Office formats (`DOCX`, `XLSX`, `PPTX`, `ODT`, `ODS`, `ODP`, etc. → `PDF`) and PDF-to-Office document conversion (`PDF` → `DOCX`, `PDF` → `PPTX`, `PDF` → `XLSX`).
- **Distribution Status**: Bundled in local workspace (`LocalConvert/Resources/LibreOffice/Contents/MacOS/soffice`). Distributed as a dedicated release archive on GitHub Releases due to size (~720 MB, containing `libmergedlo.dylib` at ~137 MB).
- **Licensing Independence**: LibreOffice is an independent software suite published by The Document Foundation under MPL 2.0. Invocation is performed across standard macOS process boundaries (`Foundation.Process`). LocalConvert's MIT license does **not** apply to LibreOffice.
- **Relevant Notice / License Location**:
  - Bundled notice: [`LocalConvert/Resources/LibreOffice/Contents/Resources/readmes/README_en-US`](LocalConvert/Resources/LibreOffice/Contents/Resources/readmes/README_en-US)
  - Poppler Data: GPLv2 notice in `LocalConvert/Resources/LibreOffice/Contents/Resources/xpdfimport/poppler_data/COPYING.gpl2`
  - Python 3.13 Runtime: PSF License in `LocalConvert/Resources/LibreOffice/Contents/Frameworks/LibreOfficePython.framework/Versions/3.13/lib/python3.13/LICENSE.txt`
  - Upstream documentation: https://www.libreoffice.org/about-us/licenses/ and https://git.libreoffice.org/core/tree/master/COPYING

---

## 4. macOS Operating System Frameworks (Apple Inc.)

The following system frameworks are dynamically linked runtime components provided by Apple macOS and are exempt under operating system library exceptions:
- `VideoToolbox.framework` & `AudioToolbox.framework` (Hardware video/audio encoding/decoding)
- `AVFoundation.framework`, `CoreMedia.framework`, `CoreVideo.framework`
- `ImageIO.framework`, `CoreGraphics.framework`, `CoreImage.framework`
- `PDFKit.framework` (PDF document rendering and extraction)
- `Foundation.framework`, `AppKit.framework`
