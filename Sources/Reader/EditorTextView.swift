import AppKit

/// Notification posted whenever the editor finishes applying styles, so
/// chrome (status bar, window title) can react to word count / dirty state.
extension Notification.Name {
    static let editorTextDidChange = Notification.Name("editorTextDidChange")
    static let editorSelectionDidChange = Notification.Name("editorSelectionDidChange")
}

/// What markdown formats the caret currently sits inside.
struct EditorFormatState: Equatable {
    var bold = false
    var italic = false
    var code = false
    var heading = false
    var list = false
    var quote = false
    var link = false
}

/// The WYSIWYG markdown editor. The underlying string is always pure
/// markdown — styling is layered on as attributes so copy/paste produces
/// the exact markdown source with zero round-trip loss.
final class EditorTextView: NSTextView, NSTextStorageDelegate {
    private let styler = MarkdownStyler()
    private var isRestyling = false
    private var isSubstituting = false
    private var sourceBeforePreview: String?

    var isPreviewing: Bool { sourceBeforePreview != nil }

    /// The underlying markdown source, regardless of mode.
    var markdownSource: String? { sourceBeforePreview }

    override init(frame: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frame, textContainer: container)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        isRichText = false
        importsGraphics = false
        allowsImageEditing = false
        // Every automatic text-processing feature off. Reader owns all text
        // transformations via `SmartSubstitutions`. The system autocomplete
        // panel in particular will eat keystrokes after a run of repeated
        // characters (e.g. `###`) if left on.
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        smartInsertDeleteEnabled = false
        allowsUndo = true
        usesFontPanel = false
        usesRuler = false
        usesFindBar = true
        isIncrementalSearchingEnabled = true

        backgroundColor = Theme.editorBackground
        drawsBackground = true
        insertionPointColor = NSColor.controlAccentColor
        textColor = Theme.textColor
        font = Theme.bodyFont
        textContainerInset = NSSize(width: 0, height: 0)

        typingAttributes = styler.baseAttributes()

        textStorage?.delegate = self

        // Accent-tinted selection at low alpha — Victor's "this is yours."
        selectedTextAttributes = [
            .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.22)
        ]
    }

    // macOS 14+ renders the caret via a separate `NSTextInsertionIndicator`
    // view, so overriding `drawInsertionPoint` produces a second cursor.
    // `insertionPointColor` alone is sufficient — the system caret is a
    // tuned, accessible affordance we don't improve by reimplementing.

    // MARK: - Styling

    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        guard !isRestyling else { return }
        isRestyling = true
        styler.restyle(textStorage)
        isRestyling = false
        NotificationCenter.default.post(name: .editorTextDidChange, object: self)
    }

    func reapplyStyling() {
        // In preview mode the storage holds the *rendered* text (markers
        // stripped), not the markdown source — running the styler against
        // it would reset all attributes and leave nothing to re-match.
        guard let storage = textStorage, !isPreviewing else { return }
        isRestyling = true
        styler.restyle(storage)
        isRestyling = false
    }

    // MARK: - Preview mode

    /// Toggle between editing (markdown source visible) and preview (markers
    /// hidden, read-only). The original markdown is preserved; exit restores
    /// it verbatim.
    @objc func togglePreview(_ sender: Any?) {
        if isPreviewing { exitPreview() } else { enterPreview() }
    }

    func enterPreview() {
        guard !isPreviewing, let storage = textStorage else { return }
        let source = storage.string
        sourceBeforePreview = source
        isRestyling = true
        storage.setAttributedString(MarkdownPreview.render(source))
        isRestyling = false
        // Preview text is shorter than source (markers stripped) — any
        // selection that lived past the new end would throw NSRangeException
        // the moment anything tried to line-range the cursor.
        setSelectedRange(NSRange(location: min(selectedRange().location, storage.length), length: 0))
        isEditable = false
        isSelectable = true
        NotificationCenter.default.post(name: .editorTextDidChange, object: self)
    }

    func exitPreview() {
        guard let source = sourceBeforePreview, let storage = textStorage else { return }
        sourceBeforePreview = nil
        isRestyling = true
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: source)
        isRestyling = false
        setSelectedRange(NSRange(location: min(selectedRange().location, storage.length), length: 0))
        isEditable = true
        reapplyStyling()
        NotificationCenter.default.post(name: .editorTextDidChange, object: self)
    }

    override func setSelectedRange(
        _ charRange: NSRange,
        affinity: NSSelectionAffinity,
        stillSelecting: Bool
    ) {
        super.setSelectedRange(charRange, affinity: affinity, stillSelecting: stillSelecting)
        if !stillSelecting {
            NotificationCenter.default.post(name: .editorSelectionDidChange, object: self)
        }
    }

    /// Computes which markdown formats surround the current caret position
    /// (or selection). The bottom bar uses this to burn active controls red.
    ///
    /// Block-level state (heading, list, quote) comes from the line prefix.
    /// Inline state (bold, italic, code, link) comes from counting unbalanced
    /// markdown markers in the line up to the cursor — *not* from font traits,
    /// since a heading line is already drawn bold by its own styling and that
    /// should not light up the Bold toggle.
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

        // Count un-escaped markers before cursor. Odd = cursor is inside a run.
        // For italic we match single `*`/`_` that are NOT part of `**`/`__`.
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

    // MARK: - Smart substitutions

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)

        // Only fire substitutions for single-character commits (typed keys),
        // and never re-enter from within our own substitution replacement.
        guard !isSubstituting else { return }
        guard let inserted = (string as? String) ?? (string as? NSAttributedString)?.string else { return }
        guard inserted.count == 1 else { return }
        guard hasMarkedText() == false else { return } // IME composition
        guard let storage = textStorage else { return }

        let cursor = min(selectedRange().location, storage.length)
        guard let repl = SmartSubstitutions.check(
            after: inserted,
            in: storage.string as NSString,
            at: cursor
        ) else { return }

        // Go through NSText's editing API — it walks the shouldChangeText /
        // didChangeText pipeline and keeps undo coherent. Direct storage
        // mutation here can leave the text view in a wedged state.
        guard shouldChangeText(in: repl.range, replacementString: repl.text) else { return }

        isSubstituting = true
        replaceCharacters(in: repl.range, with: repl.text)
        didChangeText()
        isSubstituting = false
    }

    // MARK: - Copy / Paste (markdown fidelity)

    override func writeSelection(
        to pboard: NSPasteboard,
        types: [NSPasteboard.PasteboardType]
    ) -> Bool {
        guard let storage = textStorage else { return false }
        let range = safeRange(selectedRange())
        guard range.length > 0 else { return false }
        let text = (storage.string as NSString).substring(with: range)
        pboard.clearContents()
        pboard.setString(text, forType: .string)
        return true
    }

    override func readSelection(from pboard: NSPasteboard) -> Bool {
        // Prefer plain text — if the clipboard is markdown-shaped, it
        // *is* markdown and we insert it verbatim. If only rich text is
        // available, fall back to RTF via NSAttributedString's native
        // reader and convert to markdown runs.
        //
        // Note: HTML paste (`NSAttributedString(html:)`) is *not* handled
        // here. Its WebKit-backed parser fetches remote resources and
        // carries the WebKit attack surface (see Docs/security.md §2).
        // For HTML payloads the pasteboard almost always also contains a
        // plain-text representation; we take that path and refuse to
        // parse HTML.
        if let plain = pboard.string(forType: .string) {
            insertText(plain, replacementRange: selectedRange())
            return true
        }
        if let data = pboard.data(forType: .rtf),
           let attr = NSAttributedString(rtf: data, documentAttributes: nil) {
            insertText(MarkdownSerializer.markdown(from: attr), replacementRange: selectedRange())
            return true
        }
        return super.readSelection(from: pboard)
    }

    // MARK: - Formatting shortcuts

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
        // Select "url" so user can paste immediately
        let offset = range.location + label.count + 3 // len("[") + label + "]("
        setSelectedRange(NSRange(location: offset, length: 3))
    }

    @objc func applyHeading1(_ sender: Any?) { setHeading(level: 1) }
    @objc func applyHeading2(_ sender: Any?) { setHeading(level: 2) }
    @objc func applyHeading3(_ sender: Any?) { setHeading(level: 3) }
    @objc func applyHeading0(_ sender: Any?) { setHeading(level: 0) }

    @objc func toggleUnorderedList(_ sender: Any?) { togglePrefix("- ") }
    @objc func toggleBlockquote(_ sender: Any?) { togglePrefix("> ") }

    /// Clamp a range to the text storage's current bounds. NSString's
    /// line/substring methods raise NSRangeException the moment location
    /// exceeds `length`, which can happen transiently if selection state
    /// outlives a storage-shrinking edit.
    private func safeRange(_ range: NSRange) -> NSRange {
        let length = textStorage?.length ?? 0
        let loc = max(0, min(range.location, length))
        let remaining = length - loc
        let len = max(0, min(range.length, remaining))
        return NSRange(location: loc, length: len)
    }

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
        // strip trailing newline
        var trailingNewline = ""
        if line.hasSuffix("\n") {
            trailingNewline = "\n"
            line = String(line.dropLast())
        }
        // remove existing heading marker
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
            // Empty list item? Break out of list.
            if currentLine.trimmingCharacters(in: .whitespaces) == continuation.trimmingCharacters(in: .whitespaces) {
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

    /// Returns the list/quote prefix that should be inserted on the next line,
    /// or nil if the current line doesn't warrant continuation.
    private func listContinuation(for line: String) -> String? {
        let patterns: [(String, (String) -> String)] = [
            ("^(\\s*)([-*+])\\s+", { match in "\(match)" }),
            ("^(\\s*)(\\d+)\\.\\s+", { _ in "" }),
            ("^(\\s*)>\\s*", { match in match }),
        ]
        for (pattern, _) in patterns {
            if let range = line.range(of: pattern, options: .regularExpression) {
                var prefix = String(line[range])
                if pattern.contains("\\d+") {
                    // increment ordered list number
                    let regex = try? NSRegularExpression(pattern: "^(\\s*)(\\d+)(\\.\\s+)")
                    if let match = regex?.firstMatch(in: prefix, range: NSRange(location: 0, length: (prefix as NSString).length)) {
                        let indent = (prefix as NSString).substring(with: match.range(at: 1))
                        let n = Int((prefix as NSString).substring(with: match.range(at: 2))) ?? 1
                        let tail = (prefix as NSString).substring(with: match.range(at: 3))
                        prefix = "\(indent)\(n + 1)\(tail)"
                    }
                }
                return prefix
            }
        }
        return nil
    }
}
