import XCTest
import AppKit
@testable import Reader

/// Ground-truth invariant: the styler *only* layers attributes. The character
/// content of the storage must never change. That is what makes copy/paste
/// lossless by construction.
final class MarkdownStylerTests: XCTestCase {
    func testStylerPreservesSourceExactly() {
        let cases = [
            "Plain paragraph.",
            "# Heading one",
            "## Heading **with bold** and *italic*",
            "A sentence with `inline code` in it.",
            "```\nlet x = 1\nprint(x)\n```",
            "- one\n- two\n- three",
            "1. first\n2. second",
            "> A quotation\n> continues here.",
            "[label](https://example.com)",
            "~~strikethrough~~ text",
            "---",
            "mixed **bold** and *italic* and `code` and [link](x) together",
        ]
        for source in cases {
            let storage = NSTextStorage(string: source)
            MarkdownStyler().restyle(storage)
            XCTAssertEqual(
                storage.string, source,
                "Styler mutated source characters for input:\n\(source)"
            )
        }
    }

    func testBoldIsNotAlsoItalic() {
        // **bold** must apply bold but NOT italic. The italic regex used to
        // match the outer `*...*` pair, double-applying italic on top of bold.
        let storage = NSTextStorage(string: "start **very bold** end")
        MarkdownStyler().restyle(storage)
        let inside = ((storage.string as NSString).range(of: "very bold")).location + 2
        let font = storage.attribute(.font, at: inside, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(font)
        let traits = NSFontManager.shared.traits(of: font!)
        XCTAssertTrue(traits.contains(.boldFontMask))
        XCTAssertFalse(
            traits.contains(.italicFontMask),
            "**bold** must not be italicised"
        )
    }

    func testItalicAloneAppliesItalicOnly() {
        let storage = NSTextStorage(string: "start *emph* end")
        MarkdownStyler().restyle(storage)
        let inside = ((storage.string as NSString).range(of: "emph")).location
        let font = storage.attribute(.font, at: inside, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(font)
        let traits = NSFontManager.shared.traits(of: font!)
        XCTAssertTrue(traits.contains(.italicFontMask))
        XCTAssertFalse(traits.contains(.boldFontMask))
    }

    func testStylerAppliesBoldFont() {
        let storage = NSTextStorage(string: "hello **world** there")
        MarkdownStyler().restyle(storage)
        let boldRange = ((storage.string as NSString).range(of: "**world**"))
        let font = storage.attribute(.font, at: boldRange.location + 2, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(font)
        XCTAssertTrue(
            NSFontManager.shared.traits(of: font!).contains(.boldFontMask),
            "Expected bold trait inside **world**"
        )
    }

    func testHeadingGetsLargerFont() {
        let storage = NSTextStorage(string: "# Big\n\nbody")
        MarkdownStyler().restyle(storage)
        let headingFont = storage.attribute(.font, at: 3, effectiveRange: nil) as? NSFont
        let bodyFont = storage.attribute(.font, at: storage.length - 1, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(headingFont)
        XCTAssertNotNil(bodyFont)
        XCTAssertGreaterThan(headingFont!.pointSize, bodyFont!.pointSize)
    }

    func testLinkAttributeIsPresent() {
        let storage = NSTextStorage(string: "see [site](https://example.com) now")
        MarkdownStyler().restyle(storage)
        let linkRange = (storage.string as NSString).range(of: "site")
        let link = storage.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL
        XCTAssertEqual(link?.absoluteString, "https://example.com")
    }

    func testCodeSpanSuppressesInlineEmphasis() {
        // Inside `code`, the ** and * should NOT produce bold/italic.
        let storage = NSTextStorage(string: "ok `**not bold**` ok")
        MarkdownStyler().restyle(storage)
        // Sample the middle of the code span — should be monospace, not bold.
        let codeRange = (storage.string as NSString).range(of: "**not bold**")
        let font = storage.attribute(.font, at: codeRange.location + 3, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(font)
        XCTAssertTrue(
            font!.fontDescriptor.symbolicTraits.contains(.monoSpace),
            "Expected monospace inside code span"
        )
        XCTAssertFalse(
            NSFontManager.shared.traits(of: font!).contains(.boldFontMask),
            "Bold should not apply inside a code span"
        )
    }

    func testStylerDoesNotHangOnIncompleteHeading() {
        // Three hashes with no content — styler must return quickly even
        // though the heading regex can't fully match.
        let cases = ["#", "##", "###", "####", "#####", "######", "# ", "### "]
        for source in cases {
            let storage = NSTextStorage(string: source)
            let start = Date()
            MarkdownStyler().restyle(storage)
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(elapsed, 0.5, "Styler took \(elapsed)s on \"\(source)\"")
            XCTAssertEqual(storage.string, source)
        }
    }

    func testStylerHandlesRepeatedKeystrokes() {
        // Simulate building up "### " one character at a time and running
        // the styler after each keystroke.
        let start = Date()
        for length in 1...200 {
            let source = String(repeating: "#", count: length)
            let storage = NSTextStorage(string: source)
            MarkdownStyler().restyle(storage)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
    }

    func testFencedCodeBlockIsMonospace() {
        let source = "text\n\n```\nfoo bar\n```\n\nmore"
        let storage = NSTextStorage(string: source)
        MarkdownStyler().restyle(storage)
        let codeRange = (storage.string as NSString).range(of: "foo bar")
        let font = storage.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(font)
        XCTAssertTrue(
            font!.fontDescriptor.symbolicTraits.contains(.monoSpace)
        )
    }
}
