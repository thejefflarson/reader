import XCTest
import AppKit
@testable import Reader

/// Round-trips through enterPreview/exitPreview on an EditorTextView and
/// asserts the editor returns to a usable state. The earlier
/// `MarkdownPreviewTests` only exercised the pure render function, missing
/// state-handoff bugs in the toggle path itself.
final class PreviewRoundTripTests: XCTestCase {
    private func makeEditor(_ source: String) -> EditorTextView {
        let container = NSTextContainer(containerSize: NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude))
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        let storage = NSTextStorage(string: "")
        storage.addLayoutManager(layout)
        let editor = EditorTextView(frame: .zero, textContainer: container)
        editor.string = source
        editor.reapplyStyling()
        return editor
    }

    // MARK: - Source preservation

    func testEditPreviewEditPreservesSource() {
        let source = "# Title\n\n- alpha\n- beta\n- gamma\n"
        let editor = makeEditor(source)
        editor.enterPreview()
        editor.exitPreview()
        XCTAssertEqual(editor.string, source, "source must survive a round trip")
    }

    func testManyRoundTripsPreserveSource() {
        let source = "# H\n\n- one\n- two\n\nbody **bold** end"
        let editor = makeEditor(source)
        for _ in 0..<5 {
            editor.enterPreview()
            editor.exitPreview()
        }
        XCTAssertEqual(editor.string, source)
    }

    // MARK: - List preview substitutes glyphs

    func testBulletListShowsBulletGlyphInPreview() {
        let editor = makeEditor("- alpha\n- beta\n")
        editor.enterPreview()
        XCTAssertTrue(editor.string.contains("• alpha"),
                      "expected `• alpha` in preview, got: \(editor.string)")
        XCTAssertTrue(editor.string.contains("• beta"))
        XCTAssertFalse(editor.string.contains("- alpha"))
    }

    func testTaskListShowsCheckboxGlyphsInPreview() {
        let editor = makeEditor("- [ ] todo\n- [x] done\n")
        editor.enterPreview()
        XCTAssertTrue(editor.string.contains("☐ todo"),
                      "expected `☐ todo` in preview, got: \(editor.string)")
        XCTAssertTrue(editor.string.contains("☑ done"),
                      "expected `☑ done` in preview, got: \(editor.string)")
    }

    func testNestedListBulletsAreSubstituted() {
        let editor = makeEditor("- top\n  - nested\n")
        editor.enterPreview()
        XCTAssertTrue(editor.string.contains("• top"))
        XCTAssertTrue(editor.string.contains("  • nested"),
                      "nested indent must survive bullet substitution; got: \(editor.string)")
    }

    func testOrderedListNumbersUnchangedInPreview() {
        let editor = makeEditor("1. one\n2. two\n")
        editor.enterPreview()
        XCTAssertTrue(editor.string.contains("1. one"),
                      "ordered list numbers should stay literal; got: \(editor.string)")
    }

    // MARK: - Editing state after exit

    func testEditableAfterExitPreview() {
        let editor = makeEditor("- alpha\n- beta\n")
        editor.enterPreview()
        editor.exitPreview()
        XCTAssertTrue(editor.isEditable, "must be editable again after exitPreview")
        XCTAssertFalse(editor.isPreviewing)
    }

    func testTypingAttributesAreBaseAfterExit() {
        let editor = makeEditor("- alpha\n")
        editor.enterPreview()
        editor.exitPreview()
        let typingPara = editor.typingAttributes[.paragraphStyle] as? NSParagraphStyle
        XCTAssertEqual(typingPara?.headIndent ?? 0, 0,
                       "typingAttributes must not carry list indent after preview round trip")
    }

    func testListContinuationStillWorksAfterRoundTrip() {
        let source = "- alpha\n- beta"
        let editor = makeEditor(source)
        editor.enterPreview()
        editor.exitPreview()
        editor.setSelectedRange(NSRange(location: editor.string.count, length: 0))
        editor.insertNewline(nil)
        XCTAssertTrue(editor.string.hasSuffix("\n- "),
                      "list continuation broken after preview round trip; got: \(editor.string)")
    }

    // MARK: - Cursor preservation

    func testCursorReturnsToSourcePositionAfterRoundTrip() {
        // Source: `# Title\n\nbody` (length 13). Cursor at position 9 = `b`.
        // In rendered text `Title\n\nbody` (length 11), the same character `b`
        // is at position 7. Naïvely clamping rendered-cursor to source-length
        // on exit lands at 7 — pointing into `Title\n\n` — wrong.
        let editor = makeEditor("# Title\n\nbody")
        editor.setSelectedRange(NSRange(location: 9, length: 0))
        editor.enterPreview()
        editor.exitPreview()
        XCTAssertEqual(editor.selectedRange().location, 9,
                       "cursor must return to its source-side position")
    }

    // MARK: - Preview notification ≠ edit notification

    func testPreviewToggleDoesNotFireEditNotification() {
        let editor = makeEditor("# title\n\nbody")
        var editFired = false
        let token = NotificationCenter.default.addObserver(
            forName: .editorTextDidChange,
            object: editor,
            queue: .main
        ) { _ in editFired = true }
        defer { NotificationCenter.default.removeObserver(token) }

        editor.enterPreview()
        editor.exitPreview()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertFalse(editFired,
                       "preview toggles must not fire editorTextDidChange — that flips the dirty flag")
    }

    func testPreviewToggleFiresPreviewNotification() {
        let editor = makeEditor("# title")
        var fired = 0
        let token = NotificationCenter.default.addObserver(
            forName: .editorPreviewModeDidChange,
            object: editor,
            queue: .main
        ) { _ in fired += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        editor.enterPreview()
        editor.exitPreview()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertEqual(fired, 2, "expected one notification per enter and exit")
    }
}
