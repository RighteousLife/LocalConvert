#!/usr/bin/env bash
# ==============================================================================
# LocalConvert — Setup Bundled Runtimes
# Deterministic dependency setup and verification for source checkouts.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RESOURCES_DIR="${REPO_ROOT}/LocalConvert/Resources"
LIBREOFFICE_DIR="${RESOURCES_DIR}/LibreOffice"
FFMPEG_DIR="${RESOURCES_DIR}/ffmpeg"

# Configuration Placeholders (To be configured with release assets or environment variables)
# Example: export LIBREOFFICE_RELEASE_URL="https://github.com/<owner>/LocalConvert/releases/download/<tag>/LibreOffice-runtime-arm64.tar.gz"
# Example: export LIBREOFFICE_SHA256="<sha256_hash>"
LIBREOFFICE_RELEASE_URL="${LIBREOFFICE_RELEASE_URL:-}"
LIBREOFFICE_SHA256="${LIBREOFFICE_SHA256:-}"
FFMPEG_RELEASE_URL="${FFMPEG_RELEASE_URL:-}"
FFMPEG_SHA256="${FFMPEG_SHA256:-}"

echo "📦 LocalConvert Runtime Setup"
echo "=============================="

# 1. Target Environment Check
OS_NAME="$(uname -s)"
ARCH_NAME="$(uname -m)"

if [[ "${OS_NAME}" != "Darwin" || "${ARCH_NAME}" != "arm64" ]]; then
    echo "⚠️  Unsupported platform: ${OS_NAME} ${ARCH_NAME}."
    echo "   LocalConvert bundled runtimes currently target macOS Apple Silicon (arm64)."
fi

# 2. LibreOffice Setup
echo ""
echo "▶ Checking LibreOffice runtime..."
if [[ -x "${LIBREOFFICE_DIR}/Contents/MacOS/soffice" ]]; then
    echo "✅ LibreOffice headless runtime is already installed at:"
    echo "   ${LIBREOFFICE_DIR}"
else
    echo "ℹ️  LibreOffice runtime not found in LocalConvert/Resources/LibreOffice."
    echo "   Due to GitHub's 100MB per-file boundary (libmergedlo.dylib ~137MB), LibreOffice"
    echo "   is excluded from Git history and distributed via GitHub Release assets."
    
    if [[ -z "${LIBREOFFICE_RELEASE_URL}" ]]; then
        echo ""
        echo "   [ACTION REQUIRED FOR FRESH SOURCE CLONES]"
        echo "   To configure LibreOffice for building:"
        echo "   Option A (Automated with Release URL):"
        echo "     export LIBREOFFICE_RELEASE_URL=\"https://github.com/<owner>/LocalConvert/releases/download/<tag>/LibreOffice-runtime-arm64.tar.gz\""
        echo "     export LIBREOFFICE_SHA256=\"<verified_sha256>\""
        echo "     ./scripts/setup-runtime.sh"
        echo ""
        echo "   Option B (Manual Archive Extraction):"
        echo "     Download 'LibreOffice-runtime-arm64.tar.gz' from GitHub Releases and extract to:"
        echo "     tar -xzf LibreOffice-runtime-arm64.tar.gz -C \"${RESOURCES_DIR}\""
    else
        if [[ -z "${LIBREOFFICE_SHA256}" ]]; then
            echo "❌ Error: LIBREOFFICE_RELEASE_URL is specified, but LIBREOFFICE_SHA256 is missing."
            echo "   Refusing to download unverified binary archive. Set LIBREOFFICE_SHA256."
            exit 1
        fi
        
        TEMP_DIR="$(mktemp -d -t localconvert-lo-XXXXXX)"
        trap 'rm -rf "${TEMP_DIR}"' EXIT INT TERM
        
        ARCHIVE_PATH="${TEMP_DIR}/LibreOffice-runtime.tar.gz"
        echo "⬇️  Downloading LibreOffice from: ${LIBREOFFICE_RELEASE_URL}..."
        curl -fSL --proto "=https" "${LIBREOFFICE_RELEASE_URL}" -o "${ARCHIVE_PATH}"
        
        echo "🔒 Verifying SHA-256 checksum..."
        CALCULATED_HASH="$(shasum -a 256 "${ARCHIVE_PATH}" | awk '{print $1}')"
        if [[ "${CALCULATED_HASH}" != "${LIBREOFFICE_SHA256}" ]]; then
            echo "❌ Checksum verification failed!"
            echo "   Expected: ${LIBREOFFICE_SHA256}"
            echo "   Got:      ${CALCULATED_HASH}"
            exit 1
        fi
        echo "✅ Checksum verified."
        
        echo "📂 Extracting LibreOffice runtime..."
        mkdir -p "${RESOURCES_DIR}"
        tar -xzf "${ARCHIVE_PATH}" -C "${RESOURCES_DIR}"
        
        if [[ ! -x "${LIBREOFFICE_DIR}/Contents/MacOS/soffice" ]]; then
            echo "❌ Post-extraction error: Expected soffice executable not found at ${LIBREOFFICE_DIR}/Contents/MacOS/soffice"
            exit 1
        fi
        echo "✅ LibreOffice extraction complete and verified."
    fi
fi

# 3. FFmpeg Setup
echo ""
echo "▶ Checking FFmpeg binaries..."
if [[ -x "${FFMPEG_DIR}/ffmpeg" && -x "${FFMPEG_DIR}/ffprobe" ]]; then
    echo "✅ FFmpeg & ffprobe binaries are present at:"
    echo "   ${FFMPEG_DIR}"
else
    echo "ℹ️  FFmpeg or ffprobe static binaries not found in ${FFMPEG_DIR}."
    if [[ -z "${FFMPEG_RELEASE_URL}" ]]; then
        echo "   [ACTION REQUIRED]"
        echo "   Extract 'ffmpeg-arm64-static.tar.gz' to ${FFMPEG_DIR}."
    else
        if [[ -z "${FFMPEG_SHA256}" ]]; then
            echo "❌ Error: FFMPEG_RELEASE_URL is specified, but FFMPEG_SHA256 is missing."
            exit 1
        fi
        TEMP_DIR="$(mktemp -d -t localconvert-ffmpeg-XXXXXX)"
        trap 'rm -rf "${TEMP_DIR}"' EXIT INT TERM
        
        ARCHIVE_PATH="${TEMP_DIR}/ffmpeg-runtime.tar.gz"
        echo "⬇️  Downloading FFmpeg from: ${FFMPEG_RELEASE_URL}..."
        curl -fSL --proto "=https" "${FFMPEG_RELEASE_URL}" -o "${ARCHIVE_PATH}"
        
        echo "🔒 Verifying SHA-256 checksum..."
        CALCULATED_HASH="$(shasum -a 256 "${ARCHIVE_PATH}" | awk '{print $1}')"
        if [[ "${CALCULATED_HASH}" != "${FFMPEG_SHA256}" ]]; then
            echo "❌ Checksum verification failed!"
            exit 1
        fi
        
        mkdir -p "${FFMPEG_DIR}"
        tar -xzf "${ARCHIVE_PATH}" -C "${FFMPEG_DIR}"
        echo "✅ FFmpeg extraction complete."
    fi
fi

echo ""
echo "🎉 Runtime setup check complete. Run './scripts/verify-dependencies.sh' to audit."
