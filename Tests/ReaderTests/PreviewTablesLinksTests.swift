import XCTest
import AppKit
@testable import Reader

/// Preview rendering for tables, footnotes, and link-related markdown.
/// Inline links already render correctly; this suite documents the gaps
/// (tables, footnote references, reference definitions) and locks the
/// fixes once they land.
final class PreviewTablesLinksTests: XCTestCase {

    private func rendered(_ source: String) -> String {
        MarkdownPreview.render(source).string
    }

    // MARK: - Inline links (regression — should already work)

    func testInlineLinkLabelOnlyInPreview() {
        XCTAssertEqual(
            rendered("see [site](https://example.com) now"),
            "see site now"
        )
    }

    func testInlineLinkKeepsLinkAttribute() {
        let attr = MarkdownPreview.render("see [site](https://example.com) now")
        let labelLoc = (attr.string as NSString).range(of: "site").location
        let url = attr.attribute(.link, at: labelLoc, effectiveRange: nil) as? URL
        XCTAssertEqual(url?.absoluteString, "https://example.com",
                       "preview link must stay clickable")
    }

    // MARK: - Tables

    /// Tables in preview are live SwiftUI views embedded as a single
    /// `NSTextAttachment` (TextKit 2 view provider). The attachment
    /// carries the parsed cells so the SwiftUI view can render them.
    private func attachment(in source: String) -> MarkdownTableAttachment? {
        let attr = MarkdownPreview.render(source)
        var found: MarkdownTableAttachment?
        attr.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: attr.length),
            options: []
        ) { value, _, stop in
            if let table = value as? MarkdownTableAttachment {
                found = table
                stop.pointee = true
            }
        }
        return found
    }

    func testTableEmittedAsLiveAttachment() {
        let table = attachment(in: "| a | b |\n|---|---|\n| 1 | 2 |\n")
        XCTAssertNotNil(table, "preview must embed table as an NSTextAttachment")
        XCTAssertEqual(table?.headers, ["a", "b"])
        XCTAssertEqual(table?.rows, [["1", "2"]])
    }

    func testTableAttachmentCarriesAllCells() {
        let table = attachment(in: "| Name | Score |\n|------|-------|\n| Alice | 99 |\n| Bob | 88 |\n")
        XCTAssertEqual(table?.headers, ["Name", "Score"])
        XCTAssertEqual(table?.rows, [["Alice", "99"], ["Bob", "88"]])
    }

    func testTableOccupiesOneAttachmentCharacter() {
        // `NSAttributedString(attachment:)` is a single `U+FFFC` glyph;
        // the surrounding text reflows around it as a block.
        let attr = MarkdownPreview.render("before\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nafter")
        let s = attr.string
        XCTAssertTrue(s.contains("\u{FFFC}"), "expected one attachment character; got: \(s)")
        XCTAssertTrue(s.contains("before"))
        XCTAssertTrue(s.contains("after"))
    }

    // MARK: - Reference definitions (bookkeeping — hide in preview)

    func testReferenceDefinitionHiddenInPreview() {
        let source = "See [the docs][docs].\n\n[docs]: https://example.com\n"
        let out = rendered(source)
        XCTAssertTrue(out.contains("See the docs."),
                      "reference link label must survive; got: \(out)")
        XCTAssertFalse(out.contains("[docs]:"),
                       "reference definition is bookkeeping — must disappear from preview; got: \(out)")
        XCTAssertFalse(out.contains("example.com"),
                       "definition URL must not appear in preview body")
    }

    // MARK: - Footnote references (keep number, drop syntax)

    func testFootnoteReferenceShowsNumberOnlyInPreview() {
        let out = rendered("Newton's apple[^1] fell down.")
        XCTAssertFalse(out.contains("[^1]"),
                       "footnote bracket+caret must be stripped in preview; got: \(out)")
        XCTAssertTrue(out.contains("1"),
                      "footnote number must remain visible (raised, small); got: \(out)")
    }

    // MARK: - Paragraph spacing (collapse blank lines in preview)

    func testParagraphBlankLineCollapsedInPreview() {
        // Markdown source separates paragraphs with a literal blank line.
        // Preview renders them as styled paragraphs — the `\n\n` should
        // collapse to `\n` so the gap comes from paragraph-spacing only,
        // not a stray blank line on top.
        let out = rendered("First.\n\nSecond.\n\nThird.")
        XCTAssertFalse(out.contains("\n\n"),
                       "preview must collapse blank-line paragraph breaks; got: \(out)")
        XCTAssertTrue(out.contains("First.\nSecond.\nThird."),
                      "paragraph content must survive collapse; got: \(out)")
    }

    func testCodeBlockBlankLinesPreservedInPreview() {
        let source = "before\n\n```\nfoo\n\nbar\n```\n\nafter"
        let out = rendered(source)
        XCTAssertTrue(out.contains("foo\n\nbar"),
                      "blank lines INSIDE code blocks must survive collapse; got: \(out)")
    }
}
