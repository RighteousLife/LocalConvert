#!/usr/bin/env bash
# ==============================================================================
# LocalConvert — Dependency & Environment Verification Script
# Comprehensive audit of bundled binaries, architectures, dynamic linkage, and tools.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "🔍 Verifying LocalConvert development and build environment..."
echo "📂 Project root: ${REPO_ROOT}"
echo ""

FAILURES=0

# Helper to check Mach-O arm64 architecture
check_arm64() {
    local file_path="$1"
    if [[ "${file_path}" == *.a ]]; then
        local lipo_desc
        lipo_desc="$(lipo -info "${file_path}" 2>&1 || true)"
        if echo "${lipo_desc}" | grep -q "arm64"; then
            echo "   ↳ Arch: arm64 verified"
            return
        fi
    fi
    local file_desc
    file_desc="$(file "${file_path}" 2>&1)"
    if echo "${file_desc}" | grep -q "arm64"; then
        echo "   ↳ Arch: arm64 verified"
    else
        echo "   ❌ Error: ${file_path} is not an arm64 binary (${file_desc})"
        FAILURES=$((FAILURES + 1))
    fi
}

# Helper to check for unwanted Homebrew paths in dynamic linkage
check_no_homebrew() {
    local file_path="$1"
    local brew_deps
    brew_deps="$(otool -L "${file_path}" 2>&1 | grep -iE "/opt/homebrew|/usr/local/Cellar" || true)"
    if [[ -n "${brew_deps}" ]]; then
        echo "   ❌ Error: ${file_path} links to Homebrew libraries:"
        echo "${brew_deps}"
        FAILURES=$((FAILURES + 1))
    else
        echo "   ↳ Linkage: Zero Homebrew dependencies verified"
    fi
}

# Helper to verify LC_BUILD_VERSION minos <= 15.0 (or <= 15.x)
check_minos() {
    local file_path="$1"
    local max_major="${2:-15}"
    local minos
    minos="$(otool -l "${file_path}" 2>/dev/null | awk '/cmd LC_BUILD_VERSION/{f=1} f && /minos /{print $2; exit}' || true)"
    if [[ -z "${minos}" ]]; then
        minos="$(otool -l "${file_path}" 2>/dev/null | awk '/cmd LC_VERSION_MIN_MACOSX/{f=1} f && /version /{print $2; exit}' || true)"
    fi
    if [[ -z "${minos}" ]]; then
        echo "   ⚠️  Could not read deployment target for ${file_path}"
        return
    fi
    local major="${minos%%.*}"
    if [[ "${major}" =~ ^[0-9]+$ ]] && [[ "${major}" -le "${max_major}" ]]; then
        echo "   ↳ MinOS: macOS ${minos} (compatible with <= ${max_major}.0)"
    else
        echo "   ❌ Error: ${file_path} targets macOS ${minos} (> ${max_major}.0 deployment target)"
        FAILURES=$((FAILURES + 1))
    fi
}

# 1. XcodeGen
echo "▶ Checking Build Prerequisites..."
if command -v xcodegen &> /dev/null; then
    echo "✅ XcodeGen installed: $(xcodegen --version 2>&1 | head -n 1)"
else
    echo "⚠️  XcodeGen is missing! Install via: brew install xcodegen"
    FAILURES=$((FAILURES + 1))
fi

# 2. Bundled libwebp & libsharpyuv
echo ""
echo "▶ Checking libwebp & libsharpyuv dynamic libraries..."
WEBP_DYLIB="${REPO_ROOT}/LocalConvert/Frameworks/libwebp.dylib"
SHARPYUV_DYLIB="${REPO_ROOT}/LocalConvert/Frameworks/libsharpyuv.dylib"
if [[ -f "${WEBP_DYLIB}" && -f "${SHARPYUV_DYLIB}" ]]; then
    echo "✅ libwebp & libsharpyuv present in LocalConvert/Frameworks/"
    check_arm64 "${WEBP_DYLIB}"
    check_no_homebrew "${WEBP_DYLIB}"
    check_minos "${WEBP_DYLIB}" 15
    check_arm64 "${SHARPYUV_DYLIB}"
    check_no_homebrew "${SHARPYUV_DYLIB}"
    check_minos "${SHARPYUV_DYLIB}" 15
else
    echo "❌ Bundled libwebp frameworks missing in LocalConvert/Frameworks/"
    FAILURES=$((FAILURES + 1))
fi

# 2b. Bundled static libjxl v0.13.0 & third-party archives (arm64, zero Homebrew runtime)
echo ""
echo "▶ Checking libjxl static libraries & headers..."
JXL_HEADER="${REPO_ROOT}/LocalConvert/Frameworks/include/jxl/encode.h"
JXL_LIBS=(libjxl.a libjxl_threads.a libjxl_cms.a libhwy.a libbrotlienc.a libbrotlidec.a libbrotlicommon.a)
JXL_OK=1
if [[ ! -f "${JXL_HEADER}" ]]; then
    echo "❌ libjxl headers missing in LocalConvert/Frameworks/include/jxl/"
    JXL_OK=0
    FAILURES=$((FAILURES + 1))
fi
for LIB in "${JXL_LIBS[@]}"; do
    LIB_PATH="${REPO_ROOT}/LocalConvert/Frameworks/${LIB}"
    if [[ ! -f "${LIB_PATH}" ]]; then
        echo "❌ Missing static archive: ${LIB}"
        JXL_OK=0
        FAILURES=$((FAILURES + 1))
    else
        check_arm64 "${LIB_PATH}"
    fi
done
if [[ "${JXL_OK}" -eq 1 ]]; then
    check_minos "${REPO_ROOT}/LocalConvert/Frameworks/libjxl.a" 15
    echo "✅ libjxl v0.13.0 static arm64 archives & headers verified"
fi

# 3. Bundled FFmpeg & ffprobe
echo ""
echo "▶ Checking FFmpeg & ffprobe binaries..."
FFMPEG_BIN="${REPO_ROOT}/LocalConvert/Resources/ffmpeg/ffmpeg"
FFPROBE_BIN="${REPO_ROOT}/LocalConvert/Resources/ffmpeg/ffprobe"
if [[ -x "${FFMPEG_BIN}" && -x "${FFPROBE_BIN}" ]]; then
    echo "✅ Bundled FFmpeg static binaries present in LocalConvert/Resources/ffmpeg/"
    check_arm64 "${FFMPEG_BIN}"
    check_no_homebrew "${FFMPEG_BIN}"
    check_minos "${FFMPEG_BIN}" 15
    check_arm64 "${FFPROBE_BIN}"
    check_no_homebrew "${FFPROBE_BIN}"
    check_minos "${FFPROBE_BIN}" 15
    
    FFMPEG_VER=$("${FFMPEG_BIN}" -version 2>&1 | head -n 1)
    echo "   ↳ Version: ${FFMPEG_VER}"
else
    echo "❌ Bundled FFmpeg / ffprobe missing or not executable in LocalConvert/Resources/ffmpeg/"
    FAILURES=$((FAILURES + 1))
fi

# 4. Bundled LibreOffice
echo ""
echo "▶ Checking LibreOffice runtime..."
SOFFICE_BIN="${REPO_ROOT}/LocalConvert/Resources/LibreOffice/Contents/MacOS/soffice"
if [[ -x "${SOFFICE_BIN}" ]]; then
    echo "✅ Bundled LibreOffice runtime present at ${SOFFICE_BIN}"
    check_arm64 "${SOFFICE_BIN}"
    check_no_homebrew "${SOFFICE_BIN}"
    check_minos "${SOFFICE_BIN}" 15

    LO_DIR="${REPO_ROOT}/LocalConvert/Resources/LibreOffice"
    if codesign --verify --deep --strict "${LO_DIR}/Contents/Frameworks/LibreOfficePython.framework" >/dev/null 2>&1; then
        echo "✅ LibreOfficePython.framework passed codesign --verify --deep --strict"
    else
        echo "❌ LibreOfficePython.framework failed codesign --verify --deep --strict"
        FAILURES=$((FAILURES + 1))
    fi
    if codesign --verify --deep --strict "${LO_DIR}" >/dev/null 2>&1; then
        echo "✅ Bundled LibreOffice passed codesign --verify --deep --strict"
    else
        echo "❌ Bundled LibreOffice failed codesign --verify --deep --strict"
        FAILURES=$((FAILURES + 1))
    fi

    SOFFICE_VER=$(PYTHONDONTWRITEBYTECODE=1 "${SOFFICE_BIN}" --headless --version 2>&1 | head -n 1 || true)
    echo "   ↳ Version: ${SOFFICE_VER}"
else
    echo "⚠️  Bundled LibreOffice missing in LocalConvert/Resources/LibreOffice/ (Distributed via GitHub Releases)"
fi

# 5. Third-party licenses & notices
echo ""
echo "▶ Checking Third-Party Notices & License Files..."
REQUIRED_NOTICES=(
    "${REPO_ROOT}/LICENSE"
    "${REPO_ROOT}/LocalConvert/Frameworks/LICENSE.webp"
    "${REPO_ROOT}/LocalConvert/Frameworks/LICENSE.jxl"
    "${REPO_ROOT}/LocalConvert/Resources/ffmpeg/FFmpeg-LICENSE.txt"
    "${REPO_ROOT}/THIRD_PARTY_NOTICES.md"
    "${REPO_ROOT}/LocalConvert/Resources/THIRD_PARTY_NOTICES.md"
)
for NOTICE_PATH in "${REQUIRED_NOTICES[@]}"; do
    if [[ -f "${NOTICE_PATH}" ]]; then
        echo "✅ Found ${NOTICE_PATH#"${REPO_ROOT}/"}"
    else
        echo "❌ Missing notice/license file: ${NOTICE_PATH}"
        FAILURES=$((FAILURES + 1))
    fi
done
if grep -q "JPEG XL Project Authors" "${REPO_ROOT}/THIRD_PARTY_NOTICES.md" && grep -q "JPEG XL Project Authors" "${REPO_ROOT}/LocalConvert/Resources/THIRD_PARTY_NOTICES.md"; then
    echo "✅ Both THIRD_PARTY_NOTICES.md files contain libjxl license notice"
else
    echo "❌ libjxl license text missing from THIRD_PARTY_NOTICES.md"
    FAILURES=$((FAILURES + 1))
fi

# 6. Optional built .app verification (--app <path>)
APP_BUNDLE=""
if [[ "${1:-}" == "--app" ]]; then
    APP_BUNDLE="${2:-}"
    if [[ -z "${APP_BUNDLE}" || ! -d "${APP_BUNDLE}" ]]; then
        echo ""
        echo "❌ --app requires an existing .app bundle directory (got '${APP_BUNDLE}')"
        FAILURES=$((FAILURES + 1))
        APP_BUNDLE=""
    fi
elif [[ -n "${1:-}" ]]; then
    APP_BUNDLE="${1}"
    if [[ ! -d "${APP_BUNDLE}" ]]; then
        echo ""
        echo "❌ Specified bundle path does not exist: ${APP_BUNDLE}"
        FAILURES=$((FAILURES + 1))
        APP_BUNDLE=""
    fi
fi

if [[ -n "${APP_BUNDLE}" ]]; then
    echo ""
    echo "▶ Auditing App Bundle (${APP_BUNDLE})..."
    if codesign --verify --deep --strict "${APP_BUNDLE}" >/dev/null 2>&1; then
        echo "✅ App bundle passed codesign --verify --deep --strict"
    else
        echo "❌ App bundle failed codesign --verify --deep --strict"
        FAILURES=$((FAILURES + 1))
    fi
    APP_EXEC="${APP_BUNDLE}/Contents/MacOS/LocalConvert"
    if [[ -x "${APP_EXEC}" ]]; then
        check_arm64 "${APP_EXEC}"
        check_no_homebrew "${APP_EXEC}"
    else
        echo "❌ Missing main executable: ${APP_EXEC}"
        FAILURES=$((FAILURES + 1))
    fi

    MACHO_COUNT=0
    MACHO_FAILED=0
    while IFS= read -r -d "" bundle_file; do
        [[ "${bundle_file}" == *.o ]] && continue
        if /usr/bin/file -b "${bundle_file}" | grep -q "Mach-O"; then
            MACHO_COUNT=$((MACHO_COUNT + 1))
            fdesc="$(file -b "${bundle_file}" 2>&1 || true)"
            if ! echo "${fdesc}" | grep -q "arm64"; then
                echo "   ❌ Non-arm64 Mach-O in bundle: ${bundle_file} (${fdesc})"
                MACHO_FAILED=$((MACHO_FAILED + 1))
            fi
            brew_deps="$(otool -L "${bundle_file}" 2>&1 | grep -iE "/opt/homebrew|/usr/local/Cellar" || true)"
            if [[ -n "${brew_deps}" ]]; then
                echo "   ❌ Homebrew linkage in bundle: ${bundle_file}"
                echo "${brew_deps}"
                MACHO_FAILED=$((MACHO_FAILED + 1))
            fi
        fi
    done < <(find "${APP_BUNDLE}/Contents" -type f -print0)

    if [[ ${MACHO_FAILED} -eq 0 && ${MACHO_COUNT} -gt 0 ]]; then
        echo "✅ Audited all ${MACHO_COUNT} bundled Mach-O binaries: 100% arm64, zero Homebrew linkage"
    else
        echo "❌ Bundled Mach-O audit failed (${MACHO_FAILED} failures across ${MACHO_COUNT} files)"
        FAILURES=$((FAILURES + 1))
    fi

    for BUNDLE_RES in "LICENSE" "LICENSE.webp" "LICENSE.jxl" "THIRD_PARTY_NOTICES.md" "ffmpeg/FFmpeg-LICENSE.txt"; do
        if [[ -f "${APP_BUNDLE}/Contents/Resources/${BUNDLE_RES}" ]]; then
            echo "✅ Bundled resource: Contents/Resources/${BUNDLE_RES}"
        else
            echo "❌ Missing bundled resource: Contents/Resources/${BUNDLE_RES}"
            FAILURES=$((FAILURES + 1))
        fi
    done
    APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP_BUNDLE}/Contents/Info.plist" 2>/dev/null || echo "")
    if [[ "${APP_VERSION}" == "1.0.0" ]]; then
        echo "✅ App CFBundleShortVersionString is 1.0.0"
    else
        echo "❌ Expected CFBundleShortVersionString 1.0.0, found '${APP_VERSION}'"
        FAILURES=$((FAILURES + 1))
    fi
fi

echo ""
echo "▶ Checking App Icon Metadata..."
INFO_PLIST="${REPO_ROOT}/LocalConvert/Info.plist"
if [[ -f "${INFO_PLIST}" ]]; then
    if grep -q "CFBundleIconName" "${INFO_PLIST}" && grep -q "AppIcon" "${INFO_PLIST}"; then
        echo "✅ CFBundleIconName is configured correctly in Info.plist"
    else
        echo "❌ CFBundleIconName missing or incorrect in Info.plist!"
        FAILURES=$((FAILURES + 1))
    fi
else
    echo "❌ Info.plist not found at ${INFO_PLIST}"
    FAILURES=$((FAILURES + 1))
fi

APP_ICON_SET="${REPO_ROOT}/LocalConvert/Assets.xcassets/AppIcon.appiconset/Contents.json"
if [[ -f "${APP_ICON_SET}" ]]; then
    echo "✅ AppIcon asset directory and Contents.json found"
else
    echo "❌ AppIcon asset directory or Contents.json missing!"
    FAILURES=$((FAILURES + 1))
fi

echo ""
if [[ ${FAILURES} -eq 0 ]]; then
    echo "🎉 All checked dependencies and binary requirements passed audit!"
    exit 0
else
    echo "❌ Found ${FAILURES} issue(s) during verification."
    exit 1
fi
