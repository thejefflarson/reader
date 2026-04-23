import XCTest
import AppKit
@testable import Reader

/// Preview rendering is pure transformation — testable without a live
/// NSTextView. The broader interactive paths (keystroke flow, shortcuts)
/// are validated manually; NSTextView's edit pipeline will not run without
/// an NSApplication event loop.
final class MarkdownPreviewTests: XCTestCase {
    func testHeadingMarkersStripped() {
        let rendered = MarkdownPreview.render("# Heading\n\nBody.")
        XCTAssertEqual(rendered.string, "Heading\n\nBody.")
    }

    func testBoldMarkersStripped() {
        let rendered = MarkdownPreview.render("Say **hello** now")
        XCTAssertEqual(rendered.string, "Say hello now")
    }

    func testItalicMarkersStripped() {
        let rendered = MarkdownPreview.render("a *b* c")
        XCTAssertEqual(rendered.string, "a b c")
    }

    func testInlineCodeTicksStripped() {
        let rendered = MarkdownPreview.render("run `cmd` now")
        XCTAssertEqual(rendered.string, "run cmd now")
    }

    func testStrikethroughMarkersStripped() {
        let rendered = MarkdownPreview.render("~~gone~~ kept")
        XCTAssertEqual(rendered.string, "gone kept")
    }

    func testLinkShowsLabelOnlyUrlStripped() {
        let rendered = MarkdownPreview.render("see [site](https://example.com)")
        XCTAssertEqual(rendered.string, "see site")
    }

    func testMixedMarkdownPreview() {
        let source = "## Section\n\n**bold** and *italic* with `code`."
        let rendered = MarkdownPreview.render(source)
        XCTAssertEqual(rendered.string, "Section\n\nbold and italic with code.")
    }

    func testPlainTextPassesThrough() {
        let source = "just a sentence with no markdown."
        let rendered = MarkdownPreview.render(source)
        XCTAssertEqual(rendered.string, source)
    }

    func testFencedCodeFencesStripped() {
        let source = "before\n\n```swift\nlet x = 1\nprint(x)\n```\n\nafter"
        let rendered = MarkdownPreview.render(source).string
        XCTAssertFalse(rendered.contains("```"),
            "preview must strip ``` fences; got: \(rendered)")
        XCTAssertTrue(rendered.contains("let x = 1"))
        XCTAssertTrue(rendered.contains("print(x)"))
    }

    // Regression: preview render must never be empty / negative-length;
    // the rendered length is the selection-clamp ceiling after entering
    // preview, and an out-of-bounds value would crash NSString.lineRange.
    func testPreviewRenderNeverExceedsSource() {
        let sources = [
            "# H", "**x**", "# Heading\n**bold**",
            "a [link](https://example.com) b",
            "`code` and **bold** and *italic*",
        ]
        for source in sources {
            let rendered = MarkdownPreview.render(source).string
            XCTAssertLessThanOrEqual(rendered.count, source.count, "for \(source)")
        }
    }
}
