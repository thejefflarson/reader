import AppKit

/// Format-toggle actions wired up to the bottom bar buttons and Format
/// menu. Each toggle mutates the markdown source — wrapping the selection
/// in markers, replacing or stripping a line prefix — and lets the styler
/// catch up on the next pass.
extension EditorTextView {

    // MARK: - Inline wrap toggles

    @objc func toggleBold(_ sender: Any?) { wrapSelection(with: "**") }
    @objc func toggleItalic(_ sender: Any?) { wrapSelection(with: "*") }
    @objc func toggleStrike(_ sender: Any?) { wrapSelection(with: "~~") }
    @objc func toggleCode(_ sender: Any?) { wrapSelection(with: "`") }

    @objc func insertLink(_ sender: Any?) {
        let range = safeRange(selectedRange())
        let selected = (string as NSString).substring(with: range)
        let label = selected.isEmpty ? "text" : selected
        let replacement = "[\(label)](url)"
        insertText(replacement, replacementRange: range)
        // Select `url` so the user can paste immediately.
        let offset = range.location + label.count + 3 // len("[") + label + "]("
        setSelectedRange(NSRange(location: offset, length: 3))
    }

    // MARK: - Block toggles

    @objc func applyHeading1(_ sender: Any?) { setHeading(level: 1) }
    @objc func applyHeading2(_ sender: Any?) { setHeading(level: 2) }
    @objc func applyHeading3(_ sender: Any?) { setHeading(level: 3) }
    @objc func applyHeading0(_ sender: Any?) { setHeading(level: 0) }

    @objc func toggleUnorderedList(_ sender: Any?) { togglePrefix("- ") }
    @objc func toggleBlockquote(_ sender: Any?) { togglePrefix("> ") }

    // MARK: - Wrap / unwrap selection in marker pair

    private func wrapSelection(with marker: String) {
        let range = safeRange(selectedRange())
        let ns = string as NSString
        if range.length == 0 {
            let insert = marker + marker
            insertText(insert, replacementRange: range)
            setSelectedRange(NSRange(location: range.location + marker.count, length: 0))
            return
        }
        let selected = ns.substring(with: range)
        let markerLen = marker.count
        if selected.hasPrefix(marker) && selected.hasSuffix(marker) && selected.count >= 2 * markerLen {
            let stripped = String(selected.dropFirst(markerLen).dropLast(markerLen))
            insertText(stripped, replacementRange: range)
            setSelectedRange(NSRange(location: range.location, length: (stripped as NSString).length))
        } else {
            let wrapped = marker + selected + marker
            insertText(wrapped, replacementRange: range)
            setSelectedRange(NSRange(location: range.location + markerLen, length: (selected as NSString).length))
        }
    }

    private func setHeading(level: Int) {
        let ns = string as NSString
        let lineRange = ns.lineRange(for: safeRange(selectedRange()))
        var line = ns.substring(with: lineRange)
        var trailingNewline = ""
        if line.hasSuffix("\n") {
            trailingNewline = "\n"
            line = String(line.dropLast())
        }
        let trimmed = line.replacingOccurrences(
            of: "^#{1,6}\\s+",
            with: "",
            options: .regularExpression
        )
        let replacement: String
        if level == 0 {
            replacement = trimmed + trailingNewline
        } else {
            let hashes = String(repeating: "#", count: level)
            replacement = "\(hashes) \(trimmed)\(trailingNewline)"
        }
        insertText(replacement, replacementRange: lineRange)
    }

    private func togglePrefix(_ prefix: String) {
        let ns = string as NSString
        let range = safeRange(selectedRange())
        let lineRange = ns.lineRange(for: range)
        var line = ns.substring(with: lineRange)
        var trailingNewline = ""
        if line.hasSuffix("\n") {
            trailingNewline = "\n"
            line = String(line.dropLast())
        }
        let replacement: String
        if line.hasPrefix(prefix) {
            replacement = String(line.dropFirst(prefix.count)) + trailingNewline
        } else {
            replacement = prefix + line + trailingNewline
        }
        insertText(replacement, replacementRange: lineRange)
    }

    // MARK: - Smart newline (continue lists & blockquotes)

    override func insertNewline(_ sender: Any?) {
        let ns = string as NSString
        let caret = safeRange(selectedRange()).location
        let lineStart = ns.lineRange(for: NSRange(location: caret, length: 0)).location
        let currentLine = ns.substring(with: NSRange(location: lineStart, length: caret - lineStart))

        if let continuation = listContinuation(for: currentLine) {
            // Empty list item? Break out of the list.
            if currentLine.trimmingCharacters(in: .whitespaces)
                == continuation.trimmingCharacters(in: .whitespaces) {
                let lineRange = NSRange(location: lineStart, length: caret - lineStart)
                insertText("\n", replacementRange: lineRange)
                return
            }
            super.insertNewline(sender)
            insertText(continuation, replacementRange: selectedRange())
            return
        }
        super.insertNewline(sender)
    }

    /// Returns the list/quote prefix to insert on the next line, or nil if
    /// the current line doesn't warrant continuation. Ordered lists get the
    /// next sequential number; bullet lists and blockquotes get the same
    /// prefix verbatim.
    private func listContinuation(for line: String) -> String? {
        if let range = line.range(of: "^(\\s*)[-*+]\\s+", options: .regularExpression) {
            return String(line[range])
        }
        if let regex = try? NSRegularExpression(pattern: "^(\\s*)(\\d+)(\\.\\s+)"),
           let match = regex.firstMatch(
            in: line,
            range: NSRange(location: 0, length: (line as NSString).length)
           ) {
            let ns = line as NSString
            let indent = ns.substring(with: match.range(at: 1))
            let n = Int(ns.substring(with: match.range(at: 2))) ?? 1
            let tail = ns.substring(with: match.range(at: 3))
            return "\(indent)\(n + 1)\(tail)"
        }
        if let range = line.range(of: "^(\\s*)>\\s*", options: .regularExpression) {
            return String(line[range])
        }
        return nil
    }
}
