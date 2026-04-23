import AppKit

extension NSAttributedString.Key {
    /// Marks a character range as part of a block-level code region
    /// (fenced or indented). `CodeBlockLayoutManager` uses this to draw
    /// the background as a full line-fragment-wide rectangle instead of
    /// the tight glyph hull NSLayoutManager would draw otherwise.
    static let isCodeBlock = NSAttributedString.Key("readerCodeBlock")
}

/// Paints the `codeBackground` rectangle across the full line fragment
/// for any range flagged `.isCodeBlock`, so code blocks read as a solid
/// band rather than a ragged shape following each line's glyph width.
///
/// Non-code backgrounds fall through to the default implementation.
final class CodeBlockLayoutManager: NSLayoutManager {
    override func fillBackgroundRectArray(
        _ rectArray: UnsafePointer<NSRect>,
        count rectCount: Int,
        forCharacterRange charRange: NSRange,
        color: NSColor
    ) {
        guard let storage = textStorage,
              charRange.location < storage.length,
              let flag = storage.attribute(.isCodeBlock, at: charRange.location, effectiveRange: nil) as? Bool,
              flag == true
        else {
            super.fillBackgroundRectArray(
                rectArray,
                count: rectCount,
                forCharacterRange: charRange,
                color: color
            )
            return
        }

        color.setFill()
        let glyphRange = self.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        var glyph = glyphRange.location
        while glyph < NSMaxRange(glyphRange) {
            var effective = NSRange()
            let lineRect = lineFragmentRect(forGlyphAt: glyph, effectiveRange: &effective)
            NSBezierPath(rect: lineRect).fill()
            glyph = NSMaxRange(effective)
        }
    }
}
