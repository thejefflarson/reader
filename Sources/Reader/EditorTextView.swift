import AppKit

/// Notifications posted by the editor. `editorTextDidChange` fires only on
/// genuine content edits (typing, paste, list continuation) — *not* on
/// preview toggles, which mutate the storage but don't change the document.
/// `editorPreviewModeDidChange` fires when preview is entered or exited.
extension Notification.Name {
    static let editorTextDidChange = Notification.Name("editorTextDidChange")
    static let editorSelectionDidChange = Notification.Name("editorSelectionDidChange")
    static let editorPreviewModeDidChange = Notification.Name("editorPreviewModeDidChange")
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
///
/// The class is intentionally narrow: input pipeline (smart substitutions
/// and paste), restyling on mutation, selection-change forwarding. The
/// thicker concerns live in focused extensions:
///   - `EditorTextView+Preview.swift` — enter/exit preview mode.
///   - `EditorTextView+Formatting.swift` — bold/italic/heading/list/quote
///     toggles and the smart-newline list continuation.
///   - `EditorTextView+FormatState.swift` — caret-aware format detection
///     for the bottom-bar buttons.
final class EditorTextView: NSTextView, NSTextStorageDelegate {
    /// Shared with the preview extension to call `baseAttributes()` when
    /// resetting typing attributes after a round trip.
    let styler = MarkdownStyler()

    /// Re-entrance guard for the text-storage delegate. Direct storage
    /// mutations (preview swap, restyle) flip this so the delegate doesn't
    /// re-run the styler against its own output.
    var isRestyling = false

    /// Set when preview mode is active. The string IS the rendered text;
    /// `sourceBeforePreview` carries the original markdown for round-trip.
    var sourceBeforePreview: String?

    /// Caret position in the *source* at the moment preview was entered.
    /// Restored on exit so the user lands back where they were drafting, not
    /// at whatever offset they clicked while reading the preview.
    var sourceCursorBeforePreview = 0

    private var isSubstituting = false

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

    // MARK: - Selection forwarding

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
        // Cap plain-text paste to 1 MB to prevent main-thread stall on restyle().
        let maxPasteChars = 1 * 1024 * 1024
        if let plain = pboard.string(forType: .string), plain.count <= maxPasteChars {
            insertText(plain, replacementRange: selectedRange())
            return true
        }
        // Cap RTF data to 4 MB before handing to NSAttributedString's parser,
        // which allocates memory proportional to the input inside AppKit.
        let maxRTFBytes = 4 * 1024 * 1024
        if let data = pboard.data(forType: .rtf),
           data.count <= maxRTFBytes,
           let attr = NSAttributedString(rtf: data, documentAttributes: nil) {
            insertText(MarkdownSerializer.markdown(from: attr), replacementRange: selectedRange())
            return true
        }
        return super.readSelection(from: pboard)
    }

    // MARK: - Range helpers

    /// Clamp a range to the text storage's current bounds. NSString's
    /// line/substring methods raise NSRangeException the moment location
    /// exceeds `length`, which can happen transiently if selection state
    /// outlives a storage-shrinking edit.
    func safeRange(_ range: NSRange) -> NSRange {
        let length = textStorage?.length ?? 0
        let loc = max(0, min(range.location, length))
        let remaining = length - loc
        let len = max(0, min(range.length, remaining))
        return NSRange(location: loc, length: len)
    }
}
