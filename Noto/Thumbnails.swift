import SwiftUI
import PDFKit

// Small page renders shared by the library grid and the note screen's page rail, so a page already seen
// in one place is instant in the other.
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, UIImage>()
    private let queue = DispatchQueue(label: "noto.thumbnail", qos: .utility)

    func image(for folder: DocumentFolder, page: Int, width: CGFloat, completion: @escaping (UIImage) -> Void) {
        let key = "\(folder.id)_\(page)_\(Int(width))" as NSString
        if let cached = cache.object(forKey: key) {
            completion(cached)
            return
        }
        queue.async { [weak self] in
            guard let self,
                  let doc = CGPDFDocument(folder.pdfURL as CFURL),
                  let cgPage = doc.page(at: page + 1) else { return }
            let box = cgPage.getBoxRect(.cropBox)
            let rotated = cgPage.rotationAngle % 180 != 0
            let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
            guard size.width > 0, size.height > 0 else { return }
            let image = PDFRenderer.preview(of: cgPage, pageSize: size, width: width)
            self.cache.setObject(image, forKey: key)
            DispatchQueue.main.async { completion(image) }
        }
    }
}

struct ThumbnailImage: View {
    let folder: DocumentFolder
    let page: Int
    let width: CGFloat
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable()
            } else {
                Color.white
            }
        }
        .task(id: "\(folder.id)_\(page)_\(Int(width))") {
            ThumbnailCache.shared.image(for: folder, page: page, width: width) { image = $0 }
        }
    }
}
