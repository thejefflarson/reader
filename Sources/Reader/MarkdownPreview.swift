import AppKit
import Markdown

extension NSAttributedString.Key {
    /// Marks a character range as a markdown syntax marker (the literal `#`,
    /// `*`, backtick, bracket, etc.) — so edit mode and preview can identify
    /// them. Preview emits a fresh string with no markers; this flag is
    /// stamped by `MarkdownStyler` purely for edit-mode introspection.
    static let isMarkdownSyntax = NSAttributedString.Key("readerMarkdownSyntax")
}

/// Produces a rendered view of a markdown source by walking the parsed AST
/// and emitting an attributed string with the marker characters omitted,
/// list bullets substituted (`•`, `☐`, `☑`), table pipes converted to
/// box-drawing rules, and blocks separated by a single `\n` (paragraph gap
/// comes from `paragraphSpacing` in the paragraph style, not from blank
/// lines in the rendered text).
enum MarkdownPreview {
    static func render(_ source: String) -> NSAttributedString {
        guard !source.isEmpty else { return NSAttributedString() }
        let document = Document(parsing: source, options: [])
        var renderer = PreviewRenderer()
        let raw = renderer.visit(document)
        let result = NSMutableAttributedString(attributedString: raw)
        // Post-passes: constructs swift-markdown doesn't model, plus the
        // permissive "looks like a table row" pipe substitution that GFM
        // wouldn't accept without a separator line.
        substituteFootnoteReferences(in: result)
        return result
    }
}

// MARK: - Renderer

private struct PreviewRenderer: MarkupVisitor {
    typealias Result = NSAttributedString

    mutating func defaultVisit(_ markup: Markup) -> NSAttributedString {
        return concat(markup.children.map { visit($0) })
    }

    // MARK: Blocks

    mutating func visitDocument(_ document: Document) -> NSAttributedString {
        return joinBlocks(document.children.map { visit($0) })
    }

    mutating func visitHeading(_ heading: Heading) -> NSAttributedString {
        let font = Theme.headingFont(level: heading.level)
        let result = NSMutableAttributedString(attributedString: defaultVisit(heading))
        let full = NSRange(location: 0, length: result.length)
        result.addAttribute(.font, value: font, range: full)
        result.addAttribute(.foregroundColor, value: Theme.textColor, range: full)
        result.addAttribute(
            .paragraphStyle,
            value: previewHeadingParagraphStyle(size: font.pointSize),
            range: full
        )
        return result
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: defaultVisit(paragraph))
        let full = NSRange(location: 0, length: result.length)
        result.addAttributes(prosePreviewAttributes(), range: full)
        return result
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> NSAttributedString {
        let inner = joinBlocks(blockQuote.children.map { visit($0) })
        let result = NSMutableAttributedString(attributedString: inner)
        let full = NSRange(location: 0, length: result.length)
        let italic = NSFontManager.shared.convert(Theme.bodyFont, toHaveTrait: .italicFontMask)
        result.addAttribute(.font, value: italic, range: full)
        result.addAttribute(.foregroundColor, value: Theme.secondaryColor, range: full)
        let para = NSMutableParagraphStyle()
        para.lineSpacing = Theme.bodyFont.pointSize * Theme.extraLeadingRatio
        let indent = Theme.bodyFont.pointSize * 1.5
        para.firstLineHeadIndent = indent
        para.headIndent = indent
        para.paragraphSpacing = Theme.bodyFont.pointSize * 0.3
        result.addAttribute(.paragraphStyle, value: para, range: full)
        return result
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> NSAttributedString {
        var code = codeBlock.code
        if code.hasSuffix("\n") { code.removeLast() }
        let result = NSMutableAttributedString(string: code)
        let full = NSRange(location: 0, length: result.length)
        result.addAttributes(
            [
                .font: Theme.codeFont,
                .foregroundColor: Theme.textColor,
                .backgroundColor: Theme.codeBackground,
                .isCodeBlock: true,
            ],
            range: full
        )
        applyBlockSpanParagraphStyle(to: result, kind: .code)
        return result
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "───")
        let full = NSRange(location: 0, length: result.length)
        result.addAttribute(.foregroundColor, value: Theme.quaternaryColor, range: full)
        result.addAttribute(.font, value: Theme.bodyFont, range: full)
        return result
    }

    mutating func visitUnorderedList(_ list: UnorderedList) -> NSAttributedString {
        let items: [NSAttributedString] = list.listItems.map { renderListItem($0, bullet: nil) }
        return joinBlocks(items)
    }

    mutating func visitOrderedList(_ list: OrderedList) -> NSAttributedString {
        var n = Int(list.startIndex)
        let items: [NSAttributedString] = list.listItems.map { item in
            defer { n += 1 }
            return renderListItem(item, bullet: "\(n). ")
        }
        return joinBlocks(items)
    }

    private mutating func renderListItem(_ item: ListItem, bullet: String?) -> NSAttributedString {
        let glyph: String
        if let checkbox = item.checkbox {
            glyph = checkbox == .checked ? "☑ " : "☐ "
        } else if let bullet = bullet {
            glyph = bullet
        } else {
            glyph = "• "
        }
        let body = NSMutableAttributedString(string: glyph)
        body.addAttributes(prosePreviewAttributes(), range: NSRange(location: 0, length: body.length))
        // Render children in order. Nested lists get a two-space prefix per
        // line so they sit visually under the parent's content.
        var first = true
        for child in item.children {
            if !first { body.append(NSAttributedString(string: "\n")) }
            first = false
            let rendered = visit(child)
            if child is UnorderedList || child is OrderedList {
                body.append(indentLines(rendered, by: "  "))
            } else {
                body.append(rendered)
            }
        }

        let full = NSRange(location: 0, length: body.length)
        let para = NSMutableParagraphStyle()
        para.lineSpacing = Theme.bodyFont.pointSize * Theme.extraLeadingRatio
        para.firstLineHeadIndent = 0
        para.headIndent = Theme.bodyFont.pointSize * (item.checkbox != nil ? 1.8 : 1.4)
        para.paragraphSpacing = Theme.bodyFont.pointSize * 0.15
        body.addAttribute(.paragraphStyle, value: para, range: full)

        if item.checkbox == .checked {
            let after = NSRange(location: glyph.count, length: body.length - glyph.count)
            if after.length > 0 {
                body.addAttribute(
                    .strikethroughStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    range: after
                )
                body.addAttribute(.foregroundColor, value: Theme.secondaryColor, range: after)
            }
        }
        return body
    }

    mutating func visitTable(_ table: Table) -> NSAttributedString {
        // Live SwiftUI table view embedded as an `NSTextAttachment` —
        // TextKit 2's view provider builds an `NSHostingView` from the
        // attachment's data and the layout manager positions it as a
        // block inline with the rest of the preview.
        let headers: [String] = table.head.cells.map { $0.plainText }
        var rows: [[String]] = []
        for row in table.body.rows {
            rows.append(row.cells.map { $0.plainText })
        }
        let attachment = MarkdownTableAttachment(headers: headers, rows: rows)
        let attrStr = NSMutableAttributedString(attachment: attachment)
        applyBlockSpanParagraphStyle(to: attrStr, kind: .table)
        return attrStr
    }

    // MARK: Inline

    mutating func visitText(_ text: Text) -> NSAttributedString {
        return NSAttributedString(string: text.string)
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> NSAttributedString {
        return NSAttributedString(
            string: inlineCode.code,
            attributes: [
                .font: Theme.codeFont,
                .backgroundColor: Theme.codeBackground,
            ]
        )
    }

    mutating func visitStrong(_ strong: Strong) -> NSAttributedString {
        let inner = defaultVisit(strong)
        let result = NSMutableAttributedString(attributedString: inner)
        result.enumerateAttribute(
            .font, in: NSRange(location: 0, length: result.length), options: []
        ) { value, range, _ in
            let base = (value as? NSFont) ?? Theme.bodyFont
            let bold = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
            result.addAttribute(.font, value: bold, range: range)
        }
        return result
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) -> NSAttributedString {
        let inner = defaultVisit(emphasis)
        let result = NSMutableAttributedString(attributedString: inner)
        result.enumerateAttribute(
            .font, in: NSRange(location: 0, length: result.length), options: []
        ) { value, range, _ in
            let base = (value as? NSFont) ?? Theme.bodyFont
            let italic = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
            result.addAttribute(.font, value: italic, range: range)
        }
        return result
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> NSAttributedString {
        let inner = defaultVisit(strikethrough)
        let result = NSMutableAttributedString(attributedString: inner)
        result.addAttribute(
            .strikethroughStyle,
            value: NSUnderlineStyle.single.rawValue,
            range: NSRange(location: 0, length: result.length)
        )
        return result
    }

    mutating func visitLink(_ link: Link) -> NSAttributedString {
        let inner = defaultVisit(link)
        let result = NSMutableAttributedString(attributedString: inner)
        let full = NSRange(location: 0, length: result.length)
        result.addAttribute(.foregroundColor, value: Theme.linkColor, range: full)
        result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: full)
        if let dest = link.destination, let url = safePreviewURL(from: dest) {
            result.addAttribute(.link, value: url, range: full)
        }
        return result
    }

    mutating func visitImage(_ image: Image) -> NSAttributedString {
        let alt = image.plainText
        return NSAttributedString(
            string: alt,
            attributes: [.foregroundColor: Theme.secondaryColor]
        )
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> NSAttributedString {
        return NSAttributedString(string: " ")
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) -> NSAttributedString {
        return NSAttributedString(string: "\n")
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> NSAttributedString {
        return NSAttributedString(string: inlineHTML.rawHTML)
    }

    mutating func visitHTMLBlock(_ htmlBlock: HTMLBlock) -> NSAttributedString {
        return NSAttributedString(string: htmlBlock.rawHTML)
    }

    // MARK: Helpers

    private func concat(_ parts: [NSAttributedString]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for p in parts { out.append(p) }
        return out
    }

    private func joinBlocks(_ blocks: [NSAttributedString]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (i, b) in blocks.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "\n")) }
            out.append(b)
        }
        return out
    }

    private func prosePreviewAttributes() -> [NSAttributedString.Key: Any] {
        let body = Theme.bodyFont.pointSize
        let para = NSMutableParagraphStyle()
        para.lineSpacing = body * Theme.extraLeadingRatio
        para.paragraphSpacing = body * 0.55
        para.alignment = .natural
        return [
            .font: Theme.bodyFont,
            .foregroundColor: Theme.textColor,
            .paragraphStyle: para,
        ]
    }

}

// MARK: - Line-prefix helper (for nested list indentation)

private func indentLines(_ attr: NSAttributedString, by indent: String) -> NSAttributedString {
    let s = attr.string as NSString
    let result = NSMutableAttributedString(attributedString: attr)
    var insertAt: [Int] = [0]
    var i = 0
    while i < s.length {
        if s.character(at: i) == 0x0A, i + 1 < s.length {
            insertAt.append(i + 1)
        }
        i += 1
    }
    let indentAttr = NSAttributedString(string: indent)
    for offset in insertAt.reversed() {
        result.insert(indentAttr, at: offset)
    }
    return result
}

// MARK: - Post-passes for constructs swift-markdown doesn't model

/// Replace `[^N]` footnote references with just `N`, styled raised+small
/// in link colour. swift-markdown emits the brackets as plain text.
private func substituteFootnoteReferences(in result: NSMutableAttributedString) {
    let pattern = try! NSRegularExpression(pattern: "\\[\\^([^\\]\\n]+)\\]", options: [])
    let full = NSRange(location: 0, length: result.length)
    let matches = pattern.matches(in: result.string, range: full)
    for match in matches.reversed() {
        let inside = (result.string as NSString).substring(with: match.range(at: 1))
        let raised = NSMutableAttributedString(string: inside)
        let r = NSRange(location: 0, length: raised.length)
        raised.addAttribute(.foregroundColor, value: Theme.linkColor, range: r)
        raised.addAttribute(.baselineOffset, value: 3, range: r)
        raised.addAttribute(
            .font,
            value: NSFont.systemFont(ofSize: Theme.bodyFont.pointSize * 0.8),
            range: r
        )
        result.replaceCharacters(in: match.range, with: raised)
    }
}


// MARK: - Paragraph styles

private func previewHeadingParagraphStyle(size: CGFloat) -> NSParagraphStyle {
    let para = NSMutableParagraphStyle()
    para.lineSpacing = size * 0.12
    para.paragraphSpacingBefore = size * 1.1
    para.paragraphSpacing = size * 0.35
    para.alignment = .natural
    return para
}

enum BlockKind { case code, table }

/// Per-line paragraph styles for a multi-line block (code or table). A
/// single shared style with `paragraphSpacing > 0` stamps that gap between
/// every internal `\n` boundary — a baggy block. Instead, only the first
/// line carries `paragraphSpacingBefore` and only the last carries
/// `paragraphSpacing`, so the breathing room appears outside the block.
/// Code blocks get a horizontal inset so code doesn't hug the band edge.
func applyBlockSpanParagraphStyle(to result: NSMutableAttributedString, kind: BlockKind) {
    let ns = result.string as NSString
    applyBlockSpanParagraphStyle(
        lines: lineRanges(in: ns, within: NSRange(location: 0, length: ns.length)),
        kind: kind
    ) { range, style in
        result.addAttribute(.paragraphStyle, value: style, range: range)
    }
}

func applyBlockSpanParagraphStyle(to storage: NSTextStorage, in range: NSRange, kind: BlockKind) {
    let ns = storage.string as NSString
    applyBlockSpanParagraphStyle(
        lines: lineRanges(in: ns, within: range),
        kind: kind
    ) { range, style in
        storage.addAttribute(.paragraphStyle, value: style, range: range)
    }
}

private func lineRanges(in ns: NSString, within range: NSRange) -> [NSRange] {
    var ranges: [NSRange] = []
    var i = range.location
    let end = range.location + range.length
    while i < end {
        let lr = ns.lineRange(for: NSRange(location: i, length: 0))
        let clipEnd = min(lr.location + lr.length, end)
        ranges.append(NSRange(location: lr.location, length: clipEnd - lr.location))
        i = lr.location + lr.length
    }
    return ranges
}

private func applyBlockSpanParagraphStyle(
    lines: [NSRange],
    kind: BlockKind,
    apply: (NSRange, NSParagraphStyle) -> Void
) {
    for (idx, lineRange) in lines.enumerated() {
        let isFirst = idx == 0
        let isLast = idx == lines.count - 1
        let para = NSMutableParagraphStyle()
        if kind == .code {
            para.firstLineHeadIndent = 16
            para.headIndent = 16
            para.tailIndent = -16
        }
        para.lineSpacing = kind == .code ? 2 : 0
        para.paragraphSpacingBefore = isFirst ? 16 : 0
        para.paragraphSpacing = isLast ? 16 : 0
        apply(lineRange, para)
    }
}

// MARK: - URL allowlist

/// Mirrors the styler's allowlist so a malicious markdown source can't
/// inject `javascript:` or `file://` links into the preview view either.
private func safePreviewURL(from string: String) -> URL? {
    let trimmed = string.trimmingCharacters(in: .whitespaces)
    guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
        return nil
    }
    let allowed: Set<String> = ["http", "https", "mailto"]
    return allowed.contains(scheme) ? url : nil
}
