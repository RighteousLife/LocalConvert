# LocalConvert — Phase 55.1 Binary Rebuild Report

**Phase:** Phase 55.1 — Native Binary Rebuild & macOS 15 Portability Closure  
**Workspace:** `/Users/cancan/Desktop/LocalConvert/` (`RighteousLife/LocalConvert`)  
**Target:** Apple Silicon (`arm64`), minimum deployment target `macOS 15.0` (`LC_BUILD_VERSION minos 15.0`)

---

## 1. Initial Environment Inventory (Pre-Rebuild Audit)

Captured prior to modifying any binary or staging directory (`git status --short` baseline: `239` entries):

- **Host OS:** macOS `27.2.1` (`26B131`, Apple Silicon `arm64`)
- **Xcode / SDKs:** Xcode `27.2` (`27B52`), `macosx27.2`, XcodeGen `2.48.0`
- **Available Host Build Toolchain:**
  - `/usr/bin/clang` (`Apple clang version 21.0.0 (clang-2100.4.1.1)`)
  - `/usr/bin/make` (`GNU Make 3.81`), `/opt/homebrew/bin/cmake` (`4.5.1`), `/opt/homebrew/bin/ninja` (`1.13.2`), `/opt/homebrew/bin/pkg-config` (`3.0.11`), `/usr/bin/libtool`
  - Missing (not needed for `arm64` NEON builds from release tarballs): `nasm`, `yasm`, `meson`, `autoconf`, `automake`
- **Existing Static Codec Archives Under `/opt/homebrew/lib/` (Unusable for macOS 15):**
  - `libmp3lame.a`, `libmpg123.a`, `libopus.a`, `libvpx.a`, `libwebp.a`, `libsharpyuv.a` all reported `LC_BUILD_VERSION minos 27.0` and were excluded completely from staging via isolated `PKG_CONFIG_LIBDIR` and `PKG_CONFIG_PATH=""`.
- **Pre-Rebuild Bundled Binary Blocker Baseline (`LC_BUILD_VERSION minos 27.0`):**
  1. [`LocalConvert/Frameworks/libwebp.dylib`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Frameworks/libwebp.dylib) (`arm64`, `@rpath/libwebp.dylib`, compat `10.0.0`, `minos 27.0`)
  2. [`LocalConvert/Frameworks/libsharpyuv.dylib`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Frameworks/libsharpyuv.dylib) (`arm64`, `@rpath/libsharpyuv.dylib`, compat `2.0.0` / current `2.2.0`, `minos 27.0`)
  3. [`LocalConvert/Resources/ffmpeg/ffmpeg`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Resources/ffmpeg/ffmpeg) (`9.0.2`, `arm64`, LGPLv3+, `minos 27.0`)
  4. [`LocalConvert/Resources/ffmpeg/ffprobe`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Resources/ffmpeg/ffprobe) (`9.0.2`, `arm64`, LGPLv3+, `minos 27.0`)

---

## 2. Upstream Source Versions, Provenance & SHA-256 Verification

With user approval, six official upstream release tarballs were downloaded over HTTPS into temporary staging (`/tmp/localconvert-phase55-1-src/`) and verified against upstream/Homebrew-recorded release SHA-256 digests (`shasum -a 256`) prior to extraction:

| Component | Version | License | Upstream Archive URL | Verified SHA-256 |
| :--- | :--- | :--- | :--- | :--- |
| `libwebp` (+ `libsharpyuv`) | `1.6.0` | BSD-3-Clause | `https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0.tar.gz` | `e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564` |
| `mpg123` | `1.33.7` | LGPL-2.1-only | `https://www.mpg123.de/download/mpg123-1.33.7.tar.bz2` | `31d0e35a4ca567ec9b5ebda6c3062bb4435d6d3eacd6ef0d95cadd7854dc03ee` |
| `lame` | `4.0` | LGPL-2.0-or-later | `https://downloads.sourceforge.net/project/lame/lame/4.0/lame-4.0.tar.gz` | `3df5124d5ad3a98312ffd7ba6a9b36230e4f8a3e66d3ce0f425e336c32d216eb` |
| `opus` | `1.6.1` | BSD-3-Clause | `https://ftp.osuosl.org/pub/xiph/releases/opus/opus-1.6.1.tar.gz` | `6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1` |
| `libvpx` | `1.17.0` | BSD-3-Clause | `https://github.com/webmproject/libvpx/archive/refs/tags/v1.17.0.tar.gz` | `1020f184046187baa2985dbde38e0691f49c44088bca7a1842b0236c6081dc0a` |
| `ffmpeg` | `9.0.2` | LGPLv3+ (when built with `--enable-version3` without `--enable-gpl`) | `https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz` | `8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e` |

*(Note: Detached PGP `.asc` signatures were not separately fetched; integrity rested on HTTPS transport plus exact SHA-256 verification.)*

---

## 3. Staged Build Configuration & Commands (`/tmp/localconvert-phase55-1-stage/`)

All compilation occurred strictly in temporary staging outside the repository and `/opt/homebrew`.

### 3.1 `libwebp.dylib` & `libsharpyuv.dylib` (`1.6.0`, ABI `0x0210`)
- Configured with `MACOSX_DEPLOYMENT_TARGET=15.0`, CMake + Ninja:
  ```bash
  cmake -S libwebp-1.6.0 -B webp-cmake-build -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DCMAKE_OSX_SYSROOT="$(xcrun --sdk macosx --show-sdk-path)" \
    -DBUILD_SHARED_LIBS=ON \
    -DCMAKE_MACOSX_RPATH=ON \
    -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF \
    -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF \
    -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_LIBWEBPMUX=OFF -DWEBP_BUILD_WEBPMUX=OFF \
    -DWEBP_BUILD_EXTRAS=OFF \
    -DCMAKE_INSTALL_PREFIX=/tmp/localconvert-phase55-1-stage/webp-prefix
  ```
- Normalized dynamic install names via `install_name_tool` (without touching `LC_BUILD_VERSION`):
  - `libsharpyuv.dylib`: `-id @rpath/libsharpyuv.dylib` (compat `2.0.0`, current `2.2.0`)
  - `libwebp.dylib`: `-id @rpath/libwebp.dylib` (compat `10.0.0`, current `10.0.0`) and `-change @rpath/libsharpyuv.0.dylib @rpath/libsharpyuv.dylib`
  - Ad-hoc signed via `codesign --force --sign - --timestamp=none`

### 3.2 Static Codec Dependencies (`$PREFIX=/tmp/localconvert-phase55-1-stage/prefix`)
Environment exported across all four static builds:
- `MACOSX_DEPLOYMENT_TARGET=15.0`, `CC=/usr/bin/clang`, `CXX=/usr/bin/clang++`
- `CFLAGS="-arch arm64 -mmacosx-version-min=15.0 -O2"`, `LDFLAGS="-arch arm64 -mmacosx-version-min=15.0"`
- `PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"`, `PKG_CONFIG_PATH=""`

Build order & flags (built `mpg123` prior to `lame` because `lame 4.0` requires `libmpg123 >= 1.26.0`, explaining `--extra-libs="-lmpg123"` in [`FFmpeg-BUILDCONF.txt`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Resources/ffmpeg/FFmpeg-BUILDCONF.txt)):
1. **`mpg123-1.33.7`:** `./configure --prefix="$PREFIX" --enable-static --disable-shared --with-default-audio=coreaudio`
2. **`lame-4.0`:** `./configure --prefix="$PREFIX" --enable-static --disable-shared --disable-frontend --disable-gtktest`
3. **`opus-1.6.1`:** `./configure --prefix="$PREFIX" --enable-static --disable-shared --disable-doc --disable-extra-programs`
4. **`libvpx-1.17.0`:** `./configure --prefix="$PREFIX" --target=arm64-darwin24-gcc --enable-static --disable-shared --disable-examples --disable-tools --disable-docs --disable-unit-tests --enable-vp8 --enable-vp9 --enable-vp9-highbitdepth --enable-pic --extra-cflags="-arch arm64 -mmacosx-version-min=15.0"`

Verified across **all** object members of `libmpg123.a`, `libmp3lame.a`, `libopus.a`, and `libvpx.a`: `lipo -info` = `arm64`, unique `minos` = **`15.0`**.

### 3.3 `ffmpeg` & `ffprobe` (`9.0.2`, LGPLv3+)
Configured inside isolated `PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"` and `PKG_CONFIG_PATH=""`:
```bash
./configure \
  --prefix=/tmp/localconvert-phase55-1-stage/ffmpeg-out \
  --enable-static \
  --disable-shared \
  --pkg-config-flags="--static" \
  --enable-pthreads \
  --enable-version3 \
  --cc=/usr/bin/clang \
  --extra-cflags="-arch arm64 -mmacosx-version-min=15.0 -I$PREFIX/include" \
  --extra-ldflags="-arch arm64 -mmacosx-version-min=15.0 -L$PREFIX/lib" \
  --extra-libs="-lmpg123" \
  --enable-videotoolbox \
  --enable-audiotoolbox \
  --enable-neon \
  --enable-libmp3lame \
  --enable-libopus \
  --enable-libvpx \
  --disable-ffplay \
  --disable-doc \
  --disable-debug \
  --disable-xlib \
  --disable-sdl2 \
  --disable-lzma
```
Confirmed `--enable-gpl` and `--enable-nonfree` are **absent**.

---

## 4. Before / After Binary & Capability Comparison

### 4.1 Replaced Paths & Mach-O `minos` Transition

| Workspace Path | Size | Before (`minos` / `sdk`) | After (`minos` / `sdk`) | Architecture & Install Name / Linkage |
| :--- | :--- | :--- | :--- | :--- |
| [`LocalConvert/Frameworks/libwebp.dylib`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Frameworks/libwebp.dylib) | `499K` | `27.0` / `27.0` | **`15.0` / `27.2`** | `arm64`; `@rpath/libwebp.dylib` (compat `10.0.0`); loads `@rpath/libsharpyuv.dylib` + `libSystem.B.dylib` |
| [`LocalConvert/Frameworks/libsharpyuv.dylib`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Frameworks/libsharpyuv.dylib) | `66K` | `27.0` / `27.0` | **`15.0` / `27.2`** | `arm64`; `@rpath/libsharpyuv.dylib` (compat `2.0.0`, current `2.2.0`); loads `libSystem.B.dylib` only |
| [`LocalConvert/Resources/ffmpeg/ffmpeg`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Resources/ffmpeg/ffmpeg) | `25M` | `27.0` / `27.0` | **`15.0` / `27.2`** | `arm64`; macOS system frameworks + `/usr/lib/lib{z,bz2,iconv,objc.A,System.B}.dylib`; zero Homebrew linkage |
| [`LocalConvert/Resources/ffmpeg/ffprobe`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Resources/ffmpeg/ffprobe) | `24M` | `27.0` / `27.0` | **`15.0` / `27.2`** | `arm64`; macOS system frameworks + `/usr/lib/lib{z,bz2,iconv,objc.A,System.B}.dylib`; zero Homebrew linkage |
| [`LocalConvert/Resources/ffmpeg/FFmpeg-BUILDCONF.txt`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Resources/ffmpeg/FFmpeg-BUILDCONF.txt) | Documentation | Prior `minos 27` flags | Updated macOS `15.0` configure flags & static dependency metadata | Preserves LGPLv3+ documentation |

### 4.2 FFmpeg Capability Comparison (Baseline vs. Rebuilt)
`diff -u` comparing the pre-rebuild baseline against the rebuilt binary produced **zero diff** across all three capability outputs:
- **Encoders:** `196` lines — **0 additions, 0 removals** (`h264_videotoolbox`, `hevc_videotoolbox`, `prores_videotoolbox`, `libvpx`, `libvpx-vp9`, `libmp3lame`, `libopus`, `aac_at`, etc. all preserved)
- **Decoders:** `527` lines — **0 additions, 0 removals**
- **Formats:** `418` lines — **0 additions, 0 removals**
- **Library versions:** identical (`libavutil 61.1.102`, `libavcodec 63.1.102`, `libavformat 63.1.102`, `libavdevice 63.1.102`, `libavfilter 12.1.102`, `libswscale 10.1.102`, `libswresample 7.1.102`).
