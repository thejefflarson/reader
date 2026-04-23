import AppKit

/// Applies markdown-aware typographic styling directly to an `NSTextStorage`
/// without altering its characters. The markdown source remains the ground
/// truth; attributes are layered on top so copy/paste round-trips losslessly.
///
/// Organisation:
///   - Every markdown construct is a `Rule` — a regex + a closure that
///     stamps attributes on its match.
///   - Rules run in the order they're listed in `Self.allRules`. A rule
///     marked `.occupies` (code spans, fenced blocks) forbids later rules
///     from firing inside its range — "code" content is never re-interpreted.
///   - Syntax markers (the literal `*`, `#`, backtick, brackets…) are
///     stamped with `.isMarkdownSyntax = true`; preview mode deletes those
///     ranges to produce a clean rendered view.
final class MarkdownStyler {
    private let rules: [Rule]

    init() {
        rules = Self.allRules()
    }

    func restyle(_ storage: NSTextStorage) {
        let full = NSRange(location: 0, length: storage.length)
        guard full.length > 0 else { return }

        storage.setAttributes(baseAttributes(), range: full)
        let occupied = NSMutableIndexSet()
        let context = Context(storage: storage, occupied: occupied)

        for rule in rules {
            rule.pattern.enumerateMatches(
                in: storage.string,
                options: [],
                range: full
            ) { match, _, _ in
                guard let match = match else { return }
                if !rule.occupies, occupied.intersects(in: match.range) {
                    return
                }
                rule.stamp(match, context)
                if rule.occupies {
                    occupied.add(in: match.range)
                }
            }
        }
    }

    // MARK: - Base prose

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

    // MARK: - Rule plumbing

    struct Context {
        let storage: NSTextStorage
        let occupied: NSMutableIndexSet
    }

    struct Rule {
        let pattern: NSRegularExpression
        /// Rules with `occupies == true` prevent later rules from firing
        /// inside their match range. Use this for code spans and fenced
        /// code blocks, where content must not be re-parsed as markdown.
        let occupies: Bool
        let stamp: (NSTextCheckingResult, Context) -> Void
    }

    // MARK: - Rule list (ordered)

    private static func allRules() -> [Rule] {
        return [
            fencedCode(),
            indentedCode(),
            inlineCode(),
            setextHeading1(),
            setextHeading2(),
            atxHeading(),
            horizontalRule(),
            taskListItem(),
            listItem(),
            blockquote(),
            tableRow(),
            referenceDefinition(),
            footnoteDefinition(),
            bold(),
            italicStar(),
            italicUnderscore(),
            strikethrough(),
            image(),
            inlineLink(),
            referenceLink(),
            footnoteReference(),
            autolink(),
            hardLineBreak(),
            escape(),
        ]
    }

    // MARK: - Regex helper

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // `dotMatchesLineSeparators` off by default; enable per-rule when needed.
        return try! NSRegularExpression(pattern: pattern, options: [])
    }

    // MARK: - Code

    /// Paragraph style for block-level code — horizontal inset so text
    /// doesn't hug the fill edge, vertical breathing room so the code
    /// band doesn't kiss the surrounding prose.
    private static func codeBlockParagraphStyle() -> NSParagraphStyle {
        let para = NSMutableParagraphStyle()
        para.firstLineHeadIndent = 16
        para.headIndent = 16
        para.tailIndent = -16
        para.lineSpacing = 2
        para.paragraphSpacingBefore = 10
        para.paragraphSpacing = 10
        return para
    }

    private static func fencedCode() -> Rule {
        // ``` fenced ``` over multiple lines, optional language tag. We capture
        // the opening fence line, the content, and the closing fence line as
        // three groups so preview mode can strip the fence lines (marked
        // `.isMarkdownSyntax`) while keeping the code content. The whole
        // match range is flagged `.isCodeBlock` so the custom layout manager
        // paints the background as a full-width band.
        let pattern = try! NSRegularExpression(
            pattern: "(?m)^(```[^\\n]*)\\n([\\s\\S]*?)\\n(```)\\s*$",
            options: []
        )
        return Rule(pattern: pattern, occupies: true) { match, ctx in
            let whole = match.range
            let opening = match.range(at: 1)
            let content = match.range(at: 2)
            let closing = match.range(at: 3)

            let openingLine = NSRange(
                location: opening.location,
                length: opening.length + 1
            )
            let contentEnd = content.location + content.length
            let closingLine = NSRange(
                location: contentEnd,
                length: closing.location + closing.length - contentEnd
            )

            // Whole block: full-width code background + padding.
            ctx.storage.addAttributes(
                [
                    .font: Theme.codeFont,
                    .foregroundColor: Theme.textColor,
                    .backgroundColor: Theme.codeBackground,
                    .isCodeBlock: true,
                    .paragraphStyle: codeBlockParagraphStyle(),
                ],
                range: whole
            )
            // Fence lines are markdown syntax — preview mode strips them.
            let fenceAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: Theme.syntaxColor,
                .isMarkdownSyntax: true,
            ]
            ctx.storage.addAttributes(fenceAttrs, range: openingLine)
            ctx.storage.addAttributes(fenceAttrs, range: closingLine)
        }
    }

    private static func indentedCode() -> Rule {
        let pattern = try! NSRegularExpression(
            pattern: "(?m)^(    |\\t)(.+)$",
            options: []
        )
        return Rule(pattern: pattern, occupies: true) { match, ctx in
            ctx.storage.addAttributes(
                [
                    .font: Theme.codeFont,
                    .backgroundColor: Theme.codeBackground,
                    .isCodeBlock: true,
                    .paragraphStyle: codeBlockParagraphStyle(),
                ],
                range: match.range
            )
        }
    }

    private static func inlineCode() -> Rule {
        let pattern = regex("`([^`\\n]+)`")
        return Rule(pattern: pattern, occupies: true) { match, ctx in
            let whole = match.range
            ctx.storage.addAttributes(
                [
                    .font: Theme.codeFont,
                    .backgroundColor: Theme.codeBackground,
                ],
                range: whole
            )
            ctx.storage.markSyntax(NSRange(location: whole.location, length: 1))
            ctx.storage.markSyntax(NSRange(location: whole.location + whole.length - 1, length: 1))
        }
    }

    // MARK: - Headings

    /// Paragraph style shared by every heading level. The reader wants
    /// more air above a heading than below it (Bringhurst §8.1), tight
    /// leading inside the heading itself.
    private static func headingParagraphStyle(size: CGFloat) -> NSParagraphStyle {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = size * 0.12
        para.paragraphSpacingBefore = size * 1.1
        para.paragraphSpacing = size * 0.35
        para.alignment = .natural
        return para
    }

    private static func atxHeading() -> Rule {
        let pattern = regex("(?m)^(#{1,6})(\\s+)([^\\n]+)$")
        return Rule(pattern: pattern, occupies: false) { match, ctx in
            let whole = match.range
            let hashes = match.range(at: 1)
            let font = Theme.headingFont(level: hashes.length)
            ctx.storage.addAttribute(.font, value: font, range: whole)
            ctx.storage.markSyntax(hashes)
            ctx.storage.markSyntax(match.range(at: 2))
            ctx.storage.addAttribute(.paragraphStyle, value: headingParagraphStyle(size: font.pointSize), range: whole)
        }
    }

    private static func setextHeading1() -> Rule {
        let pattern = regex("(?m)^([^\\n]+)\\n(=+)\\s*$")
        return Rule(pattern: pattern, occupies: false) { match, ctx in
            let font = Theme.headingFont(level: 1)
            ctx.storage.addAttribute(.font, value: font, range: match.range(at: 1))
            ctx.storage.markSyntax(match.range(at: 2))
            ctx.storage.addAttribute(.paragraphStyle, value: headingParagraphStyle(size: font.pointSize), range: match.range)
        }
    }

    private static func setextHeading2() -> Rule {
        // `Title\n---` — but only if the title line isn't itself a list
        // bullet or blockquote (which would fight this interpretation).
        let pattern = regex("(?m)^([^\\n]+)\\n(-{2,})\\s*$")
        return Rule(pattern: pattern, occupies: false) { match, ctx in
            let titleLine = match.range(at: 1)
            let titleText = (ctx.storage.string as NSString).substring(with: titleLine)
            if titleText.range(of: "^\\s*([-*+]|\\d+\\.)\\s+", options: .regularExpression) != nil {
                return
            }
            let font = Theme.headingFont(level: 2)
            ctx.storage.addAttribute(.font, value: font, range: titleLine)
            ctx.storage.markSyntax(match.range(at: 2))
            ctx.storage.addAttribute(.paragraphStyle, value: headingParagraphStyle(size: font.pointSize), range: match.range)
        }
    }

    // MARK: - Block

    private static func horizontalRule() -> Rule {
        let pattern = regex("(?m)^(-{3,}|\\*{3,}|_{3,})\\s*$")
        return Rule(pattern: pattern, occupies: false) { match, ctx in
            ctx.storage.addAttribute(.foregroundColor, value: Theme.quaternaryColor, range: match.range)
        }
    }

    private static func blockquote() -> Rule {
        let pattern = regex("(?m)^(>\\s*)(.*)$")
        return Rule(pattern: pattern, occupies: false) { match, ctx in
            let whole = match.range
            let marker = match.range(at: 1)
            let content = match.range(at: 2)

            ctx.storage.markSyntax(marker)
            ctx.storage.addAttribute(.foregroundColor, value: Theme.secondaryColor, range: whole)
            let italic = NSFontManager.shared.convert(Theme.bodyFont, toHaveTrait: .italicFontMask)
            ctx.storage.addAttribute(.font, value: italic, range: content)

            let para = NSMutableParagraphStyle()
            para.lineSpacing = Theme.bodyFont.pointSize * Theme.extraLeadingRatio
            let indent = Theme.bodyFont.pointSize * 1.5
            para.firstLineHeadIndent = indent
            para.headIndent = indent
            para.paragraphSpacing = Theme.bodyFont.pointSize * 0.3
            ctx.storage.addAttribute(.paragraphStyle, value: para, range: whole)
        }
    }

    private static func listItem() -> Rule {
        let pattern = regex("(?m)^(\\s*)([-*+]|\\d+\\.)(\\s+)(.+)$")
        return Rule(pattern: pattern, occupies: false) { match, ctx in
            let whole = match.range
            let marker = match.range(at: 2)
            ctx.storage.addAttribute(.foregroundColor, value: Theme.syntaxColor, range: marker)

            let para = NSMutableParagraphStyle()
            para.lineSpacing = Theme.bodyFont.pointSize * Theme.extraLeadingRatio
            para.firstLineHeadIndent = 0
            para.headIndent = Theme.bodyFont.pointSize * 1.4
            para.paragraphSpacing = Theme.bodyFont.pointSize * 0.15
            ctx.storage.addAttribute(.paragraphStyle, value: para, range: whole)
        }
    }

    private static func taskListItem() -> Rule {
        // `- [ ] task` / `- [x] done` — stamp a visual "box" style on the
        // checkbox, strike-through completed items.
        let pattern = regex("(?m)^(\\s*)([-*+])(\\s+)(\\[([ xX])\\])(\\s+)(.+)$")
        return Rule(pattern: pattern, occupies: false) { match, ctx in
            let whole = match.range
            let marker = match.range(at: 2)
            let checkbox = match.range(at: 4)
            let state = match.range(at: 5)
            let content = match.range(at: 7)

            ctx.storage.addAttribute(.foregroundColor, value: Theme.syntaxColor, range: marker)
            ctx.storage.addAttribute(.foregroundColor, value: Theme.syntaxColor, range: checkbox)

            let storageText = ctx.storage.string as NSString
            let stateChar = storageText.substring(with: state).trimmingCharacters(in: .whitespaces).lowercased()
            if stateChar == "x" {
                ctx.storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: content)
                ctx.storage.addAttribute(.foregroundColor, value: Theme.secondaryColor, range: content)
            }

            let para = NSMutableParagraphStyle()
            para.lineSpacing = Theme.bodyFont.pointSize * Theme.extraLeadingRatio
            para.firstLineHeadIndent = 0
            para.headIndent = Theme.bodyFont.pointSize * 1.8
            para.paragraphSpacing = Theme.bodyFont.pointSize * 0.15
            ctx.storage.addAttribute(.paragraphStyle, value: para, range: whole)
        }
    }

    private static func tableRow() -> Rule {
        // Match any line that looks like a table row: starts and ends with
        // `|`, has at least one interior `|`. Cells are monospace so columns
        // align visually in the source-is-rendered model.
        let pattern = regex("(?m)^(\\s*\\|.+\\|)\\s*$")
        return Rule(pattern: pattern, occupies: false) { match, ctx in
            let whole = match.range
            ctx.storage.addAttribute(.font, value: Theme.codeFont, range: whole)

            // Dim every `|` pipe character as syntax.
            let ns = ctx.storage.string as NSString
            let line = ns.substring(with: whole)
            var offset = 0
            for ch in line {
                if ch == "|" {
                    let r = NSRange(location: whole.location + offset, length: 1)
                    ctx.storage.markSyntax(r)
                }
                offset += 1
            }

            // Dim separator rows entirely (`|---|---|`).
            if line.range(of: "^\\s*\\|?[\\s:\\-|]+\\|?\\s*$", options: .regularExpression) != nil,
               line.contains("-") {
                ctx.storage.addAttribute(.foregroundColor, value: Theme.syntaxColor, range: whole)
            }
        }
    }

    // MARK: - Inline emphasis

    private static func bold() -> Rule {
        let pattern = try! NSRegularExpression(
            pattern: "(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1",
            options: [.dotMatchesLineSeparators]
        )
        return Rule(pattern: pattern, occupies: false) { match, ctx in
            let whole = match.range
            let currentFont = ctx.storage.attribute(.font, at: whole.location, effectiveRange: nil) as? NSFont ?? Theme.bodyFont
            let boldFont = NSFontManager.shared.convert(currentFont, toHaveTrait: .boldFontMask)
            ctx.storage.addAttribute(.font, value: boldFont, range: whole)
            ctx.storage.markSyntax(NSRange(location: whole.location, length: 2))
            ctx.storage.markSyntax(NSRange(location: whole.location + whole.length - 2, length: 2))
        }
    }

    private static func italicStar() -> Rule {
        let pattern = regex("(?<![*\\w])\\*(?=\\S)([^*\\n]+?)(?<=\\S)\\*(?![*\\w])")
        return Rule(pattern: pattern, occupies: false) { match, ctx in
            Self.stampItalic(match, ctx: ctx, markerLength: 1)
        }
    }

    private static func italicUnderscore() -> Rule {
        let pattern = regex("(?<![_\\w])_(?=\\S)([^_\\n]+?)(?<=\\S)_(?![_\\w])")
        return Rule(pattern: pattern, occupies: false) { match, ctx in
            Self.stampItalic(match, ctx: ctx, markerLength: 1)
        }
    }

    private static func stampItalic(_ match: NSTextCheckingResult, ctx: Context, markerLength: Int) {
        let whole = match.range
        let currentFont = ctx.storage.attribute(.font, at: whole.location, effectiveRange: nil) as? NSFont ?? Theme.bodyFont
        let italicFont = NSFontManager.shared.convert(currentFont, toHaveTrait: .italicFontMask)
        ctx.storage.addAttribute(.font, value: italicFont, range: whole)
        ctx.storage.markSyntax(NSRange(location: whole.location, length: markerLength))
        ctx.storage.markSyntax(NSRange(location: whole.location + whole.length - markerLength, length: markerLength))
    }

    private static func strikethrough() -> Rule {
        let pattern = regex("~~(?=\\S)([^\\n]+?)(?<=\\S)~~")
        return Rule(pattern: pattern, occupies: false) { match, ctx in
            let whole = match.range
            ctx.storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: whole)
            ctx.storage.markSyntax(NSRange(location: whole.location, length: 2))
            ctx.storage.markSyntax(NSRange(location: whole.location + whole.length - 2, length: 2))
        }
    }

    // MARK: - Links & images

    private static func inlineLink() -> Rule {
        let pattern = regex("(?<!\\!)\\[([^\\]\\n]+)\\]\\(([^)\\n]+)\\)")
        return Rule(pattern: pattern, occupies: false) { match, ctx in
            let whole = match.range
            let label = match.range(at: 1)
            let urlRange = match.range(at: 2)
            let urlString = (ctx.storage.string as NSString).substring(with: urlRange)
                .trimmingCharacters(in: .whitespaces)

            ctx.storage.addAttribute(.foregroundColor, value: Theme.linkColor, range: label)
            ctx.storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: label)
            ctx.storage.markSyntax(urlRange)
            ctx.storage.markSyntax(NSRange(location: whole.location, length: 1))
            ctx.storage.markSyntax(NSRange(location: label.location + label.length, length: 2))
            ctx.storage.markSyntax(NSRange(location: whole.location + whole.length - 1, length: 1))

            if let url = safeURL(from: urlString) {
                ctx.storage.addAttribute(.link, value: url, range: label)
            }
        }
    }

    /// Allowlist the URL schemes that may be made clickable. `NSTextView`
    /// opens clicked `.link` values via `NSWorkspace`, which honours
    /// `file://`, custom app schemes, and other vectors a hostile `.md`
    /// source should not be able to trigger with one click.
    private static func safeURL(from string: String) -> URL? {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased() else {
            return nil
        }
        let allowed: Set<String> = ["http", "https", "mailto"]
        return allowed.contains(scheme) ? url : nil
    }

    private static func image() -> Rule {
        // `![alt](url)` — same shape as a link with a `!` prefix. We dim
        // the whole thing (can't render the bitmap inside a text view
        // without replacing source characters); the alt text remains
        // legible, the URL is marked syntax.
        let pattern = regex("!\\[([^\\]\\n]*)\\]\\(([^)\\n]+)\\)")
        return Rule(pattern: pattern, occupies: false) { match, ctx in
            let whole = match.range
            let alt = match.range(at: 1)
            let urlRange = match.range(at: 2)

            ctx.storage.addAttribute(.foregroundColor, value: Theme.secondaryColor, range: alt)
            ctx.storage.markSyntax(urlRange)
            ctx.storage.markSyntax(NSRange(location: whole.location, length: 2))         // `![`
            ctx.storage.markSyntax(NSRange(location: alt.location + alt.length, length: 2)) // `](`
            ctx.storage.markSyntax(NSRange(location: whole.location + whole.length - 1, length: 1)) // `)`
        }
    }

    private static func autolink() -> Rule {
        // `<https://example.com>` or `<user@example.com>`.
        let pattern = regex("<((?:https?://|mailto:)[^>\\s]+|[\\w._%+-]+@[\\w.-]+\\.[A-Za-z]{2,})>")
        return Rule(pattern: pattern, occupies: false) { match, ctx in
            let whole = match.range
            let inside = match.range(at: 1)
            ctx.storage.markSyntax(NSRange(location: whole.location, length: 1))
            ctx.storage.markSyntax(NSRange(location: whole.location + whole.length - 1, length: 1))
            ctx.storage.addAttribute(.foregroundColor, value: Theme.linkColor, range: inside)
            ctx.storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: inside)

            let raw = (ctx.storage.string as NSString).substring(with: inside)
            let urlString = raw.contains("@") && !raw.hasPrefix("mailto:") ? "mailto:" + raw : raw
            if let url = safeURL(from: urlString) {
                ctx.storage.addAttribute(.link, value: url, range: inside)
            }
        }
    }

    private static func referenceLink() -> Rule {
        // `[label][ref]` or `[label][]` — we can't resolve the ref without
        // a full two-pass parse, but we style the label as link-coloured
        // and mark the ref as syntax. The reference definition rule takes
        // care of the `[ref]: url` definitions elsewhere.
        let pattern = regex("(?<!\\!)\\[([^\\]\\n]+)\\]\\[([^\\]\\n]*)\\]")
        return Rule(pattern: pattern, occupies: false) { match, ctx in
            let whole = match.range
            let label = match.range(at: 1)
            let ref = match.range(at: 2)
            ctx.storage.addAttribute(.foregroundColor, value: Theme.linkColor, range: label)
            ctx.storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: label)
            ctx.storage.markSyntax(NSRange(location: whole.location, length: 1))
            ctx.storage.markSyntax(NSRange(location: label.location + label.length, length: 2))
            ctx.storage.markSyntax(ref)
            ctx.storage.markSyntax(NSRange(location: whole.location + whole.length - 1, length: 1))
        }
    }

    private static func referenceDefinition() -> Rule {
        // `[ref]: https://example.com "Optional Title"` at the start of a line.
        let pattern = regex("(?m)^(\\[[^\\]\\n]+\\]):\\s+(\\S+)(\\s+\"[^\"\\n]*\")?\\s*$")
        return Rule(pattern: pattern, occupies: false) { match, ctx in
            let whole = match.range
            ctx.storage.addAttribute(.foregroundColor, value: Theme.secondaryColor, range: whole)
            let label = match.range(at: 1)
            ctx.storage.addAttribute(.foregroundColor, value: Theme.linkColor, range: label)
        }
    }

    private static func footnoteReference() -> Rule {
        // `[^1]` inline — render slightly raised and dimmed.
        let pattern = regex("\\[\\^([^\\]\\n]+)\\]")
        return Rule(pattern: pattern, occupies: false) { match, ctx in
            let whole = match.range
            ctx.storage.addAttribute(.foregroundColor, value: Theme.linkColor, range: whole)
            ctx.storage.addAttribute(.baselineOffset, value: 3, range: whole)
            let smallFont = NSFont.systemFont(ofSize: Theme.bodyFont.pointSize * 0.8)
            ctx.storage.addAttribute(.font, value: smallFont, range: whole)
        }
    }

    private static func footnoteDefinition() -> Rule {
        // `[^1]: footnote text` at start of a line.
        let pattern = regex("(?m)^(\\[\\^[^\\]\\n]+\\]):\\s*(.+)$")
        return Rule(pattern: pattern, occupies: false) { match, ctx in
            let label = match.range(at: 1)
            let body = match.range(at: 2)
            ctx.storage.addAttribute(.foregroundColor, value: Theme.linkColor, range: label)
            ctx.storage.addAttribute(.foregroundColor, value: Theme.secondaryColor, range: body)
            let italic = NSFontManager.shared.convert(Theme.bodyFont, toHaveTrait: .italicFontMask)
            ctx.storage.addAttribute(.font, value: italic, range: body)
        }
    }

    private static func hardLineBreak() -> Rule {
        // Two spaces before a newline = hard break. We highlight the two
        // trailing spaces so the writer can see the break is there.
        let pattern = regex("(  )\\n")
        return Rule(pattern: pattern, occupies: false) { match, ctx in
            let spaces = match.range(at: 1)
            ctx.storage.addAttribute(.backgroundColor, value: Theme.codeBackground, range: spaces)
            ctx.storage.markSyntax(spaces)
        }
    }

    private static func escape() -> Rule {
        // `\*`, `\_`, `\\`, etc. — dim the backslash so the next character
        // reads as the literal. Note: because escape runs last, any prior
        // emphasis rule that would have consumed the marker has already
        // fired. This is imperfect vs. a real parser but good enough for
        // readable source.
        let pattern = regex("\\\\[\\\\`*_{}\\[\\]()#+\\-.!>~|]")
        return Rule(pattern: pattern, occupies: false) { match, ctx in
            let slash = NSRange(location: match.range.location, length: 1)
            ctx.storage.markSyntax(slash)
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
