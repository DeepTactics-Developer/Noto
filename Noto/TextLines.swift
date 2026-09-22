import CoreGraphics

// Groups a PDF page's character-level bounding boxes into lines of text, for the highlighter's "snap to text"
// setting. Pure geometry, independent of PDFKit, so it can be unit tested without a real PDF.
enum TextLineLayout {
    // `bounds` is one rect per character, in reading order (however the source numbers them) — consecutive
    // characters whose vertical center stays within the current line's own height are the same line.
    static func lines(fromCharacterBounds bounds: [CGRect]) -> [CGRect] {
        var lines: [CGRect] = []
        var current: CGRect?
        for box in bounds where box.width > 0 && box.height > 0 {
            if let existing = current, abs(box.midY - existing.midY) <= existing.height * 0.4 {
                current = existing.union(box)
            } else {
                if let existing = current { lines.append(existing) }
                current = box
            }
        }
        if let existing = current { lines.append(existing) }
        return lines
    }
}
