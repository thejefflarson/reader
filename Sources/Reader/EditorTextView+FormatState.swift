import AppKit

/// Caret-aware format detection. The bottom bar uses this to highlight
/// active controls in the `activeAccent` colour.
///
/// Block-level state (heading, list, quote) comes from the line prefix.
/// Inline state (bold, italic, code) comes from counting unbalanced
/// markdown markers in the line up to the cursor — *not* from font traits,
/// since a heading line is already drawn bold by its own styling and that
/// should not light up the Bold toggle.
extension EditorTextView {
    func currentFormatState() -> EditorFormatState {
        guard let storage = textStorage, storage.length > 0 else {
            return EditorFormatState()
        }
        let length = storage.length
        let cursor = max(0, min(selectedRange().location, length))
        let ns = storage.string as NSString

        let lineRange = ns.lineRange(for: NSRange(location: cursor, length: 0))
        let line = ns.substring(with: lineRange)
        let cursorInLine = min(cursor - lineRange.location, (line as NSString).length)
        let prefix = (line as NSString).substring(to: cursorInLine)

        var state = EditorFormatState()
        state.heading = line.range(of: "^#{1,6}\\s+", options: .regularExpression) != nil
        state.list = line.range(of: "^\\s*([-*+]|\\d+\\.)\\s+", options: .regularExpression) != nil
        state.quote = line.hasPrefix("> ") || line.hasPrefix(">")

        // Count un-escaped markers before the cursor — odd = caret is inside
        // a run. For italic we match single `*`/`_` that aren't part of `**`/`__`.
        state.bold = hasUnbalanced(marker: "**", in: prefix)
            || hasUnbalanced(marker: "__", in: prefix)
        state.italic = hasUnbalancedSingle(marker: "*", in: prefix)
            || hasUnbalancedSingle(marker: "_", in: prefix)
        state.code = hasUnbalanced(marker: "`", in: prefix)

        let probe = cursor == 0 ? 0 : min(cursor - 1, length - 1)
        state.link = storage.attribute(.link, at: probe, effectiveRange: nil) != nil
        return state
    }

    private func hasUnbalanced(marker: String, in text: String) -> Bool {
        guard !marker.isEmpty else { return false }
        let count = text.components(separatedBy: marker).count - 1
        return count % 2 == 1
    }

    private func hasUnbalancedSingle(marker: Character, in text: String) -> Bool {
        // Count lone `*` or `_`, skipping doubled occurrences (those are bold).
        var i = text.startIndex
        var count = 0
        while i < text.endIndex {
            if text[i] == marker {
                let next = text.index(after: i)
                if next < text.endIndex, text[next] == marker {
                    i = text.index(after: next)   // skip the pair
                    continue
                }
                count += 1
            }
            i = text.index(after: i)
        }
        return count % 2 == 1
    }
}
