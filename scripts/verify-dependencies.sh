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
    check_arm64 "${SHARPYUV_DYLIB}"
    check_no_homebrew "${SHARPYUV_DYLIB}"
else
    echo "❌ Bundled libwebp frameworks missing in LocalConvert/Frameworks/"
    FAILURES=$((FAILURES + 1))
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
    check_arm64 "${FFPROBE_BIN}"
    check_no_homebrew "${FFPROBE_BIN}"
    
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
    
    SOFFICE_VER=$("${SOFFICE_BIN}" --version 2>&1 | head -n 1 || true)
    echo "   ↳ Version: ${SOFFICE_VER}"
else
    echo "⚠️  Bundled LibreOffice missing in LocalConvert/Resources/LibreOffice/ (Distributed via GitHub Releases)"
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
