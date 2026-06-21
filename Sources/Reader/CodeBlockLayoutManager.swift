import AppKit

extension NSAttributedString.Key {
    /// Marks a character range as part of a block-level code region
    /// (fenced or indented). `CodeBlockLayoutFragment` uses this to draw
    /// the background as a full line-fragment-wide rectangle instead of
    /// the tight glyph hull NSTextLayoutManager would draw otherwise.
    static let isCodeBlock = NSAttributedString.Key("readerCodeBlock")
}

/// TextKit 2 equivalent of the old `CodeBlockLayoutManager`. Subclasses
/// `NSTextLayoutFragment` to draw the `codeBackground` rectangle across
/// the full line-fragment width for any fragment whose first character is
/// flagged `.isCodeBlock`. Non-code fragments fall through to the default
/// implementation.
///
/// `MainWindowController` returns this class from its layout-manager
/// delegate so every fragment that lays out code-block characters gets
/// the full-width band.
final class CodeBlockLayoutFragment: NSTextLayoutFragment {
    override func draw(at point: CGPoint, in context: CGContext) {
        if isCodeBlock {
            context.saveGState()
            context.setFillColor(Theme.codeBackground.cgColor)
            // `layoutFragmentFrame` is in container coordinates; subtract
            // the fragment origin to translate into the rect we're asked
            // to draw at.
            let frame = layoutFragmentFrame
            let containerWidth = textLayoutManager?.textContainer?.size.width ?? frame.width
            context.fill(CGRect(
                x: point.x,
                y: point.y,
                width: containerWidth,
                height: frame.height
            ))
            context.restoreGState()
        }
        super.draw(at: point, in: context)
    }

    private var isCodeBlock: Bool {
        guard let elementRange = textElement?.elementRange,
              let manager = textLayoutManager,
              let contentStorage = manager.textContentManager as? NSTextContentStorage,
              let storage = contentStorage.textStorage,
              let nsRange = contentStorage.nsRange(for: elementRange),
              nsRange.location < storage.length
        else { return false }
        let flag = storage.attribute(
            .isCodeBlock, at: nsRange.location, effectiveRange: nil
        ) as? Bool
        return flag == true
    }
}

private extension NSTextContentStorage {
    func nsRange(for textRange: NSTextRange) -> NSRange? {
        let start = offset(from: documentRange.location, to: textRange.location)
        let length = offset(from: textRange.location, to: textRange.endLocation)
        guard start >= 0, length >= 0 else { return nil }
        return NSRange(location: start, length: length)
    }
}
