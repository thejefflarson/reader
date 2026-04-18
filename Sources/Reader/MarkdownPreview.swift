import AppKit

extension NSAttributedString.Key {
    /// Marks a character range as a markdown syntax marker (the literal `#`,
    /// `*`, backtick, bracket, etc.) — so preview mode can strip them.
    static let isMarkdownSyntax = NSAttributedString.Key("readerMarkdownSyntax")
}

/// Produces a rendered view of a markdown source. Runs the styler, then
/// removes every range the styler flagged as a syntax marker. Links keep
/// their label text; URL parts disappear. Code fences disappear; code
/// contents remain monospace.
enum MarkdownPreview {
    static func render(_ source: String) -> NSAttributedString {
        let storage = NSTextStorage(string: source)
        MarkdownStyler().restyle(storage)

        // Walk the storage in reverse, deleting marker ranges as we go so
        // earlier indices stay valid.
        let full = NSRange(location: 0, length: storage.length)
        var markerRanges: [NSRange] = []
        storage.enumerateAttribute(.isMarkdownSyntax, in: full, options: []) { value, range, _ in
            if (value as? Bool) == true {
                markerRanges.append(range)
            }
        }
        for range in markerRanges.reversed() {
            storage.deleteCharacters(in: range)
        }
        return storage
    }
}
