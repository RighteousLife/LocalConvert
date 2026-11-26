#!/usr/bin/env bash
# ==============================================================================
# LocalConvert — Setup Bundled Runtimes
# Deterministic dependency setup and verification for source checkouts.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RESOURCES_DIR="${LOCALCONVERT_RESOURCES_DIR:-${REPO_ROOT}/LocalConvert/Resources}"
LIBREOFFICE_DIR="${RESOURCES_DIR}/LibreOffice"
FFMPEG_DIR="${RESOURCES_DIR}/ffmpeg"

# Pinned configuration env vars (must be supplied by the caller; never hardcoded to unverified defaults):
#   export LIBREOFFICE_RELEASE_URL="https://github.com/<owner>/LocalConvert/releases/download/<tag>/LibreOffice-runtime-arm64.tar.gz"
#   export LIBREOFFICE_SHA256="<64-hex-sha256>"
#   export FFMPEG_RELEASE_URL="https://github.com/<owner>/LocalConvert/releases/download/<tag>/ffmpeg-arm64-static.tar.gz"
#   export FFMPEG_SHA256="<64-hex-sha256>"
LIBREOFFICE_RELEASE_URL="${LIBREOFFICE_RELEASE_URL:-}"
LIBREOFFICE_SHA256="${LIBREOFFICE_SHA256:-}"
FFMPEG_RELEASE_URL="${FFMPEG_RELEASE_URL:-}"
FFMPEG_SHA256="${FFMPEG_SHA256:-}"

CLEANUP_DIRS=()
cleanup() {
    for d in "${CLEANUP_DIRS[@]:-}"; do
        rm -rf "${d}" 2>/dev/null || true
    done
}
trap cleanup EXIT INT TERM

MISSING_RUNTIMES=0

validate_pinned_download() {
    local label="$1"
    local url_var="$2"
    local sha_var="$3"
    local url_val="$4"
    local sha_val="$5"

    if [[ -z "${url_val}" ]]; then
        echo "❌ Missing required ${label} download configuration: ${url_var} is unset." >&2
        if [[ -z "${sha_val}" ]]; then
            echo "   Also unset: ${sha_var} (must be a 64-character SHA-256 hex digest matching the pinned archive)." >&2
        else
            echo "   Note: ${sha_var} is set, but ${url_var} is missing." >&2
        fi
        return 1
    fi

    if [[ ! "${url_val}" =~ ^https:// ]] || [[ "${url_val}" == *"<"* || "${url_val}" == *">"* ]]; then
        echo "❌ Invalid ${url_var}: '${url_val}'. Must be a concrete https:// URL without placeholders." >&2
        return 1
    fi

    if [[ -z "${sha_val}" ]]; then
        echo "❌ Error: ${url_var} is set, but ${sha_var} is unset. Refusing to download unverified archive." >&2
        return 1
    fi

    if [[ ! "${sha_val}" =~ ^[0-9a-fA-F]{64}$ ]]; then
        echo "❌ Invalid ${sha_var}: expected a 64-character hexadecimal SHA-256 digest." >&2
        return 1
    fi

    return 0
}

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
    echo "ℹ️  LibreOffice runtime not found in ${LIBREOFFICE_DIR}."
    if ! validate_pinned_download "LibreOffice" "LIBREOFFICE_RELEASE_URL" "LIBREOFFICE_SHA256" "${LIBREOFFICE_RELEASE_URL}" "${LIBREOFFICE_SHA256}"; then
        echo "   Set LIBREOFFICE_RELEASE_URL and LIBREOFFICE_SHA256 (or place LibreOffice.app into ${LIBREOFFICE_DIR})." >&2
        MISSING_RUNTIMES=1
    else
        TEMP_LO_DIR="$(mktemp -d "${TMPDIR:-/tmp}/localconvert-lo.XXXXXX")"
        CLEANUP_DIRS+=("${TEMP_LO_DIR}")

        ARCHIVE_PATH="${TEMP_LO_DIR}/LibreOffice-runtime.tar.gz"
        echo "⬇️  Downloading LibreOffice from: ${LIBREOFFICE_RELEASE_URL}..."
        curl -fSL --proto "=https" --tlsv1.2 "${LIBREOFFICE_RELEASE_URL}" -o "${ARCHIVE_PATH}"

        echo "🔒 Verifying SHA-256 checksum..."
        CALCULATED_HASH="$(shasum -a 256 "${ARCHIVE_PATH}" | awk '{print $1}' | tr '[:upper:]' '[:lower:]')"
        EXPECTED_HASH="$(printf '%s' "${LIBREOFFICE_SHA256}" | tr '[:upper:]' '[:lower:]')"
        if [[ "${CALCULATED_HASH}" != "${EXPECTED_HASH}" ]]; then
            echo "❌ Checksum verification failed for LibreOffice!" >&2
            echo "   Expected: ${EXPECTED_HASH}" >&2
            echo "   Got:      ${CALCULATED_HASH}" >&2
            exit 1
        fi
        echo "✅ Checksum verified."

        echo "📂 Extracting LibreOffice runtime..."
        mkdir -p "${RESOURCES_DIR}"
        tar -xzf "${ARCHIVE_PATH}" -C "${RESOURCES_DIR}"

        if [[ ! -x "${LIBREOFFICE_DIR}/Contents/MacOS/soffice" ]]; then
            echo "❌ Post-extraction error: Expected soffice executable not found at ${LIBREOFFICE_DIR}/Contents/MacOS/soffice" >&2
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
    echo "ℹ️  FFmpeg or ffprobe binaries not found in ${FFMPEG_DIR}."
    if ! validate_pinned_download "FFmpeg" "FFMPEG_RELEASE_URL" "FFMPEG_SHA256" "${FFMPEG_RELEASE_URL}" "${FFMPEG_SHA256}"; then
        echo "   Set FFMPEG_RELEASE_URL and FFMPEG_SHA256 (or place ffmpeg & ffprobe binaries into ${FFMPEG_DIR})." >&2
        MISSING_RUNTIMES=1
    else
        TEMP_FF_DIR="$(mktemp -d "${TMPDIR:-/tmp}/localconvert-ffmpeg.XXXXXX")"
        CLEANUP_DIRS+=("${TEMP_FF_DIR}")

        ARCHIVE_PATH="${TEMP_FF_DIR}/ffmpeg-runtime.tar.gz"
        echo "⬇️  Downloading FFmpeg from: ${FFMPEG_RELEASE_URL}..."
        curl -fSL --proto "=https" --tlsv1.2 "${FFMPEG_RELEASE_URL}" -o "${ARCHIVE_PATH}"

        echo "🔒 Verifying SHA-256 checksum..."
        CALCULATED_HASH="$(shasum -a 256 "${ARCHIVE_PATH}" | awk '{print $1}' | tr '[:upper:]' '[:lower:]')"
        EXPECTED_HASH="$(printf '%s' "${FFMPEG_SHA256}" | tr '[:upper:]' '[:lower:]')"
        if [[ "${CALCULATED_HASH}" != "${EXPECTED_HASH}" ]]; then
            echo "❌ Checksum verification failed for FFmpeg!" >&2
            echo "   Expected: ${EXPECTED_HASH}" >&2
            echo "   Got:      ${CALCULATED_HASH}" >&2
            exit 1
        fi
        echo "✅ Checksum verified."

        mkdir -p "${FFMPEG_DIR}"
        tar -xzf "${ARCHIVE_PATH}" -C "${FFMPEG_DIR}"
        if [[ ! -x "${FFMPEG_DIR}/ffmpeg" || ! -x "${FFMPEG_DIR}/ffprobe" ]]; then
            echo "❌ Post-extraction error: Expected ffmpeg and ffprobe executables not found in ${FFMPEG_DIR}" >&2
            exit 1
        fi
        echo "✅ FFmpeg extraction complete."
    fi
fi

if [[ "${MISSING_RUNTIMES}" -ne 0 ]]; then
    echo "" >&2
    echo "❌ Runtime setup incomplete: provide valid pinned *_RELEASE_URL and *_SHA256 environment variables." >&2
    exit 1
fi

echo ""
echo "🎉 Runtime setup check complete. Run './scripts/verify-dependencies.sh' to audit."
