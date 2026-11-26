import Foundation

// MARK: - Output File Naming & Atomic Reservation (Compatibility Forwarding Shims)

extension ConversionManager {

    nonisolated static func outputURL(
        for inputURL: URL,
        format: FileFormat,
        in directory: URL,
        options: ConversionOptions = .default
    ) -> URL {
        OutputReservationCoordinator.outputURL(for: inputURL, format: format, in: directory, options: options)
    }

    nonisolated static func reserveOutputURL(
        for inputURL: URL,
        format: FileFormat,
        in directory: URL,
        options: ConversionOptions = .default
    ) throws -> URL {
        try OutputReservationCoordinator.reserveOutputURL(for: inputURL, format: format, in: directory, options: options)
    }

    nonisolated static func reserveUniqueOutputURL(
        directory: URL,
        baseName: String,
        extension ext: String,
        sourceURL: URL? = nil,
        policy: ExistingFileHandling = .createUnique
    ) throws -> URL {
        try OutputReservationCoordinator.reserveUniqueOutputURL(
            directory: directory,
            baseName: baseName,
            extension: ext,
            sourceURL: sourceURL,
            policy: policy
        )
    }

    nonisolated static func reserveMultiPageOutputURL(
        for inputURL: URL,
        pageIndex: Int,
        totalPages: Int,
        format: FileFormat,
        in directory: URL,
        options: ConversionOptions = .default
    ) throws -> URL {
        try OutputReservationCoordinator.reserveMultiPageOutputURL(
            for: inputURL,
            pageIndex: pageIndex,
            totalPages: totalPages,
            format: format,
            in: directory,
            options: options
        )
    }

    nonisolated static func releaseReservedOutputURL(_ url: URL) {
        OutputReservationCoordinator.releaseReservedOutputURL(url)
    }

    nonisolated static func clearReservedOutputURLs() {
        OutputReservationCoordinator.clearReservedOutputURLs()
    }

    @discardableResult
    nonisolated static func cleanStaleTemporaryFiles(
        in directory: URL = FileManager.default.temporaryDirectory,
        olderThan ageSeconds: TimeInterval = 3600
    ) -> Int {
        OutputReservationCoordinator.cleanStaleTemporaryFiles(in: directory, olderThan: ageSeconds)
    }

    nonisolated static func finalizeOutputFile(
        from tempURL: URL,
        for inputURL: URL,
        format: FileFormat,
        in directory: URL,
        options: ConversionOptions = .default
    ) throws -> URL {
        try OutputReservationCoordinator.finalizeOutputFile(
            from: tempURL,
            for: inputURL,
            format: format,
            in: directory,
            options: options
        )
    }

    nonisolated static func finalizeOutputFile(
        from tempURL: URL,
        directory: URL,
        baseName: String,
        extension ext: String,
        sourceURL: URL? = nil,
        policy: ExistingFileHandling = .createUnique
    ) throws -> URL {
        try OutputReservationCoordinator.finalizeOutputFile(
            from: tempURL,
            directory: directory,
            baseName: baseName,
            extension: ext,
            sourceURL: sourceURL,
            policy: policy
        )
    }

    nonisolated static func uniqueOutputURL(directory: URL, baseName: String, extension ext: String) -> URL {
        OutputReservationCoordinator.uniqueOutputURL(directory: directory, baseName: baseName, extension: ext)
    }

    nonisolated static func multiPageOutputURL(
        for inputURL: URL,
        pageIndex: Int,
        totalPages: Int,
        format: FileFormat,
        in directory: URL
    ) -> URL {
        OutputReservationCoordinator.multiPageOutputURL(
            for: inputURL,
            pageIndex: pageIndex,
            totalPages: totalPages,
            format: format,
            in: directory
        )
    }
}
