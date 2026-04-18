import AppKit

/// Hochuli, *Detail in Typography*: the tool silently fixes micro-typography.
/// Butterick, *Practical Typography*: straight quotes are "a problem left over
/// from typewriter days." En dash for ranges, em dash for parenthetical aside.
/// One space after a period. Ellipsis as a single glyph.
///
/// Applied inline as the writer types — never retroactively, so undoing the
/// keystroke cleanly undoes the substitution.
enum SmartSubstitutions {
    /// Called after a character is inserted. Returns an optional replacement
    /// range + text if a substitution should be applied in place of the last
    /// character(s).
    struct Replacement {
        let range: NSRange
        let text: String
    }

    static func check(after insertion: String, in source: NSString, at cursor: Int) -> Replacement? {
        guard !insideCodeSpan(source: source, at: cursor) else { return nil }

        // Three dots → ellipsis
        if insertion == "." && cursor >= 3 {
            let precedingRange = NSRange(location: cursor - 3, length: 3)
            if source.substring(with: precedingRange) == "..." {
                return Replacement(range: precedingRange, text: "…")
            }
        }

        // Three hyphens → em dash. Two hyphens → en dash.
        if insertion == "-" {
            if cursor >= 3 {
                let r = NSRange(location: cursor - 3, length: 3)
                if source.substring(with: r) == "---" {
                    return Replacement(range: r, text: "—")
                }
            }
            if cursor >= 2 {
                let r = NSRange(location: cursor - 2, length: 2)
                if source.substring(with: r) == "--" && !isMarkdownHR(source: source, at: cursor - 2) {
                    return Replacement(range: r, text: "–")
                }
            }
        }

        // Straight double quote → curly
        if insertion == "\"" {
            let openers: CharacterSet = .whitespacesAndNewlines.union(.init(charactersIn: "([{“‘—–"))
            let previous = charBefore(source: source, at: cursor - 1)
            let isOpen = previous == nil || previous!.unicodeScalars.allSatisfy { openers.contains($0) }
            let replacement = isOpen ? "\u{201C}" : "\u{201D}"
            return Replacement(
                range: NSRange(location: cursor - 1, length: 1),
                text: replacement
            )
        }

        // Straight single quote → curly (unless it looks like an apostrophe
        // inside a word like don't, which the "close quote" case handles).
        if insertion == "'" {
            let openers: CharacterSet = .whitespacesAndNewlines.union(.init(charactersIn: "([{\u{2018}\u{201C}—–"))
            let previous = charBefore(source: source, at: cursor - 1)
            let isOpen = previous == nil || previous!.unicodeScalars.allSatisfy { openers.contains($0) }
            let replacement = isOpen ? "\u{2018}" : "\u{2019}"
            return Replacement(
                range: NSRange(location: cursor - 1, length: 1),
                text: replacement
            )
        }

        // Two spaces after sentence punctuation → one space (Butterick).
        if insertion == " " && cursor >= 2 {
            let r = NSRange(location: cursor - 2, length: 2)
            let pair = source.substring(with: r)
            if pair == "  " && cursor >= 3 {
                let beforePair = source.character(at: cursor - 3)
                if let scalar = Unicode.Scalar(beforePair),
                   ".!?".unicodeScalars.contains(scalar) {
                    return Replacement(range: r, text: " ")
                }
            }
        }

        return nil
    }

    private static func charBefore(source: NSString, at index: Int) -> String? {
        guard index >= 1, index <= source.length else { return nil }
        return source.substring(with: NSRange(location: index - 1, length: 1))
    }

    private static func isMarkdownHR(source: NSString, at index: Int) -> Bool {
        // At the start of a line with only hyphens → user is making an <hr>.
        let lineStart = source.lineRange(for: NSRange(location: index, length: 0)).location
        let lineSoFar = source.substring(with: NSRange(location: lineStart, length: index - lineStart))
        return lineSoFar.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func insideCodeSpan(source: NSString, at index: Int) -> Bool {
        // Count backticks on the current line before the cursor. Odd → inside.
        let lineRange = source.lineRange(for: NSRange(location: index, length: 0))
        let prefix = source.substring(with: NSRange(location: lineRange.location, length: index - lineRange.location))
        return prefix.filter { $0 == "`" }.count % 2 == 1
    }
}
