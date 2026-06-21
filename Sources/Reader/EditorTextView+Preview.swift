import AppKit

/// Preview-mode state transitions. The source markdown is preserved on
/// entry and restored verbatim on exit; the caret returns to its
/// pre-preview position so the writer lands back where they were drafting.
extension EditorTextView {
    /// Toggle between editing (markdown source visible) and preview (markers
    /// hidden, read-only).
    @objc func togglePreview(_ sender: Any?) {
        if isPreviewing { exitPreview() } else { enterPreview() }
    }

    func enterPreview() {
        guard !isPreviewing, let storage = textStorage else { return }
        let source = storage.string
        sourceBeforePreview = source
        sourceCursorBeforePreview = selectedRange().location
        isRestyling = true
        storage.setAttributedString(MarkdownPreview.render(source))
        isRestyling = false
        // Rendered text is shorter than source (markers stripped) — a
        // selection that lived past the new end would raise NSRangeException
        // the moment anything tried to line-range the caret.
        setSelectedRange(NSRange(
            location: min(sourceCursorBeforePreview, storage.length),
            length: 0
        ))
        isEditable = false
        isSelectable = true
        NotificationCenter.default.post(name: .editorPreviewModeDidChange, object: self)
    }

    func exitPreview() {
        guard let source = sourceBeforePreview, let storage = textStorage else { return }
        sourceBeforePreview = nil
        isRestyling = true
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: source)
        isRestyling = false
        isEditable = true
        reapplyStyling()
        // Restore the *source* cursor — not whatever offset the user clicked
        // to in the preview (different character-count, would land in the
        // wrong place).
        setSelectedRange(NSRange(
            location: min(sourceCursorBeforePreview, storage.length),
            length: 0
        ))
        // typingAttributes can hold stale attributes (e.g. list paragraph
        // style) inherited from the rendered text; reset to base so the
        // next keystroke types plain paragraph text.
        typingAttributes = styler.baseAttributes()
        NotificationCenter.default.post(name: .editorPreviewModeDidChange, object: self)
    }
}
