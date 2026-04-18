import AppKit

/// Applies markdown-aware typographic styling directly to an `NSTextStorage`
/// without altering its characters. The markdown source remains the ground
/// truth; attributes are layered on top so copy/paste round-trips losslessly.
final class MarkdownStyler {
    private let fenced = try! NSRegularExpression(
        pattern: "(^|\\n)(```[^\\n]*\\n[\\s\\S]*?\\n```)(?=\\n|$)",
        options: []
    )
    private let indentedCode = try! NSRegularExpression(
        pattern: "(?m)^(    |\\t)(.+)$",
        options: []
    )
    private let inlineCode = try! NSRegularExpression(
        pattern: "`([^`\\n]+)`",
        options: []
    )
    private let heading = try! NSRegularExpression(
        pattern: "(?m)^(#{1,6})(\\s+)([^\\n]+)$",
        options: []
    )
    private let blockquote = try! NSRegularExpression(
        pattern: "(?m)^(>\\s*)(.*)$",
        options: []
    )
    private let listItem = try! NSRegularExpression(
        pattern: "(?m)^(\\s*)([-*+]|\\d+\\.)(\\s+)(.+)$",
        options: []
    )
    private let hr = try! NSRegularExpression(
        pattern: "(?m)^(-{3,}|\\*{3,}|_{3,})\\s*$",
        options: []
    )
    private let bold = try! NSRegularExpression(
        pattern: "(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1",
        options: [.dotMatchesLineSeparators]
    )
    // Italic must NOT match the `*...*` pieces of `**bold**`. Require the
    // asterisk (or underscore) to have a non-marker, non-word boundary on
    // each side, and forbid the marker character from appearing in the
    // content. Stars and underscores each get their own pattern so the
    // "no other marker in content" rule is unambiguous.
    private let italicStar = try! NSRegularExpression(
        pattern: "(?<![*\\w])\\*(?=\\S)([^*\\n]+?)(?<=\\S)\\*(?![*\\w])",
        options: []
    )
    private let italicUnder = try! NSRegularExpression(
        pattern: "(?<![_\\w])_(?=\\S)([^_\\n]+?)(?<=\\S)_(?![_\\w])",
        options: []
    )
    private let strike = try! NSRegularExpression(
        pattern: "~~(?=\\S)([^\\n]+?)(?<=\\S)~~",
        options: []
    )
    private let link = try! NSRegularExpression(
        pattern: "\\[([^\\]\\n]+)\\]\\(([^)\\n]+)\\)",
        options: []
    )

    func restyle(_ storage: NSTextStorage) {
        let text = storage.string as NSString
        let full = NSRange(location: 0, length: text.length)
        guard full.length > 0 else { return }

        storage.setAttributes(baseAttributes(), range: full)

        let codeRanges = NSMutableIndexSet()

        applyFencedCode(in: storage, text: text, full: full, codeRanges: codeRanges)
        applyIndentedCode(in: storage, text: text, full: full, codeRanges: codeRanges)
        applyInlineCode(in: storage, text: text, full: full, codeRanges: codeRanges)

        applyHeadings(in: storage, text: text, full: full, codeRanges: codeRanges)
        applyBlockquotes(in: storage, text: text, full: full, codeRanges: codeRanges)
        applyLists(in: storage, text: text, full: full, codeRanges: codeRanges)
        applyHR(in: storage, text: text, full: full, codeRanges: codeRanges)

        applyBold(in: storage, text: text, full: full, codeRanges: codeRanges)
        applyItalic(in: storage, text: text, full: full, codeRanges: codeRanges)
        applyStrike(in: storage, text: text, full: full, codeRanges: codeRanges)
        applyLinks(in: storage, text: text, full: full, codeRanges: codeRanges)
    }

    // MARK: - Base

    func baseAttributes() -> [NSAttributedString.Key: Any] {
        let body = Theme.bodyFont.pointSize
        let para = NSMutableParagraphStyle()
        // Use `lineSpacing` (extra leading between lines) rather than
        // `lineHeightMultiple` (which inflates the whole line box). This
        // keeps the caret at natural font height instead of being stretched
        // to fit an enlarged line box.
        para.lineSpacing = body * Theme.extraLeadingRatio
        para.paragraphSpacing = body * 0.55
        para.alignment = .natural
        return [
            .font: Theme.bodyFont,
            .foregroundColor: Theme.textColor,
            .paragraphStyle: para,
        ]
    }

    private func overlaps(_ range: NSRange, _ set: NSIndexSet) -> Bool {
        set.intersects(in: range)
    }

    private func markOccupied(_ range: NSRange, _ set: NSMutableIndexSet) {
        set.add(in: range)
    }

    // MARK: - Block: Code

    private func applyFencedCode(
        in storage: NSTextStorage,
        text: NSString,
        full: NSRange,
        codeRanges: NSMutableIndexSet
    ) {
        fenced.enumerateMatches(in: storage.string, options: [], range: full) { match, _, _ in
            guard let match = match else { return }
            let blockRange = match.range(at: 2)
            storage.addAttributes(
                [
                    .font: Theme.codeFont,
                    .foregroundColor: Theme.textColor,
                    .backgroundColor: Theme.codeBackground,
                ],
                range: blockRange
            )
            self.markOccupied(blockRange, codeRanges)
        }
    }

    private func applyIndentedCode(
        in storage: NSTextStorage,
        text: NSString,
        full: NSRange,
        codeRanges: NSMutableIndexSet
    ) {
        indentedCode.enumerateMatches(in: storage.string, options: [], range: full) { match, _, _ in
            guard let match = match else { return }
            let lineRange = match.range
            if self.overlaps(lineRange, codeRanges) { return }
            storage.addAttributes(
                [
                    .font: Theme.codeFont,
                    .backgroundColor: Theme.codeBackground,
                ],
                range: lineRange
            )
            self.markOccupied(lineRange, codeRanges)
        }
    }

    private func applyInlineCode(
        in storage: NSTextStorage,
        text: NSString,
        full: NSRange,
        codeRanges: NSMutableIndexSet
    ) {
        inlineCode.enumerateMatches(in: storage.string, options: [], range: full) { match, _, _ in
            guard let match = match else { return }
            let whole = match.range
            if self.overlaps(whole, codeRanges) { return }
            let inner = match.range(at: 1)
            storage.addAttributes(
                [
                    .font: Theme.codeFont,
                    .backgroundColor: Theme.codeBackground,
                ],
                range: whole
            )
            // dim the tick marks
            let leftTick = NSRange(location: whole.location, length: 1)
            let rightTick = NSRange(location: whole.location + whole.length - 1, length: 1)
            storage.addAttributes([
                .foregroundColor: Theme.syntaxColor,
                .isMarkdownSyntax: true,
            ], range: leftTick)
            storage.addAttributes([
                .foregroundColor: Theme.syntaxColor,
                .isMarkdownSyntax: true,
            ], range: rightTick)
            storage.addAttribute(.foregroundColor, value: Theme.textColor, range: inner)
            self.markOccupied(whole, codeRanges)
        }
    }

    // MARK: - Block: Structure

    private func applyHeadings(
        in storage: NSTextStorage,
        text: NSString,
        full: NSRange,
        codeRanges: NSMutableIndexSet
    ) {
        heading.enumerateMatches(in: storage.string, options: [], range: full) { match, _, _ in
            guard let match = match else { return }
            let whole = match.range
            if self.overlaps(whole, codeRanges) { return }
            let hashes = match.range(at: 1)
            let level = hashes.length
            let font = Theme.headingFont(level: level)

            storage.addAttribute(.font, value: font, range: whole)
            storage.addAttributes([
                .foregroundColor: Theme.syntaxColor,
                .isMarkdownSyntax: true,
            ], range: hashes)
            // leading space after hashes — also part of the marker, strip in preview
            let space = match.range(at: 2)
            storage.addAttributes([
                .foregroundColor: Theme.syntaxColor,
                .isMarkdownSyntax: true,
            ], range: space)

            let para = NSMutableParagraphStyle()
            let headingSize = font.pointSize
            para.lineSpacing = headingSize * 0.12
            // Bringhurst §8.1 — more air above a heading than below it; the
            // reader needs a moment of silence before the new section begins.
            para.paragraphSpacingBefore = headingSize * 1.1
            para.paragraphSpacing = headingSize * 0.35
            para.alignment = .natural
            storage.addAttribute(.paragraphStyle, value: para, range: whole)
        }
    }

    private func applyBlockquotes(
        in storage: NSTextStorage,
        text: NSString,
        full: NSRange,
        codeRanges: NSMutableIndexSet
    ) {
        blockquote.enumerateMatches(in: storage.string, options: [], range: full) { match, _, _ in
            guard let match = match else { return }
            let whole = match.range
            if self.overlaps(whole, codeRanges) { return }
            let marker = match.range(at: 1)
            storage.addAttributes([
                .foregroundColor: Theme.syntaxColor,
                .isMarkdownSyntax: true,
            ], range: marker)
            storage.addAttribute(.foregroundColor, value: Theme.secondaryColor, range: whole)
            let italicFont = NSFontManager.shared.convert(Theme.bodyFont, toHaveTrait: .italicFontMask)
            storage.addAttribute(.font, value: italicFont, range: match.range(at: 2))

            let para = NSMutableParagraphStyle()
            para.lineSpacing = Theme.bodyFont.pointSize * Theme.extraLeadingRatio
            // Block-quote indent — Bringhurst §2.3.4: quotations are "set off
            // from the main text by space or by indention or both." Both
            // first line and wrapped lines sit at ~1.5em so the `>` marker
            // and its content shift right as a whole.
            let indent = Theme.bodyFont.pointSize * 1.5
            para.firstLineHeadIndent = indent
            para.headIndent = indent
            para.paragraphSpacing = Theme.bodyFont.pointSize * 0.3
            storage.addAttribute(.paragraphStyle, value: para, range: whole)
        }
    }

    private func applyLists(
        in storage: NSTextStorage,
        text: NSString,
        full: NSRange,
        codeRanges: NSMutableIndexSet
    ) {
        listItem.enumerateMatches(in: storage.string, options: [], range: full) { match, _, _ in
            guard let match = match else { return }
            let whole = match.range
            if self.overlaps(whole, codeRanges) { return }
            let marker = match.range(at: 2)
            // Preserve the bullet/number as a rendered glyph in preview — only
            // strip the trailing space if desired. Keeping the marker keeps
            // list structure legible without markdown syntax.
            storage.addAttribute(.foregroundColor, value: Theme.syntaxColor, range: marker)

            // Hanging indent: wrapped lines align with the text, not the marker.
            let para = NSMutableParagraphStyle()
            para.lineSpacing = Theme.bodyFont.pointSize * Theme.extraLeadingRatio
            para.firstLineHeadIndent = 0
            para.headIndent = Theme.bodyFont.pointSize * 1.4
            para.paragraphSpacing = Theme.bodyFont.pointSize * 0.15
            storage.addAttribute(.paragraphStyle, value: para, range: whole)
        }
    }

    private func applyHR(
        in storage: NSTextStorage,
        text: NSString,
        full: NSRange,
        codeRanges: NSMutableIndexSet
    ) {
        hr.enumerateMatches(in: storage.string, options: [], range: full) { match, _, _ in
            guard let match = match else { return }
            let whole = match.range
            if self.overlaps(whole, codeRanges) { return }
            storage.addAttribute(.foregroundColor, value: Theme.quaternaryColor, range: whole)
        }
    }

    // MARK: - Inline

    private func applyBold(
        in storage: NSTextStorage,
        text: NSString,
        full: NSRange,
        codeRanges: NSMutableIndexSet
    ) {
        bold.enumerateMatches(in: storage.string, options: [], range: full) { match, _, _ in
            guard let match = match else { return }
            let whole = match.range
            if self.overlaps(whole, codeRanges) { return }
            let currentFont = storage.attribute(.font, at: whole.location, effectiveRange: nil) as? NSFont ?? Theme.bodyFont
            let boldFont = NSFontManager.shared.convert(currentFont, toHaveTrait: .boldFontMask)
            storage.addAttribute(.font, value: boldFont, range: whole)
            let leftMark = NSRange(location: whole.location, length: 2)
            let rightMark = NSRange(location: whole.location + whole.length - 2, length: 2)
            storage.addAttributes([
                .foregroundColor: Theme.syntaxColor,
                .isMarkdownSyntax: true,
            ], range: leftMark)
            storage.addAttributes([
                .foregroundColor: Theme.syntaxColor,
                .isMarkdownSyntax: true,
            ], range: rightMark)
        }
    }

    private func applyItalic(
        in storage: NSTextStorage,
        text: NSString,
        full: NSRange,
        codeRanges: NSMutableIndexSet
    ) {
        for regex in [italicStar, italicUnder] {
            regex.enumerateMatches(in: storage.string, options: [], range: full) { match, _, _ in
                guard let match = match else { return }
                let whole = match.range
                if self.overlaps(whole, codeRanges) { return }
                let currentFont = storage.attribute(.font, at: whole.location, effectiveRange: nil) as? NSFont ?? Theme.bodyFont
                let italicFont = NSFontManager.shared.convert(currentFont, toHaveTrait: .italicFontMask)
                storage.addAttribute(.font, value: italicFont, range: whole)
                let leftMark = NSRange(location: whole.location, length: 1)
                let rightMark = NSRange(location: whole.location + whole.length - 1, length: 1)
                storage.addAttributes([
                    .foregroundColor: Theme.syntaxColor,
                    .isMarkdownSyntax: true,
                ], range: leftMark)
                storage.addAttributes([
                    .foregroundColor: Theme.syntaxColor,
                    .isMarkdownSyntax: true,
                ], range: rightMark)
            }
        }
    }

    private func applyStrike(
        in storage: NSTextStorage,
        text: NSString,
        full: NSRange,
        codeRanges: NSMutableIndexSet
    ) {
        strike.enumerateMatches(in: storage.string, options: [], range: full) { match, _, _ in
            guard let match = match else { return }
            let whole = match.range
            if self.overlaps(whole, codeRanges) { return }
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: whole)
            let leftMark = NSRange(location: whole.location, length: 2)
            let rightMark = NSRange(location: whole.location + whole.length - 2, length: 2)
            storage.addAttributes([
                .foregroundColor: Theme.syntaxColor,
                .isMarkdownSyntax: true,
            ], range: leftMark)
            storage.addAttributes([
                .foregroundColor: Theme.syntaxColor,
                .isMarkdownSyntax: true,
            ], range: rightMark)
        }
    }

    private func applyLinks(
        in storage: NSTextStorage,
        text: NSString,
        full: NSRange,
        codeRanges: NSMutableIndexSet
    ) {
        link.enumerateMatches(in: storage.string, options: [], range: full) { match, _, _ in
            guard let match = match else { return }
            let whole = match.range
            if self.overlaps(whole, codeRanges) { return }
            let label = match.range(at: 1)
            let urlRange = match.range(at: 2)
            let urlString = text.substring(with: urlRange)
            storage.addAttribute(.foregroundColor, value: Theme.linkColor, range: label)
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: label)
            // The URL portion — stripped entirely in preview.
            storage.addAttributes([
                .foregroundColor: Theme.syntaxColor,
                .isMarkdownSyntax: true,
            ], range: urlRange)
            let openBracket = NSRange(location: whole.location, length: 1)
            let closeBracketOpenParen = NSRange(location: label.location + label.length, length: 2)
            let closeParen = NSRange(location: whole.location + whole.length - 1, length: 1)
            for r in [openBracket, closeBracketOpenParen, closeParen] {
                storage.addAttributes([
                    .foregroundColor: Theme.syntaxColor,
                    .isMarkdownSyntax: true,
                ], range: r)
            }
            if let url = URL(string: urlString.trimmingCharacters(in: .whitespaces)) {
                storage.addAttribute(.link, value: url, range: label)
            }
        }
    }
}
