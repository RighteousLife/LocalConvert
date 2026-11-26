import SwiftUI
import PDFKit

struct PDFPreviewThumbnailsView: NSViewRepresentable {
    let pdfURL: URL?
    var password: String? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()

        let pdfView = PDFView()
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .horizontal

        let thumbnailView = PDFThumbnailView()
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailView.pdfView = pdfView
        thumbnailView.thumbnailSize = NSSize(width: 80, height: 100)

        container.addSubview(pdfView)
        container.addSubview(thumbnailView)

        NSLayoutConstraint.activate([
            thumbnailView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            thumbnailView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            thumbnailView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            thumbnailView.heightAnchor.constraint(equalToConstant: 100),

            pdfView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: container.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: thumbnailView.topAnchor, constant: -8)
        ])

        context.coordinator.syncDocument(into: pdfView, url: pdfURL, password: password)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let pdfView = nsView.subviews.first(where: { $0 is PDFView }) as? PDFView else { return }
        context.coordinator.syncDocument(into: pdfView, url: pdfURL, password: password)
    }

    @MainActor
    final class Coordinator {
        private var loadedURL: URL?
        private var loadedFileSignature: String?
        private var loadedPassword: String?

        func syncDocument(into pdfView: PDFView, url: URL?, password: String?) {
            guard let url = url?.standardizedFileURL else {
                if loadedURL != nil || pdfView.document != nil {
                    pdfView.document = nil
                    loadedURL = nil
                    loadedFileSignature = nil
                    loadedPassword = nil
                }
                return
            }

            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? Int64) ?? 0
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let signature = "\(size)|\(mtime)"
            let normalizedPwd = password?.isEmpty == false ? password : nil

            if loadedURL == url && loadedFileSignature == signature && (pdfView.document?.isLocked == false || loadedPassword == normalizedPwd) {
                return
            }

            guard let doc = PDFDocument(url: url) else {
                pdfView.document = nil
                loadedURL = url
                loadedFileSignature = signature
                loadedPassword = normalizedPwd
                return
            }

            if doc.isLocked, let pwd = normalizedPwd {
                _ = doc.unlock(withPassword: pwd)
            }
            pdfView.document = doc
            loadedURL = url
            loadedFileSignature = signature
            loadedPassword = normalizedPwd
        }
    }
}
