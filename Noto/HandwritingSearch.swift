import Vision
import UIKit

// Recognizes text from a page's own ink (rasterized, then OCR'd via Vision) so search can also match
// handwritten notes, not just the PDF's real text layer. Not cheap, so callers should cache per page.
enum HandwritingSearch {
    // Results are in page space (top-left origin), the same convention as the rest of the app.
    static func recognize(strokes: [InkStroke], pageSize: CGSize) async -> [(text: String, rect: CGRect)] {
        guard !strokes.isEmpty, pageSize.width > 0, pageSize.height > 0 else { return [] }
        let scale: CGFloat = 2 // light supersampling helps Vision on thin pen strokes
        let renderSize = CGSize(width: pageSize.width * scale, height: pageSize.height * scale)
        let image = UIGraphicsImageRenderer(size: renderSize).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: renderSize))
            ctx.cgContext.scaleBy(x: scale, y: scale)
            for stroke in strokes {
                let color = InkStroke.uiColor(stroke.color).cgColor
                for run in InkGeometry.runs(of: stroke.points, width: stroke.width, pressure: stroke.pressure, kind: stroke.kind) {
                    ctx.cgContext.setStrokeColor(color)
                    ctx.cgContext.setLineWidth(run.width)
                    ctx.cgContext.setLineCap(.round)
                    ctx.cgContext.setLineJoin(.round)
                    ctx.cgContext.addPath(InkGeometry.path(run.points))
                    ctx.cgContext.strokePath()
                }
            }
        }
        guard let cgImage = image.cgImage else { return [] }

        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let results = observations.compactMap { observation -> (text: String, rect: CGRect)? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    // Vision's boundingBox is normalized with a bottom-left origin; flip to this app's page space.
                    let box = observation.boundingBox
                    let rect = CGRect(x: box.minX * pageSize.width, y: (1 - box.maxY) * pageSize.height,
                                      width: box.width * pageSize.width, height: box.height * pageSize.height)
                    return (candidate.string, rect)
                }
                continuation.resume(returning: results)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["ko-KR", "en-US"]
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                // If perform itself throws, the request's own completion handler never runs — resume here so the
                // continuation can't hang forever waiting for a callback that isn't coming.
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: [])
                }
            }
        }
    }
}
