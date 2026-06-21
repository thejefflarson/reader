import AppKit
import Markdown

/// Applies markdown-aware typographic styling directly to an `NSTextStorage`
/// without altering its characters. The markdown source remains the ground
/// truth; attributes are layered on top so copy/paste round-trips losslessly.
///
/// Implementation:
///   - Parses the source with `swift-markdown` (Apple's CommonMark+GFM
///     parser). Each node's `range` (line/column-based) is mapped to an
///     `NSRange` over the storage.
///   - A `MarkupWalker` visits every node and stamps attributes onto the
///     storage at the node's range — heading font on headings, bold on
///     strong, code background on inline code, etc.
///   - Marker characters (`**`, backticks, brackets, fence lines…) are
///     flagged `.isMarkdownSyntax = true`; preview mode strips them.
///   - Footnote refs/definitions and reference definitions aren't modelled
///     by swift-markdown, so a small regex post-pass handles them.
final class MarkdownStyler {
    func restyle(_ storage: NSTextStorage) {
        let full = NSRange(location: 0, length: storage.length)
        guard full.length > 0 else { return }
        // Refuse to run the full parse + walk synchronously on very large
        // documents — that can produce a multi-second main-thread stall.
        // 1 MB is well above any realistic note size.
        let maxStyleBytes = 1 * 1024 * 1024
        guard storage.length <= maxStyleBytes else { return }

        storage.setAttributes(baseAttributes(), range: full)

        let source = storage.string
        let document = Document(parsing: source, options: [])
        let map = SourceMap(source)
        var walker = AttributeStamper(storage: storage, map: map)
        walker.visit(document)

        // Constructs swift-markdown doesn't model.
        stampReferenceDefinitions(in: storage)
        stampReferenceLinks(in: storage)
        stampFootnoteReferences(in: storage)
        stampFootnoteDefinitions(in: storage)
        stampBackslashEscapes(in: storage)
        stampHardLineBreaks(in: storage)
    }

    func baseAttributes() -> [NSAttributedString.Key: Any] {
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

// MARK: - SourceMap

/// Translates `swift-markdown`'s 1-based `(line, utf8Column)` source
/// locations into `NSString` UTF-16 offsets, which is what `NSTextStorage`
/// uses. ASCII collapses to `lineStart + column - 1`; non-ASCII walks the
/// line's scalars to convert byte offsets to UTF-16 offsets.
final class SourceMap {
    private let source: String
    private let nsLength: Int
    private var lineStarts: [(utf16: Int, utf8: Int)] = [(0, 0)]

    init(_ source: String) {
        self.source = source
        self.nsLength = (source as NSString).length
        var u16 = 0
        var u8 = 0
        for scalar in source.unicodeScalars {
            u16 += scalar.utf16.count
            u8 += scalar.utf8.count
            if scalar == "\n" {
                lineStarts.append((u16, u8))
            }
        }
    }

    func offset(_ location: SourceLocation) -> Int {
        let idx = max(0, min(location.line - 1, lineStarts.count - 1))
        let start = lineStarts[idx]
        let targetU8 = start.utf8 + max(0, location.column - 1)

        // ASCII fast path covers virtually every markdown file.
        if targetU8 - start.utf8 == location.column - 1,
           source.utf8.count == (source as NSString).length {
            return min(start.utf16 + (location.column - 1), nsLength)
        }

        // Walk the line's scalars from line start.
        let s16 = source.utf16
        guard let strStart = s16.index(
            s16.startIndex, offsetBy: start.utf16, limitedBy: s16.endIndex
        ) else {
            return nsLength
        }
        guard let tail = String(s16[strStart...]) else {
            return min(start.utf16 + (location.column - 1), nsLength)
        }
        var u8 = start.utf8
        var u16 = start.utf16
        for scalar in tail.unicodeScalars {
            if u8 >= targetU8 { break }
            u8 += scalar.utf8.count
            u16 += scalar.utf16.count
            if scalar == "\n" { break }
        }
        return min(u16, nsLength)
    }

    func nsRange(_ range: SourceRange) -> NSRange {
        let lo = offset(range.lowerBound)
        let hi = offset(range.upperBound)
        return NSRange(location: lo, length: max(0, hi - lo))
    }
}

// MARK: - Visitor

/// Walks the markdown AST and stamps attributes onto an `NSTextStorage`.
/// Each `visit…` either calls the helper for that construct or descends
/// (`defaultVisit`) so children get their turn.
private struct AttributeStamper: MarkupWalker {
    let storage: NSTextStorage
    let map: SourceMap
    var ns: NSString { storage.string as NSString }

    // MARK: Blocks

    mutating func visitHeading(_ heading: Heading) {
        guard let r = nsRange(of: heading) else { return descendInto(heading) }
        let font = Theme.headingFont(level: heading.level)
        storage.addAttribute(.font, value: font, range: r)
        storage.addAttribute(
            .paragraphStyle,
            value: headingParagraphStyle(size: font.pointSize),
            range: r
        )

        let first = ns.character(at: r.location)
        if first == 0x23 {  // '#' → ATX heading; mark hashes + following whitespace
            let lineEnd = ns.lineRange(for: NSRange(location: r.location, length: 0))
            var i = r.location
            while i < lineEnd.location + lineEnd.length, ns.character(at: i) == 0x23 {
                i += 1
            }
            let hashCount = i - r.location
            var ws = 0
            while i + ws < lineEnd.location + lineEnd.length,
                  ns.character(at: i + ws) == 0x20 { ws += 1 }
            storage.markSyntax(NSRange(location: r.location, length: hashCount + ws))
        } else {
            // Setext heading: title on first line, `===`/`---` on second.
            let firstLine = ns.lineRange(for: NSRange(location: r.location, length: 0))
            let underlineStart = firstLine.location + firstLine.length
            if underlineStart < r.location + r.length {
                let underline = ns.lineRange(for: NSRange(location: underlineStart, length: 0))
                let stripLen = min(underline.length, r.location + r.length - underline.location)
                storage.markSyntax(NSRange(location: underline.location, length: stripLen))
            }
        }
        descendInto(heading)
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        guard let r = nsRange(of: thematicBreak) else { return }
        storage.addAttribute(.foregroundColor, value: Theme.quaternaryColor, range: r)
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        guard let r = nsRange(of: codeBlock) else { return }
        storage.addAttributes(
            [
                .font: Theme.codeFont,
                .foregroundColor: Theme.textColor,
                .backgroundColor: Theme.codeBackground,
                .isCodeBlock: true,
            ],
            range: r
        )
        applyBlockSpanParagraphStyle(to: storage, in: r, kind: .code)
        // Fenced code: mark the opening and closing fence lines as syntax.
        if r.length > 0 {
            let firstChar = ns.character(at: r.location)
            if firstChar == 0x60 || firstChar == 0x7E {  // ` or ~
                let opening = ns.lineRange(for: NSRange(location: r.location, length: 0))
                storage.addAttributes(
                    [.foregroundColor: Theme.syntaxColor, .isMarkdownSyntax: true],
                    range: opening
                )
                // Find the last non-empty line covered by the range — that's the closing fence.
                var probe = r.location + r.length - 1
                while probe > opening.location + opening.length,
                      ns.character(at: probe) == 0x0A { probe -= 1 }
                let closing = ns.lineRange(for: NSRange(location: probe, length: 0))
                if closing.location > opening.location {
                    let clip = min(closing.length, r.location + r.length - closing.location)
                    storage.addAttributes(
                        [.foregroundColor: Theme.syntaxColor, .isMarkdownSyntax: true],
                        range: NSRange(location: closing.location, length: clip)
                    )
                }
            }
        }
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        guard let r = nsRange(of: blockQuote) else { return descendInto(blockQuote) }
        storage.addAttribute(.foregroundColor, value: Theme.secondaryColor, range: r)
        let italic = NSFontManager.shared.convert(Theme.bodyFont, toHaveTrait: .italicFontMask)
        storage.addAttribute(.font, value: italic, range: r)

        let para = NSMutableParagraphStyle()
        para.lineSpacing = Theme.bodyFont.pointSize * Theme.extraLeadingRatio
        let indent = Theme.bodyFont.pointSize * 1.5
        para.firstLineHeadIndent = indent
        para.headIndent = indent
        para.paragraphSpacing = Theme.bodyFont.pointSize * 0.3
        storage.addAttribute(.paragraphStyle, value: para, range: r)

        // Mark the `>` marker at the start of each line.
        forEachLine(in: r) { lineRange in
            var i = lineRange.location
            let end = lineRange.location + lineRange.length
            while i < end, ns.character(at: i) == 0x20 { i += 1 }
            if i < end, ns.character(at: i) == 0x3E {  // '>'
                var markerLen = 1
                if i + 1 < end, ns.character(at: i + 1) == 0x20 { markerLen = 2 }
                storage.markSyntax(NSRange(location: i, length: markerLen))
            }
        }
        descendInto(blockQuote)
    }

    mutating func visitListItem(_ listItem: ListItem) {
        guard let r = nsRange(of: listItem) else { return descendInto(listItem) }

        let para = NSMutableParagraphStyle()
        para.lineSpacing = Theme.bodyFont.pointSize * Theme.extraLeadingRatio
        para.firstLineHeadIndent = 0
        para.headIndent = Theme.bodyFont.pointSize * (listItem.checkbox != nil ? 1.8 : 1.4)
        para.paragraphSpacing = Theme.bodyFont.pointSize * 0.15
        storage.addAttribute(.paragraphStyle, value: para, range: r)

        // Find and dim the bullet marker (`-`, `*`, `+`, or `N.`).
        var i = r.location
        let end = r.location + r.length
        while i < end, isSpaceOrTab(ns.character(at: i)) { i += 1 }
        let markerStart = i
        // Ordered: digits then '.'
        var sawDigit = false
        while i < end, isDigit(ns.character(at: i)) { i += 1; sawDigit = true }
        if sawDigit, i < end, ns.character(at: i) == 0x2E {
            i += 1
            storage.addAttribute(
                .foregroundColor, value: Theme.syntaxColor,
                range: NSRange(location: markerStart, length: i - markerStart)
            )
        } else if i < end {
            let ch = ns.character(at: i)
            if ch == 0x2D || ch == 0x2A || ch == 0x2B {  // - * +
                storage.addAttribute(
                    .foregroundColor, value: Theme.syntaxColor,
                    range: NSRange(location: i, length: 1)
                )
                i += 1
            }
        }

        // Task list: find the `[ ]` / `[x]` after the marker and style it.
        if let checkbox = listItem.checkbox {
            while i < end, isSpaceOrTab(ns.character(at: i)) { i += 1 }
            if i + 2 < end, ns.character(at: i) == 0x5B,
               ns.character(at: i + 2) == 0x5D {
                storage.addAttribute(
                    .foregroundColor, value: Theme.syntaxColor,
                    range: NSRange(location: i, length: 3)
                )
                if checkbox == .checked {
                    // Strike-through and dim the content after `] `.
                    var contentStart = i + 3
                    while contentStart < end, isSpaceOrTab(ns.character(at: contentStart)) {
                        contentStart += 1
                    }
                    let lineEnd = ns.lineRange(for: NSRange(location: contentStart, length: 0))
                    let endOfLine = min(lineEnd.location + lineEnd.length, end)
                    var contentLen = endOfLine - contentStart
                    while contentLen > 0,
                          ns.character(at: contentStart + contentLen - 1) == 0x0A {
                        contentLen -= 1
                    }
                    if contentLen > 0 {
                        let contentRange = NSRange(location: contentStart, length: contentLen)
                        storage.addAttribute(
                            .strikethroughStyle,
                            value: NSUnderlineStyle.single.rawValue,
                            range: contentRange
                        )
                        storage.addAttribute(
                            .foregroundColor, value: Theme.secondaryColor, range: contentRange
                        )
                    }
                }
            }
        }
        descendInto(listItem)
    }

    mutating func visitTable(_ table: Table) {
        guard let r = nsRange(of: table) else { return descendInto(table) }
        storage.addAttribute(.font, value: Theme.codeFont, range: r)

        forEachLine(in: r) { lineRange in
            let line = ns.substring(with: lineRange)

            // Dim pipes (preview substitutes them; not isMarkdownSyntax).
            var offset = 0
            for ch in line {
                if ch == "|" {
                    storage.addAttribute(
                        .foregroundColor, value: Theme.syntaxColor,
                        range: NSRange(location: lineRange.location + offset, length: 1)
                    )
                }
                offset += 1
            }
            // Whole separator row dimmed.
            if line.range(of: "^\\s*\\|?[\\s:\\-|]+\\|?\\s*$", options: .regularExpression) != nil,
               line.contains("-") {
                storage.addAttribute(
                    .foregroundColor, value: Theme.syntaxColor, range: lineRange
                )
            }
        }
    }

    // MARK: Inline

    mutating func visitStrong(_ strong: Strong) {
        guard let r = nsRange(of: strong), r.length >= 4 else { return descendInto(strong) }
        let currentFont = storage.attribute(.font, at: r.location, effectiveRange: nil)
            as? NSFont ?? Theme.bodyFont
        let bold = NSFontManager.shared.convert(currentFont, toHaveTrait: .boldFontMask)
        storage.addAttribute(.font, value: bold, range: r)
        storage.markSyntax(NSRange(location: r.location, length: 2))
        storage.markSyntax(NSRange(location: r.location + r.length - 2, length: 2))
        descendInto(strong)
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        guard let r = nsRange(of: emphasis), r.length >= 2 else { return descendInto(emphasis) }
        let currentFont = storage.attribute(.font, at: r.location, effectiveRange: nil)
            as? NSFont ?? Theme.bodyFont
        let italic = NSFontManager.shared.convert(currentFont, toHaveTrait: .italicFontMask)
        storage.addAttribute(.font, value: italic, range: r)
        storage.markSyntax(NSRange(location: r.location, length: 1))
        storage.markSyntax(NSRange(location: r.location + r.length - 1, length: 1))
        descendInto(emphasis)
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
        guard let r = nsRange(of: strikethrough), r.length >= 4 else { return descendInto(strikethrough) }
        storage.addAttribute(
            .strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: r
        )
        storage.markSyntax(NSRange(location: r.location, length: 2))
        storage.markSyntax(NSRange(location: r.location + r.length - 2, length: 2))
        descendInto(strikethrough)
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        guard let r = nsRange(of: inlineCode), r.length >= 2 else { return }
        storage.addAttributes(
            [.font: Theme.codeFont, .backgroundColor: Theme.codeBackground],
            range: r
        )
        storage.markSyntax(NSRange(location: r.location, length: 1))
        storage.markSyntax(NSRange(location: r.location + r.length - 1, length: 1))
    }

    mutating func visitLink(_ link: Link) {
        guard let r = nsRange(of: link), r.length >= 2 else { return descendInto(link) }
        let isAutolink = link.isAutolink

        if isAutolink {
            // `<https://x>` — mark the angle brackets, link-colour the inside.
            let inside = NSRange(location: r.location + 1, length: r.length - 2)
            storage.markSyntax(NSRange(location: r.location, length: 1))
            storage.markSyntax(NSRange(location: r.location + r.length - 1, length: 1))
            storage.addAttribute(.foregroundColor, value: Theme.linkColor, range: inside)
            storage.addAttribute(
                .underlineStyle, value: NSUnderlineStyle.single.rawValue, range: inside
            )
            if let dest = link.destination, let url = safeURL(from: dest) {
                storage.addAttribute(.link, value: url, range: inside)
            }
            return
        }

        // Inline `[label](url)` or reference `[label][ref]`.
        // The label range is everything between the outer `[` and `]`.
        let labelStart = r.location + 1
        // Find the matching `]` by scanning forward (the parser already
        // produced a valid link, so this always succeeds).
        var depth = 1
        var i = labelStart
        let end = r.location + r.length
        while i < end {
            let ch = ns.character(at: i)
            if ch == 0x5B { depth += 1 }
            else if ch == 0x5D { depth -= 1; if depth == 0 { break } }
            i += 1
        }
        let labelEnd = min(i, end)
        let labelRange = NSRange(location: labelStart, length: labelEnd - labelStart)

        storage.addAttribute(.foregroundColor, value: Theme.linkColor, range: labelRange)
        storage.addAttribute(
            .underlineStyle, value: NSUnderlineStyle.single.rawValue, range: labelRange
        )
        if let dest = link.destination, let url = safeURL(from: dest) {
            storage.addAttribute(.link, value: url, range: labelRange)
        }

        storage.markSyntax(NSRange(location: r.location, length: 1))                // `[`
        if labelEnd < end {
            // Everything from `]` to the closing `)` or `]` is syntax.
            storage.markSyntax(
                NSRange(location: labelEnd, length: end - labelEnd)
            )
        }
        descendInto(link)
    }

    mutating func visitImage(_ image: Image) {
        guard let r = nsRange(of: image), r.length >= 4 else { return descendInto(image) }
        // `![alt](url)` — find `]` to split alt from URL.
        let altStart = r.location + 2
        var i = altStart
        let end = r.location + r.length
        while i < end, ns.character(at: i) != 0x5D { i += 1 }
        let altEnd = min(i, end)
        let altRange = NSRange(location: altStart, length: altEnd - altStart)
        storage.addAttribute(.foregroundColor, value: Theme.secondaryColor, range: altRange)

        storage.markSyntax(NSRange(location: r.location, length: 2))  // `![`
        if altEnd < end {
            storage.markSyntax(NSRange(location: altEnd, length: end - altEnd))
        }
    }

    // Hard line breaks (`  \n`) are handled by a regex post-pass —
    // swift-markdown's LineBreak source range doesn't reliably cover the
    // trailing spaces authors visibly type, so we re-discover them.

    // MARK: Helpers

    private func nsRange(of markup: Markup) -> NSRange? {
        guard let range = markup.range else { return nil }
        let nsr = map.nsRange(range)
        let storageLen = (storage.string as NSString).length
        guard nsr.location <= storageLen else { return nil }
        let clipped = NSRange(
            location: nsr.location,
            length: max(0, min(nsr.length, storageLen - nsr.location))
        )
        return clipped.length == 0 ? nil : clipped
    }

    private func forEachLine(in range: NSRange, _ body: (NSRange) -> Void) {
        var i = range.location
        let end = range.location + range.length
        while i < end {
            let lr = ns.lineRange(for: NSRange(location: i, length: 0))
            let clipEnd = min(lr.location + lr.length, end)
            body(NSRange(location: lr.location, length: clipEnd - lr.location))
            i = lr.location + lr.length
        }
    }

    private func isSpaceOrTab(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 }
    private func isDigit(_ c: unichar) -> Bool { c >= 0x30 && c <= 0x39 }
}

// MARK: - Paragraph styles

/// More air above a heading than below it (Bringhurst §8.1), tight leading
/// inside the heading itself.
private func headingParagraphStyle(size: CGFloat) -> NSParagraphStyle {
    let para = NSMutableParagraphStyle()
    para.lineSpacing = size * 0.12
    para.paragraphSpacingBefore = size * 1.1
    para.paragraphSpacing = size * 0.35
    para.alignment = .natural
    return para
}

// `applyPerLineCodeBlockParagraphStyle(to:in:)` is defined in
// MarkdownPreview.swift so both the styler and the preview renderer use
// one source of truth for code-block paragraph styling.

// MARK: - URL scheme allowlist (security)

/// Allowlist of URL schemes that may be made clickable. `NSTextView` opens
/// clicked `.link` values via `NSWorkspace`, which honours `file://`,
/// `javascript:`, custom app schemes, and other vectors a hostile `.md`
/// source should not be able to trigger with one click.
private func safeURL(from string: String) -> URL? {
    let trimmed = string.trimmingCharacters(in: .whitespaces)
    // swift-markdown's autolink for `<jeff@example.com>` gives destination
    // "mailto:jeff@example.com" already, so no special-casing needed here.
    guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
        return nil
    }
    let allowed: Set<String> = ["http", "https", "mailto"]
    return allowed.contains(scheme) ? url : nil
}

// MARK: - Constructs swift-markdown doesn't model

private extension MarkdownStyler {
    /// `[ref]: https://example.com "Title"` — visible in edit mode (dimmed)
    /// so authors can manage references; the whole line (plus trailing \n)
    /// is flagged `.isMarkdownSyntax` so preview hides it.
    func stampReferenceDefinitions(in storage: NSTextStorage) {
        let pattern = try! NSRegularExpression(
            pattern: "(?m)^(\\[[^\\]\\n]+\\]):\\s+(\\S+)(\\s+\"[^\"\\n]*\")?\\s*$",
            options: []
        )
        let ns = storage.string as NSString
        let full = NSRange(location: 0, length: ns.length)
        pattern.enumerateMatches(in: storage.string, range: full) { match, _, _ in
            guard let match = match else { return }
            let whole = match.range
            storage.addAttribute(.foregroundColor, value: Theme.secondaryColor, range: whole)
            storage.addAttribute(
                .foregroundColor, value: Theme.linkColor, range: match.range(at: 1)
            )
            let after = whole.location + whole.length
            let stripLen =
                (after < ns.length && ns.character(at: after) == 0x0A) ? whole.length + 1 : whole.length
            storage.addAttribute(
                .isMarkdownSyntax, value: true,
                range: NSRange(location: whole.location, length: stripLen)
            )
        }
    }

    /// `[label][ref]` and `[label][]` — swift-markdown emits these as
    /// `Link` only when a matching reference definition exists in the
    /// document. We can't resolve the ref in general (definition might
    /// arrive later, or be in a different file), so we always style the
    /// label as link-coloured and flag the wrapping brackets as syntax.
    func stampReferenceLinks(in storage: NSTextStorage) {
        let pattern = try! NSRegularExpression(
            pattern: "(?<!\\!)\\[([^\\]\\n]+)\\]\\[([^\\]\\n]*)\\]",
            options: []
        )
        let full = NSRange(location: 0, length: storage.length)
        pattern.enumerateMatches(in: storage.string, range: full) { match, _, _ in
            guard let match = match else { return }
            let whole = match.range
            let label = match.range(at: 1)
            let ref = match.range(at: 2)
            storage.addAttribute(.foregroundColor, value: Theme.linkColor, range: label)
            storage.addAttribute(
                .underlineStyle, value: NSUnderlineStyle.single.rawValue, range: label
            )
            storage.markSyntax(NSRange(location: whole.location, length: 1))
            storage.markSyntax(NSRange(location: label.location + label.length, length: 2))
            storage.markSyntax(ref)
            storage.markSyntax(NSRange(location: whole.location + whole.length - 1, length: 1))
        }
    }

    /// `[^1]` — render the number raised and small; mark `[^` and `]` as
    /// syntax so preview shows just the number.
    func stampFootnoteReferences(in storage: NSTextStorage) {
        let pattern = try! NSRegularExpression(pattern: "\\[\\^([^\\]\\n]+)\\]", options: [])
        let full = NSRange(location: 0, length: storage.length)
        pattern.enumerateMatches(in: storage.string, range: full) { match, _, _ in
            guard let match = match else { return }
            let whole = match.range
            storage.addAttribute(.foregroundColor, value: Theme.linkColor, range: whole)
            storage.addAttribute(.baselineOffset, value: 3, range: whole)
            storage.addAttribute(
                .font,
                value: NSFont.systemFont(ofSize: Theme.bodyFont.pointSize * 0.8),
                range: whole
            )
            storage.addAttribute(
                .isMarkdownSyntax, value: true,
                range: NSRange(location: whole.location, length: 2)
            )
            storage.addAttribute(
                .isMarkdownSyntax, value: true,
                range: NSRange(location: whole.location + whole.length - 1, length: 1)
            )
        }
    }

    /// `[^1]: the note` at the start of a line.
    func stampFootnoteDefinitions(in storage: NSTextStorage) {
        let pattern = try! NSRegularExpression(
            pattern: "(?m)^(\\[\\^[^\\]\\n]+\\]):\\s*(.+)$",
            options: []
        )
        let full = NSRange(location: 0, length: storage.length)
        pattern.enumerateMatches(in: storage.string, range: full) { match, _, _ in
            guard let match = match else { return }
            let label = match.range(at: 1)
            let body = match.range(at: 2)
            storage.addAttribute(.foregroundColor, value: Theme.linkColor, range: label)
            storage.addAttribute(.foregroundColor, value: Theme.secondaryColor, range: body)
            let italic = NSFontManager.shared.convert(Theme.bodyFont, toHaveTrait: .italicFontMask)
            storage.addAttribute(.font, value: italic, range: body)
        }
    }

    /// Two trailing spaces before `\n` are a CommonMark hard break.
    /// Highlight the spaces so the writer can see the break is there.
    func stampHardLineBreaks(in storage: NSTextStorage) {
        let pattern = try! NSRegularExpression(pattern: "(  )\\n", options: [])
        let full = NSRange(location: 0, length: storage.length)
        pattern.enumerateMatches(in: storage.string, range: full) { match, _, _ in
            guard let match = match else { return }
            let spaces = match.range(at: 1)
            storage.addAttribute(.backgroundColor, value: Theme.codeBackground, range: spaces)
            storage.markSyntax(spaces)
        }
    }

    /// `\*`, `\_`, `\\` — dim the backslash so the next character reads
    /// as the literal. swift-markdown consumes the slash before emitting
    /// the text, so we re-discover them via regex.
    func stampBackslashEscapes(in storage: NSTextStorage) {
        let pattern = try! NSRegularExpression(
            pattern: "\\\\[\\\\`*_{}\\[\\]()#+\\-.!>~|]",
            options: []
        )
        let full = NSRange(location: 0, length: storage.length)
        pattern.enumerateMatches(in: storage.string, range: full) { match, _, _ in
            guard let match = match else { return }
            storage.markSyntax(NSRange(location: match.range.location, length: 1))
        }
    }
}

// MARK: - Convenience

private extension NSTextStorage {
    /// Tint a range as a markdown syntax marker and flag it so preview mode
    /// can strip it.
    func markSyntax(_ range: NSRange) {
        addAttributes([
            .foregroundColor: Theme.syntaxColor,
            .isMarkdownSyntax: true,
        ], range: range)
    }
}
