#!/usr/bin/env bash
set -euo pipefail

# Reproducible build, inside-out code signing, verification, and atomic DMG/ZIP packaging script for LocalConvert.
# Usage:
#   scripts/package-release.sh [--identity "-"] [--notarize-profile <profile>] [--configuration Release]
#                              [--output-dir release] [--derived-data <path>] [--app-path <path>]
#                              [--version 1.0.0] [--allow-dirty] [--dry-run] [--skip-build]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

IDENTITY="-"
NOTARIZE_PROFILE=""
CONFIGURATION="Release"
OUTPUT_DIR="${REPO_ROOT}/release"
DERIVED_DATA=""
APP_PATH_OVERRIDE=""
VERSION=""
SKIP_BUILD=0
ALLOW_DIRTY=0
DRY_RUN=0
SIMULATE_FAILURE_BEFORE_PUBLISH=0

usage() {
    cat <<'EOF'
Usage: scripts/package-release.sh [options]

Options:
  --identity <id>                   Code signing identity (default: "-" for ad-hoc local verification).
  --notarize-profile <name>         Optional notarytool keychain profile name (requires Developer ID identity).
  --configuration <cfg>             Xcode build configuration (default: Release).
  --output-dir <path>               Final release directory root (default: ./release). Never used for DerivedData.
  --derived-data <path>             Separate DerivedData path (default: isolated /tmp workspace DerivedData).
  --app-path <path>                 Prebuilt LocalConvert.app path (requires --skip-build).
  --version <ver>                   Override release version (default: CFBundleShortVersionString in LocalConvert/Info.plist).
  --allow-dirty                     Allow packaging when git working tree has uncommitted changes (refused by default).
  --dry-run                         Validate configuration, git state, and staging plan without building or writing outputs.
  --skip-build                      Skip isolated XcodeGen/xcodebuild and re-sign/package existing DerivedData app bundle.
  --simulate-failure-before-publish Test-only: abort right after artifact staging and before atomic publish.
  -h, --help                        Show this help message.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --identity)
            IDENTITY="${2:-}"
            shift 2
            ;;
        --notarize-profile)
            NOTARIZE_PROFILE="${2:-}"
            shift 2
            ;;
        --configuration)
            CONFIGURATION="${2:-}"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="${2:-}"
            shift 2
            ;;
        --derived-data)
            DERIVED_DATA="${2:-}"
            shift 2
            ;;
        --app-path)
            APP_PATH_OVERRIDE="${2:-}"
            shift 2
            ;;
        --version)
            VERSION="${2:-}"
            shift 2
            ;;
        --allow-dirty)
            ALLOW_DIRTY=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --skip-build)
            SKIP_BUILD=1
            shift
            ;;
        --simulate-failure-before-publish)
            SIMULATE_FAILURE_BEFORE_PUBLISH=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "❌ Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ -z "${IDENTITY}" ]]; then
    IDENTITY="-"
fi

if [[ -n "${APP_PATH_OVERRIDE}" && "${SKIP_BUILD}" -eq 0 ]]; then
    echo "❌ --app-path can only be used together with --skip-build." >&2
    exit 2
fi

if [[ -n "${NOTARIZE_PROFILE}" && "${IDENTITY}" == "-" ]]; then
    echo "❌ Cannot notarize an ad-hoc ('-') build. Pass a Developer ID Application --identity." >&2
    exit 1
fi

INFO_PLIST="${REPO_ROOT}/LocalConvert/Info.plist"
if [[ -z "${VERSION}" ]]; then
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${INFO_PLIST}")
fi
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "${INFO_PLIST}" 2>/dev/null || echo "1")
BUNDLE_IDENTIFIER="com.localconvert.app"

GIT_COMMIT="unknown"
GIT_DIRTY_COUNT=0
GIT_DIRTY="false"
if git -C "${REPO_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    GIT_COMMIT="$(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null || echo unknown)"
    GIT_STATUS_PORCELAIN="$(git -C "${REPO_ROOT}" status --porcelain 2>/dev/null || true)"
    if [[ -n "${GIT_STATUS_PORCELAIN}" ]]; then
        GIT_DIRTY_COUNT="$(printf '%s\n' "${GIT_STATUS_PORCELAIN}" | wc -l | tr -d ' ')"
        GIT_DIRTY="true"
    fi
fi

if [[ "${GIT_DIRTY}" == "true" && "${ALLOW_DIRTY}" -ne 1 ]]; then
    echo "❌ Refusing to package release from a dirty git working tree (${GIT_DIRTY_COUNT} changed/untracked paths)." >&2
    echo "   Commit or clean changes, or pass --allow-dirty explicitly." >&2
    exit 1
fi

OUTPUT_DIR_ABS="$(cd "${REPO_ROOT}" && python3 -c 'import os, sys; print(os.path.abspath(sys.argv[1]))' "${OUTPUT_DIR}")"
if [[ -n "${DERIVED_DATA}" ]]; then
    DERIVED_DATA_ABS="$(cd "${REPO_ROOT}" && python3 -c 'import os, sys; print(os.path.abspath(sys.argv[1]))' "${DERIVED_DATA}")"
    if [[ "${DERIVED_DATA_ABS}" == "${OUTPUT_DIR_ABS}" || "${DERIVED_DATA_ABS}" == "${OUTPUT_DIR_ABS}/"* || "${OUTPUT_DIR_ABS}" == "${DERIVED_DATA_ABS}/"* ]]; then
        echo "❌ --derived-data (${DERIVED_DATA_ABS}) must remain separate from --output-dir (${OUTPUT_DIR_ABS})." >&2
        exit 1
    fi
fi

WORK_ROOT=""
cleanup_work() {
    if [[ -n "${WORK_ROOT:-}" ]]; then
        rm -rf "${WORK_ROOT}"
    fi
}
trap cleanup_work EXIT INT TERM

RELEASE_DIR="${OUTPUT_DIR_ABS}/${VERSION}"
DMG_NAME="LocalConvert-${VERSION}-arm64.dmg"
ZIP_NAME="LocalConvert-${VERSION}-arm64.zip"
SHA_NAME="SHA256SUMS.txt"
MANIFEST_NAME="release-manifest.json"
RELEASE_NOTES_NAME="RELEASE_NOTES_${VERSION}.md"
RELEASE_NOTES_SRC="${REPO_ROOT}/docs/${RELEASE_NOTES_NAME}"
DMG_PATH="${RELEASE_DIR}/${DMG_NAME}"
ZIP_PATH="${RELEASE_DIR}/${ZIP_NAME}"
SHA_FILE="${RELEASE_DIR}/${SHA_NAME}"
MANIFEST_FILE="${RELEASE_DIR}/${MANIFEST_NAME}"
RELEASE_NOTES_FILE="${RELEASE_DIR}/${RELEASE_NOTES_NAME}"
ENTITLEMENTS="${REPO_ROOT}/LocalConvert/LocalConvert.entitlements"
QUICKACTIONS_ENTITLEMENTS="${REPO_ROOT}/LocalConvertQuickActions/LocalConvertQuickActions.entitlements"

SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo unknown)"
SDK_NAME="macosx${SDK_VERSION}"
if [[ "${IDENTITY}" == "-" ]]; then
    HARDENED_RUNTIME_MODE="app-only-adhoc"
else
    HARDENED_RUNTIME_MODE="runtime-all"
fi

if [[ "${DRY_RUN}" -eq 1 ]]; then
    PLANNED_ARTIFACTS="${DMG_NAME}, ${ZIP_NAME}, ${SHA_NAME}, ${MANIFEST_NAME}"
    if [[ -f "${RELEASE_NOTES_SRC}" ]]; then
        PLANNED_ARTIFACTS="${PLANNED_ARTIFACTS}, ${RELEASE_NOTES_NAME}"
    fi
    cat <<EOF
[DRY RUN] LocalConvert Release Packaging Plan
  Version / Build:      ${VERSION} (${BUILD_NUMBER})
  Configuration / Arch: ${CONFIGURATION} / arm64 (${SDK_NAME})
  Git Commit / Dirty:   ${GIT_COMMIT} / dirty=${GIT_DIRTY} (${GIT_DIRTY_COUNT} entries, allow_dirty=${ALLOW_DIRTY})
  Signing Identity:     ${IDENTITY} (hardened runtime: ${HARDENED_RUNTIME_MODE})
  Notarize Profile:     ${NOTARIZE_PROFILE:-<none>}
  Isolated XcodeGen:    $([[ "${SKIP_BUILD}" -eq 0 ]] && echo "${TMPDIR:-/tmp}/localconvert-release-work.XXXXXX/project-gen" || echo "<skipped>")
  DerivedData:          ${DERIVED_DATA_ABS:-${TMPDIR:-/tmp}/localconvert-release-work.XXXXXX/DerivedData} (separate from output-dir)
  Stage Workspace:      ${TMPDIR:-/tmp}/localconvert-release-work.XXXXXX/artifacts
  Final Release Dir:    ${RELEASE_DIR}
  Planned Artifacts:    ${PLANNED_ARTIFACTS}
  Publish Mode:         Atomic hidden-sibling rename after build, codesign --verify, verify-dependencies.sh, and checksum verification
EOF
    exit 0
fi

WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/localconvert-release-work.XXXXXX")"

if [[ -z "${DERIVED_DATA}" ]]; then
    DERIVED_DATA_ABS="${WORK_ROOT}/DerivedData"
fi

if [[ -n "${APP_PATH_OVERRIDE}" ]]; then
    APP_PATH="${APP_PATH_OVERRIDE}"
else
    APP_PATH="${DERIVED_DATA_ABS}/Build/Products/${CONFIGURATION}/LocalConvert.app"
fi

WORK_APP_COPY="${WORK_ROOT}/app-stage/LocalConvert.app"
DMG_STAGE="${WORK_ROOT}/dmg-root"
ARTIFACT_STAGE="${WORK_ROOT}/artifacts"
XCODEGEN_WORKSPACE="${WORK_ROOT}/project-gen"

sign_target() {
    local target="$1"
    local extra_entitlements="${2:-}"
    local cmd=(/usr/bin/codesign --force)
    if [[ "${IDENTITY}" == "-" ]]; then
        # Ad-hoc nested helpers omit --options runtime (matching project.yml) so bundled LibreOffice
        # loads ad-hoc dylibs without dyld Team ID mismatch; the outer entitled app uses --options runtime.
        if [[ -n "${extra_entitlements}" ]]; then
            cmd+=(--options runtime)
        fi
        cmd+=(--sign - --timestamp=none)
    else
        cmd+=(--options runtime --timestamp --sign "${IDENTITY}")
    fi
    if [[ -n "${extra_entitlements}" ]]; then
        cmd+=(--entitlements "${extra_entitlements}")
    fi
    cmd+=("${target}")
    "${cmd[@]}"
}

echo "🚀 Packaging LocalConvert ${VERSION} (build ${BUILD_NUMBER}, ${CONFIGURATION}, identity=${IDENTITY})"

if [[ "${SKIP_BUILD}" -eq 0 ]]; then
    if ! command -v xcodegen >/dev/null 2>&1; then
        echo "❌ XcodeGen is required for isolated project generation." >&2
        exit 1
    fi

    echo "▶ Generating isolated Xcode project in ${XCODEGEN_WORKSPACE} (leaving repo .xcodeproj untouched)..."
    mkdir -p "${XCODEGEN_WORKSPACE}"
    for item in LocalConvert LocalConvertQuickActions LocalConvertTests LocalConvertUITests LocalConvertTestSupport LICENSE THIRD_PARTY_NOTICES.md scripts project.yml; do
        if [[ -e "${REPO_ROOT}/${item}" ]]; then
            ln -s "${REPO_ROOT}/${item}" "${XCODEGEN_WORKSPACE}/${item}"
        fi
    done
    xcodegen generate --spec "${XCODEGEN_WORKSPACE}/project.yml" --project "${XCODEGEN_WORKSPACE}"

    echo "▶ Building LocalConvert (${CONFIGURATION}, arm64) into ${DERIVED_DATA_ABS}..."
    mkdir -p "${DERIVED_DATA_ABS}"
    BUILD_ARGS=(
        -project "${XCODEGEN_WORKSPACE}/LocalConvert.xcodeproj"
        -scheme LocalConvert
        -configuration "${CONFIGURATION}"
        -derivedDataPath "${DERIVED_DATA_ABS}"
        ARCHS=arm64
        ONLY_ACTIVE_ARCH=YES
    )
    if [[ "${IDENTITY}" == "-" ]]; then
        BUILD_ARGS+=(CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=YES)
    else
        BUILD_ARGS+=(CODE_SIGN_IDENTITY="${IDENTITY}" CODE_SIGN_STYLE=Manual)
    fi

    xcodebuild "${BUILD_ARGS[@]}" build
fi

if [[ ! -d "${APP_PATH}" ]]; then
    echo "❌ Expected built app bundle at ${APP_PATH}" >&2
    exit 1
fi

echo "▶ Staging app copy in isolated workspace (${WORK_APP_COPY})..."
mkdir -p "$(dirname "${WORK_APP_COPY}")"
/usr/bin/ditto "${APP_PATH}" "${WORK_APP_COPY}"

echo "▶ Stripping mutable Python bytecode (.pyc / __pycache__) and .DS_Store from staged app bundle..."
find "${WORK_APP_COPY}" -name ".DS_Store" -delete 2>/dev/null || true
LO_BUNDLE="${WORK_APP_COPY}/Contents/Resources/LibreOffice"
if [[ -d "${LO_BUNDLE}" ]]; then
    find "${LO_BUNDLE}" -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
    find "${LO_BUNDLE}" -name "*.pyc" -delete 2>/dev/null || true
fi

echo "▶ Performing inside-out code signing (--options runtime)..."
if [[ -d "${WORK_APP_COPY}/Contents/Frameworks" ]]; then
    while IFS= read -r -d "" fw_item; do
        if /usr/bin/file -b "${fw_item}" | /usr/bin/grep -q "Mach-O"; then
            sign_target "${fw_item}" >/dev/null
        fi
    done < <(find "${WORK_APP_COPY}/Contents/Frameworks" -type f -print0)
fi

for FFMPEG_TOOL in "ffmpeg" "ffprobe"; do
    TOOL_PATH="${WORK_APP_COPY}/Contents/Resources/ffmpeg/${FFMPEG_TOOL}"
    if [[ -f "${TOOL_PATH}" ]]; then
        chmod +x "${TOOL_PATH}"
        sign_target "${TOOL_PATH}" >/dev/null
    fi
done

if [[ -d "${LO_BUNDLE}" ]]; then
    while IFS= read -r -d "" lo_macho; do
        if /usr/bin/file -b "${lo_macho}" | /usr/bin/grep -q "Mach-O" && [[ "${lo_macho}" != *.o ]]; then
            sign_target "${lo_macho}" >/dev/null
        fi
    done < <(find "${LO_BUNDLE}/Contents" -type f -print0)

    PY_FW="${LO_BUNDLE}/Contents/Frameworks/LibreOfficePython.framework"
    if [[ -d "${PY_FW}/Versions" ]]; then
        for PY_VER_DIR in "${PY_FW}/Versions"/*; do
            [[ -d "${PY_VER_DIR}" && ! -L "${PY_VER_DIR}" ]] || continue
            if [[ -d "${PY_VER_DIR}/Resources/Python.app" ]]; then
                sign_target "${PY_VER_DIR}/Resources/Python.app" >/dev/null
            fi
            sign_target "${PY_VER_DIR}" >/dev/null
        done
    fi
    if [[ -d "${PY_FW}" ]]; then
        sign_target "${PY_FW}" >/dev/null
    fi
    sign_target "${LO_BUNDLE}" >/dev/null
fi

QUICKACTIONS_APPEX="${WORK_APP_COPY}/Contents/PlugIns/LocalConvertQuickActions.appex"
if [[ -d "${QUICKACTIONS_APPEX}" ]]; then
    sign_target "${QUICKACTIONS_APPEX}" "${QUICKACTIONS_ENTITLEMENTS}" >/dev/null
fi

sign_target "${WORK_APP_COPY}" "${ENTITLEMENTS}"

echo "▶ Verifying staged bundle signatures & third-party compliance..."
/usr/bin/codesign --verify --deep --strict --verbose=2 "${WORK_APP_COPY}"
if [[ "${CONFIGURATION}" == "Release" && -d "${QUICKACTIONS_APPEX}" ]]; then
    APPEX_ENTITLEMENTS_OUT="$(/usr/bin/codesign -d --entitlements :- "${QUICKACTIONS_APPEX}" 2>&1 || true)"
    if printf '%s' "${APPEX_ENTITLEMENTS_OUT}" | /usr/bin/grep -q "com.apple.security.get-task-allow"; then
        echo "❌ Release Quick Actions extension must not contain com.apple.security.get-task-allow entitlement (${QUICKACTIONS_APPEX})." >&2
        exit 1
    fi
fi
bash "${SCRIPT_DIR}/verify-dependencies.sh" --app "${WORK_APP_COPY}"

if [[ -d "${LO_BUNDLE}" ]]; then
    echo "▶ Smoke-testing bundled soffice..."
    PYTHONDONTWRITEBYTECODE=1 "${LO_BUNDLE}/Contents/MacOS/soffice" --headless --version
fi

echo "▶ Assessing Gatekeeper status (spctl)..."
if SPCTL_OUT=$(/usr/sbin/spctl --assess --type execute -v "${WORK_APP_COPY}" 2>&1); then
    echo "✅ Gatekeeper assessment passed: ${SPCTL_OUT}"
else
    if [[ "${IDENTITY}" == "-" ]]; then
        echo "ℹ️  Gatekeeper assessment (expected for ad-hoc '-' local build): ${SPCTL_OUT}"
    else
        echo "⚠️  Gatekeeper assessment returned non-zero before notarization: ${SPCTL_OUT}"
    fi
fi

echo "▶ Staging distribution archives in temporary directory (${ARTIFACT_STAGE})..."
mkdir -p "${DMG_STAGE}" "${ARTIFACT_STAGE}"
/usr/bin/ditto "${WORK_APP_COPY}" "${DMG_STAGE}/LocalConvert.app"
find "${DMG_STAGE}" -name ".DS_Store" -delete 2>/dev/null || true
ln -s /Applications "${DMG_STAGE}/Applications"

STAGED_DMG="${ARTIFACT_STAGE}/${DMG_NAME}"
STAGED_ZIP="${ARTIFACT_STAGE}/${ZIP_NAME}"
STAGED_SHA="${ARTIFACT_STAGE}/${SHA_NAME}"
STAGED_MANIFEST="${ARTIFACT_STAGE}/${MANIFEST_NAME}"

/usr/bin/hdiutil create \
    -volname "LocalConvert ${VERSION}" \
    -srcfolder "${DMG_STAGE}" \
    -ov \
    -format UDZO \
    "${STAGED_DMG}"

if [[ "${IDENTITY}" != "-" ]]; then
    /usr/bin/codesign --force --timestamp --sign "${IDENTITY}" "${STAGED_DMG}"
fi

NOTARIZED="false"
if [[ -n "${NOTARIZE_PROFILE}" ]]; then
    echo "▶ Submitting ${STAGED_DMG} for notarization with profile '${NOTARIZE_PROFILE}'..."
    xcrun notarytool submit "${STAGED_DMG}" --keychain-profile "${NOTARIZE_PROFILE}" --wait
    xcrun stapler staple "${WORK_APP_COPY}"
    xcrun stapler staple "${STAGED_DMG}"
    /usr/sbin/spctl --assess --type execute -v "${WORK_APP_COPY}"
    /usr/sbin/spctl --assess --type open --context context:primary-signature -v "${STAGED_DMG}"
    NOTARIZED="true"
    echo "✅ Notarization and stapling complete!"
fi

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "${WORK_APP_COPY}" "${STAGED_ZIP}"

(
    cd "${ARTIFACT_STAGE}"
    shasum -a 256 "${DMG_NAME}" "${ZIP_NAME}" > "${STAGED_SHA}"
    shasum -a 256 -c "${SHA_NAME}"
)

APP_BINARY="${WORK_APP_COPY}/Contents/MacOS/LocalConvert"
APP_BINARY_SHA256="$(shasum -a 256 "${APP_BINARY}" | awk '{print $1}')"
DMG_SHA256="$(shasum -a 256 "${STAGED_DMG}" | awk '{print $1}')"
ZIP_SHA256="$(shasum -a 256 "${STAGED_ZIP}" | awk '{print $1}')"

python3 - "${STAGED_MANIFEST}" "${VERSION}" "${BUILD_NUMBER}" "${BUNDLE_IDENTIFIER}" "${CONFIGURATION}" "${GIT_COMMIT}" "${GIT_DIRTY}" "${SDK_NAME}" "${IDENTITY}" "${HARDENED_RUNTIME_MODE}" "${NOTARIZED}" "${APP_BINARY_SHA256}" "${DMG_NAME}" "${DMG_SHA256}" "${ZIP_NAME}" "${ZIP_SHA256}" <<'PY'
import json
import sys
from datetime import datetime, timezone

(
    out_path,
    version,
    build_number,
    bundle_id,
    configuration,
    git_commit,
    git_dirty,
    sdk_name,
    identity,
    hardened_runtime_mode,
    notarized,
    binary_sha256,
    dmg_name,
    dmg_sha256,
    zip_name,
    zip_sha256,
) = sys.argv[1:]

manifest = {
    "schemaVersion": 1,
    "generatedAtUTC": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "bundleIdentifier": bundle_id,
    "version": version,
    "build": build_number,
    "configuration": configuration,
    "arch": "arm64",
    "sdk": sdk_name,
    "gitCommit": git_commit,
    "gitDirty": (git_dirty == "true"),
    "signingIdentity": identity,
    "hardenedRuntimeOptions": hardened_runtime_mode,
    "notarized": (notarized == "true"),
    "appBinarySHA256": binary_sha256,
    "artifacts": {
        dmg_name: {"sha256": dmg_sha256},
        zip_name: {"sha256": zip_sha256},
    },
}

with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(manifest, fh, indent=2, sort_keys=False)
    fh.write("\n")
PY

PUBLISH_NAMES=("${DMG_NAME}" "${ZIP_NAME}" "${SHA_NAME}" "${MANIFEST_NAME}")
if [[ -f "${RELEASE_NOTES_SRC}" ]]; then
    cp -p "${RELEASE_NOTES_SRC}" "${ARTIFACT_STAGE}/${RELEASE_NOTES_NAME}"
    PUBLISH_NAMES+=("${RELEASE_NOTES_NAME}")
fi

if [[ "${SIMULATE_FAILURE_BEFORE_PUBLISH}" -eq 1 ]]; then
    echo "❌ Simulated failure before atomic publish (staged artifacts discarded; pre-existing ${RELEASE_DIR} preserved)." >&2
    exit 1
fi

echo "▶ Publishing validated artifacts atomically into ${RELEASE_DIR}..."
mkdir -p "${RELEASE_DIR}"
STAGED_TARGET_TMP=()

cleanup_publish_tmp() {
    for tmp_f in "${STAGED_TARGET_TMP[@]:-}"; do
        rm -f "${tmp_f}" 2>/dev/null || true
    done
}
trap 'cleanup_publish_tmp; cleanup_work' EXIT INT TERM

for fname in "${PUBLISH_NAMES[@]}"; do
    tmp_target="${RELEASE_DIR}/.${fname}.staging.$$"
    STAGED_TARGET_TMP+=("${tmp_target}")
    cp -p "${ARTIFACT_STAGE}/${fname}" "${tmp_target}"
    if [[ ! -s "${tmp_target}" ]]; then
        echo "❌ Staged target missing or empty before commit: ${tmp_target}" >&2
        exit 1
    fi
done

for fname in "${PUBLISH_NAMES[@]}"; do
    mv -f "${RELEASE_DIR}/.${fname}.staging.$$" "${RELEASE_DIR}/${fname}"
done
STAGED_TARGET_TMP=()

echo "✅ Published ${DMG_PATH}"
echo "✅ Published ${ZIP_PATH}"
echo "✅ Published ${SHA_FILE}"
echo "✅ Published ${MANIFEST_FILE}"
if [[ -f "${RELEASE_NOTES_FILE}" ]]; then
    echo "✅ Published ${RELEASE_NOTES_FILE}"
fi

if [[ -z "${NOTARIZE_PROFILE}" && "${IDENTITY}" != "-" ]]; then
    cat <<EOF

ℹ️  Signed with Developer ID ('${IDENTITY}'), notarization skipped (no --notarize-profile supplied).
Re-run with --notarize-profile "<KEYCHAIN_PROFILE>" to notarize, staple, and atomically republish DMG/ZIP/checksums/manifest.
EOF
elif [[ -z "${NOTARIZE_PROFILE}" ]]; then
    echo ""
    echo "ℹ️  Ad-hoc ('-') local package verified. For public macOS distribution without Gatekeeper warnings,"
    echo "    re-run with a Developer ID Application certificate and notarytool keychain profile:"
    echo "    scripts/package-release.sh --identity \"Developer ID Application: <Your Name> (<TEAMID>)\" --notarize-profile \"<PROFILE>\""
fi
