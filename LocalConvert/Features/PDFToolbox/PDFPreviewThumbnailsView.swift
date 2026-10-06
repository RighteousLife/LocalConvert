import SwiftUI
import PDFKit

struct PDFPreviewThumbnailsView: NSViewRepresentable {
    let pdfURL: URL?
    var password: String? = nil
    
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
        
        if let url = pdfURL, let document = PDFDocument(url: url) {
            if document.isLocked, let pwd = password, !pwd.isEmpty {
                document.unlock(withPassword: pwd)
            }
            pdfView.document = document
        }
        
        return container
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let pdfView = nsView.subviews.first(where: { $0 is PDFView }) as? PDFView else { return }
        
        if let url = pdfURL {
            let doc = PDFDocument(url: url)
            if let doc, doc.isLocked, let pwd = password, !pwd.isEmpty {
                doc.unlock(withPassword: pwd)
            }
            pdfView.document = doc
        } else {
            pdfView.document = nil
        }
    }
}
