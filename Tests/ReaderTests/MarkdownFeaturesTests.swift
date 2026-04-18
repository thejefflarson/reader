import XCTest
import AppKit
@testable import Reader

/// Coverage tests for the markdown constructs added beyond the first cut:
/// setext headings, images, autolinks, reference links/definitions, task
/// lists, tables, footnotes, hard breaks, escapes. Each test sets up a
/// small input and asserts the styler marks the expected ranges.
final class MarkdownFeaturesTests: XCTestCase {
    private let styler = MarkdownStyler()

    private func styled(_ source: String) -> NSTextStorage {
        let storage = NSTextStorage(string: source)
        styler.restyle(storage)
        return storage
    }

    // MARK: - Setext headings

    func testSetextH1AppliesHeadingFont() {
        let storage = styled("Title\n=====\n\nbody")
        let font = storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(font)
        XCTAssertGreaterThan(font!.pointSize, Theme.bodyFont.pointSize)
    }

    func testSetextH2AppliesHeadingFont() {
        let storage = styled("Subtitle\n-------\n\nbody")
        let font = storage.attribute(.font, at: 3, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(font)
        XCTAssertGreaterThan(font!.pointSize, Theme.bodyFont.pointSize)
    }

    func testSetextH2DoesNotStealThematicBreak() {
        // A lone `---` with no preceding non-empty line should remain a HR.
        let storage = styled("\n---\n")
        let hrLoc = (storage.string as NSString).range(of: "---").location
        let color = storage.attribute(.foregroundColor, at: hrLoc, effectiveRange: nil) as? NSColor
        // HR tint is quaternary (softer than body label).
        XCTAssertNotNil(color)
    }

    // MARK: - Images

    func testImageAltIsDimmedAndBracketsMarkedSyntax() {
        let source = "![Alt text](https://example.com/pic.png)"
        let storage = styled(source)
        let bang = NSRange(location: 0, length: 1)
        let isSyntax = storage.attribute(.isMarkdownSyntax, at: bang.location, effectiveRange: nil) as? Bool
        XCTAssertEqual(isSyntax, true)

        let urlRange = (source as NSString).range(of: "https://example.com/pic.png")
        let urlSyntax = storage.attribute(.isMarkdownSyntax, at: urlRange.location, effectiveRange: nil) as? Bool
        XCTAssertEqual(urlSyntax, true)
    }

    // MARK: - Autolinks

    func testHttpAutolinkBecomesLink() {
        let source = "see <https://anthropic.com> here"
        let storage = styled(source)
        let urlRange = (source as NSString).range(of: "https://anthropic.com")
        let link = storage.attribute(.link, at: urlRange.location, effectiveRange: nil) as? URL
        XCTAssertEqual(link?.absoluteString, "https://anthropic.com")
    }

    func testEmailAutolinkBecomesMailto() {
        let source = "<jeff@example.com>"
        let storage = styled(source)
        let link = storage.attribute(.link, at: 1, effectiveRange: nil) as? URL
        XCTAssertEqual(link?.absoluteString, "mailto:jeff@example.com")
    }

    // MARK: - Task lists

    func testCompletedTaskIsStruckThrough() {
        let storage = styled("- [x] done")
        let contentIdx = (storage.string as NSString).range(of: "done").location
        let strike = storage.attribute(.strikethroughStyle, at: contentIdx, effectiveRange: nil) as? Int
        XCTAssertEqual(strike, NSUnderlineStyle.single.rawValue)
    }

    func testOpenTaskIsNotStruck() {
        let storage = styled("- [ ] todo")
        let contentIdx = (storage.string as NSString).range(of: "todo").location
        let strike = storage.attribute(.strikethroughStyle, at: contentIdx, effectiveRange: nil)
        XCTAssertNil(strike)
    }

    // MARK: - Reference links / definitions

    func testReferenceDefinitionStyling() {
        let source = "[ref]: https://example.com\n"
        let storage = styled(source)
        let colorAtDef = storage.attribute(.foregroundColor, at: 5, effectiveRange: nil) as? NSColor
        XCTAssertNotNil(colorAtDef)
    }

    func testReferenceLinkLabelIsLinkColored() {
        let source = "see [here][ref]"
        let storage = styled(source)
        let labelIdx = (source as NSString).range(of: "here").location
        let color = storage.attribute(.foregroundColor, at: labelIdx, effectiveRange: nil) as? NSColor
        XCTAssertEqual(color, Theme.linkColor)
    }

    // MARK: - Footnotes

    func testFootnoteReferenceIsRaisedSmallLink() {
        let source = "something[^1] else"
        let storage = styled(source)
        let refIdx = (source as NSString).range(of: "[^1]").location
        let baseline = storage.attribute(.baselineOffset, at: refIdx, effectiveRange: nil) as? CGFloat
        XCTAssertEqual(baseline, 3)
    }

    func testFootnoteDefinitionBodyIsItalic() {
        let source = "[^1]: the note"
        let storage = styled(source)
        let bodyIdx = (source as NSString).range(of: "the note").location
        let font = storage.attribute(.font, at: bodyIdx, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(font)
        let traits = NSFontManager.shared.traits(of: font!)
        XCTAssertTrue(traits.contains(.italicFontMask))
    }

    // MARK: - Hard line breaks

    func testHardBreakTrailingSpacesMarked() {
        let source = "line one  \nline two"
        let storage = styled(source)
        let spacesIdx = (source as NSString).range(of: "  \n").location
        let isSyntax = storage.attribute(.isMarkdownSyntax, at: spacesIdx, effectiveRange: nil) as? Bool
        XCTAssertEqual(isSyntax, true)
    }

    // MARK: - Escape sequences

    func testEscapedAsteriskBackslashIsMarkedSyntax() {
        let source = "not \\*bold\\*"
        let storage = styled(source)
        let firstSlash = (source as NSString).range(of: "\\").location
        let isSyntax = storage.attribute(.isMarkdownSyntax, at: firstSlash, effectiveRange: nil) as? Bool
        XCTAssertEqual(isSyntax, true)
    }

    // MARK: - Tables

    func testTableRowIsMonospace() {
        let source = "| a | b |\n| - | - |\n| 1 | 2 |\n"
        let storage = styled(source)
        let font = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(font)
        XCTAssertTrue(font!.fontDescriptor.symbolicTraits.contains(.monoSpace))
    }

    func testTablePipeIsSyntaxMarker() {
        let source = "| a | b |"
        let storage = styled(source)
        let pipeIdx = (source as NSString).range(of: "|").location
        let isSyntax = storage.attribute(.isMarkdownSyntax, at: pipeIdx, effectiveRange: nil) as? Bool
        XCTAssertEqual(isSyntax, true)
    }

    // MARK: - URL scheme allowlist (security)

    func testHttpsLinkIsClickable() {
        let source = "see [here](https://example.com) now"
        let storage = styled(source)
        let labelIdx = (source as NSString).range(of: "here").location
        let link = storage.attribute(.link, at: labelIdx, effectiveRange: nil) as? URL
        XCTAssertEqual(link?.scheme, "https")
    }

    func testFileSchemeLinkIsRefused() {
        let source = "see [root](file:///etc/passwd) now"
        let storage = styled(source)
        let labelIdx = (source as NSString).range(of: "root").location
        let link = storage.attribute(.link, at: labelIdx, effectiveRange: nil)
        XCTAssertNil(link, "file:// scheme must never become clickable")
    }

    func testJavascriptSchemeLinkIsRefused() {
        let source = "see [click](javascript:alert(1)) now"
        let storage = styled(source)
        let labelIdx = (source as NSString).range(of: "click").location
        let link = storage.attribute(.link, at: labelIdx, effectiveRange: nil)
        XCTAssertNil(link)
    }

    func testCustomAppSchemeLinkIsRefused() {
        let source = "see [open](myapp://do-something-bad) now"
        let storage = styled(source)
        let labelIdx = (source as NSString).range(of: "open").location
        let link = storage.attribute(.link, at: labelIdx, effectiveRange: nil)
        XCTAssertNil(link)
    }

    func testMailtoLinkIsClickable() {
        let source = "write [me](mailto:hi@example.com) please"
        let storage = styled(source)
        let labelIdx = (source as NSString).range(of: "me").location
        let link = storage.attribute(.link, at: labelIdx, effectiveRange: nil) as? URL
        XCTAssertEqual(link?.scheme, "mailto")
    }

    func testAutolinkRefusesNonStandardScheme() {
        let source = "<file:///etc/passwd>"
        let storage = styled(source)
        let link = storage.attribute(.link, at: 1, effectiveRange: nil)
        XCTAssertNil(link)
    }
}
