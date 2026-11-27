import Foundation
import os.log

// MARK: - CLI Bridge Errors & Result

enum CLIBridgeError: Error, LocalizedError, Equatable, Sendable {
    case invalidBaseDirectory(URL)
    case writeFailed(String)
    case permissionUpdateFailed(String)
    case removalFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseDirectory(let url):
            return String(localized: "Cannot install CLI helper into invalid directory: \(url.path)")
        case .writeFailed(let detail):
            return String(localized: "Failed to install localconvert CLI helper: \(detail)")
        case .permissionUpdateFailed(let detail):
            return String(localized: "Failed to mark localconvert CLI helper as executable: \(detail)")
        case .removalFailed(let detail):
            return String(localized: "Failed to remove localconvert CLI helper: \(detail)")
        }
    }
}

struct CLIBridgeInstallStatus: Equatable, Sendable {
    let scriptURL: URL
    let isInstalled: Bool
    let isExecutable: Bool
    let isBinDirectoryInPATH: Bool
    let resolvedAppPath: String
}

// MARK: - CLI Bridge Installer

/// Installs and removes a lightweight `~/.local/bin/localconvert` bash/zsh launcher script
/// that opens `LocalConvert.app` with any passed file paths or `localconvert://` URLs.
struct CLIBridgeInstaller: Sendable {

    static let shared = CLIBridgeInstaller()
    static let commandName = "localconvert"
    private static let logger = Logger(subsystem: "com.localconvert.app", category: "CLIBridgeInstaller")

    let baseDirectory: URL
    let appBundlePathOverride: String?

    init(
        baseDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        appBundlePathOverride: String? = nil
    ) {
        self.baseDirectory = baseDirectory.standardizedFileURL
        self.appBundlePathOverride = appBundlePathOverride
    }

    var binDirectoryURL: URL {
        baseDirectory
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
    }

    var scriptURL: URL {
        binDirectoryURL.appendingPathComponent(Self.commandName, isDirectory: false)
    }

    var isInstalled: Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: scriptURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return false
        }
        return fm.isExecutableFile(atPath: scriptURL.path)
    }

    func status(environment: [String: String] = ProcessInfo.processInfo.environment) -> CLIBridgeInstallStatus {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: scriptURL.path, isDirectory: &isDir) && !isDir.boolValue
        let executable = exists && fm.isExecutableFile(atPath: scriptURL.path)
        let pathEntries = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true).standardizedFileURL.path }
        let binPath = binDirectoryURL.standardizedFileURL.path
        let inPATH = pathEntries.contains(binPath)

        return CLIBridgeInstallStatus(
            scriptURL: scriptURL,
            isInstalled: exists && executable,
            isExecutable: executable,
            isBinDirectoryInPATH: inPATH,
            resolvedAppPath: resolvedAppBundlePath()
        )
    }

    func resolvedAppBundlePath() -> String {
        if let override = appBundlePathOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override
        }

        let mainBundleURL = Bundle.main.bundleURL.standardizedFileURL
        if mainBundleURL.pathExtension == "app",
           !mainBundleURL.path.contains(".xctest") {
            return mainBundleURL.path
        }

        let applicationsPath = "/Applications/LocalConvert.app"
        if FileManager.default.fileExists(atPath: applicationsPath) {
            return applicationsPath
        }

        return "LocalConvert"
    }

    func renderLauncherScript() -> String {
        let escapedAppPath = Self.singleQuotedShellLiteral(resolvedAppBundlePath())
        return """
        #!/usr/bin/env bash
        set -euo pipefail

        usage() {
          printf "Usage: localconvert [--] [file ...]\\n"
          printf "Opens LocalConvert and queues the specified files for local conversion.\\n"
        }

        END_OF_OPTIONS=0
        FILTERED_ARGS=()

        for arg in "$@"; do
          if [[ "$END_OF_OPTIONS" -eq 0 ]]; then
            case "$arg" in
              -h|--help)
                usage
                exit 0
                ;;
              --)
                END_OF_OPTIONS=1
                continue
                ;;
              -*)
                printf "localconvert: unrecognized option '%s'\\n" "$arg" >&2
                exit 2
                ;;
            esac
          fi
          FILTERED_ARGS+=("$arg")
        done

        APP_TARGET=\(escapedAppPath)
        if [[ "$APP_TARGET" == /* && ! -d "$APP_TARGET" ]]; then
          APP_TARGET="LocalConvert"
        fi

        if [[ ${#FILTERED_ARGS[@]} -eq 0 ]]; then
          open -a "$APP_TARGET"
          exit 0
        fi

        RESOLVED_PATHS=()
        for arg in "${FILTERED_ARGS[@]}"; do
          if [[ "$arg" == localconvert://* ]]; then
            RESOLVED_PATHS+=("$arg")
          elif [[ -e "$arg" ]]; then
            DIR_PART="$(cd -- "$(dirname -- "$arg")" && pwd)"
            BASE_PART="$(basename -- "$arg")"
            RESOLVED_PATHS+=("${DIR_PART%/}/${BASE_PART}")
          else
            RESOLVED_PATHS+=("$arg")
          fi
        done

        open -a "$APP_TARGET" "${RESOLVED_PATHS[@]}"
        """
    }

    @discardableResult
    func install() throws -> CLIBridgeInstallStatus {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: binDirectoryURL, withIntermediateDirectories: true)
        } catch {
            throw CLIBridgeError.writeFailed(error.localizedDescription)
        }

        try OutputReservationCoordinator.validateWritableDirectory(binDirectoryURL)

        let tempURL = binDirectoryURL.appendingPathComponent(".LocalConvert-cli-\(UUID().uuidString).tmp", isDirectory: false)
        defer {
            try? fm.removeItem(at: tempURL)
        }

        let script = renderLauncherScript() + "\n"
        do {
            try script.write(to: tempURL, atomically: true, encoding: .utf8)
        } catch {
            throw CLIBridgeError.writeFailed(error.localizedDescription)
        }

        do {
            try fm.setAttributes([.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: tempURL.path)
        } catch {
            throw CLIBridgeError.permissionUpdateFailed(error.localizedDescription)
        }

        let finalURL: URL
        do {
            finalURL = try OutputReservationCoordinator.moveOrReplaceTempFile(
                tempURL,
                to: scriptURL,
                policy: .overwrite
            )
        } catch {
            throw CLIBridgeError.writeFailed(error.localizedDescription)
        }

        do {
            try fm.setAttributes([.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: finalURL.path)
        } catch {
            throw CLIBridgeError.permissionUpdateFailed(error.localizedDescription)
        }

        Self.logger.info("Installed localconvert CLI helper at \(finalURL.path, privacy: .private)")
        return status()
    }

    @discardableResult
    func remove() throws -> CLIBridgeInstallStatus {
        let fm = FileManager.default
        if fm.fileExists(atPath: scriptURL.path) {
            do {
                try fm.removeItem(at: scriptURL)
                Self.logger.info("Removed localconvert CLI helper from \(scriptURL.path, privacy: .private)")
            } catch {
                throw CLIBridgeError.removalFailed(error.localizedDescription)
            }
        }
        return status()
    }

    private static func singleQuotedShellLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
