import AppKit

/// Typography for Reader, grounded in classical sources.
///
/// Sources:
/// - Bringhurst, *The Elements of Typographic Style*, §2.1.2 (measure),
///   §2.2.2 (leading), §2.3 (paragraphs), §3.1 (emphasis), §3.2 (figures
///   and ligatures), §8.1 (type scale), §8.3 (contrast).
/// - Butterick, *Practical Typography* (screen point size, line spacing,
///   margins, code, links).
/// - Tufte's design principles (asymmetric margins, generous whitespace).
///
/// All colors are macOS semantic colors so Dark Mode adaptation is automatic
/// and matches Apple's own contrast calibration (system `labelColor` is
/// never pure black on pure white — Bringhurst §8.3 is already honored).
enum Theme {
    // MARK: Measure & scale

    /// 17pt body: top of Butterick's 15–25pt screen range; matches Apple HIG
    /// body metric. New York has a modest x-height so we stay large.
    static let bodyFontSize: CGFloat = 17

    /// 88% of body — Bringhurst §3.2.2: monospaced type reads optically larger
    /// than proportional type at the same point size.
    static let codeFontSize: CGFloat = 15

    /// Classical major third (5:4). Bringhurst §8.1 explicitly recommends the
    /// musical scales; 1.25 gives legible hierarchy without shouting.
    static let scaleRatio: CGFloat = 1.25

    /// Extra leading between lines, as a fraction of body size. Applied via
    /// `NSParagraphStyle.lineSpacing` so the line box (and the caret) stay at
    /// natural font height — only the gap between lines is enlarged.
    /// 0.35 × 17pt ≈ 6pt; combined with New York's ~20pt native line height
    /// this lands near Bringhurst §2.2.2's 1.2–1.45 range without stretching
    /// the caret.
    static let extraLeadingRatio: CGFloat = 0.35

    /// 66 characters at 17pt New York ≈ 640pt. Bringhurst §2.1.2: "66 is
    /// widely regarded as ideal." Acceptable range: 45–75.
    static let measure: CGFloat = 640

    /// Outer padding. Top clears the traffic-light zone (~28pt) with a full
    /// line-height of air on top of that — Tschichold's "quiet approach"
    /// to the first word.
    static let editorPadding = NSEdgeInsets(top: 72, left: 72, bottom: 56, right: 72)

    // MARK: Fonts — macOS system families only

    /// Body serif: New York (Apple's transitional serif). Cached — the
    /// styler hits this on every keystroke; descriptor building must not
    /// repeat. OpenType feature customization is avoided here because it
    /// has caused noticeable input stalls in live editing.
    static let bodyFont: NSFont = {
        let base = NSFont.systemFont(ofSize: bodyFontSize, weight: .regular)
        let descriptor = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
        return NSFont(descriptor: descriptor, size: bodyFontSize) ?? base
    }()

    private static var headingFontCache: [Int: NSFont] = [:]

    static func headingFont(level: Int) -> NSFont {
        if let cached = headingFontCache[level] { return cached }
        let size = headingSize(for: level)
        let weight: NSFont.Weight = level <= 2 ? .bold : .semibold
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let descriptor = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
        let font = NSFont(descriptor: descriptor, size: size) ?? base
        headingFontCache[level] = font
        return font
    }

    static func headingSize(for level: Int) -> CGFloat {
        let body = bodyFontSize
        switch level {
        case 1: return round(body * pow(scaleRatio, 3))   // 33.2
        case 2: return round(body * pow(scaleRatio, 2))   // 26.6 → 27
        case 3: return round(body * scaleRatio)           // 21.25 → 21
        case 4: return round(body * 1.125)                // 19.1 → 19
        case 5: return body                               // 17 (weight only)
        default: return body
        }
    }

    static var codeFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: codeFontSize, weight: .regular)
    }

    /// Chrome / UI (toolbar, status bar) — SF Pro small, never intrudes.
    static var uiFont: NSFont {
        NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    }

    // MARK: Colors — semantic only (Dark Mode automatic)

    /// Body text. Softened per Bringhurst §8.3 — never pure #000 on #FFF.
    /// Light: #1A1A1A (~90% black). Dark: #E8E4DB (~88% warm off-white)
    /// per Legge on stroke-width compensation on dark backgrounds.
    static var textColor: NSColor {
        NSColor(name: "readerText") { appearance in
            appearance.isDarkMode
                ? NSColor(red: 0xE8/255, green: 0xE4/255, blue: 0xDB/255, alpha: 1)
                : NSColor(red: 0x1A/255, green: 0x1A/255, blue: 0x1A/255, alpha: 1)
        }
    }

    /// Blockquote body. ~60% of text luminance.
    static var secondaryColor: NSColor {
        textColor.withAlphaComponent(0.6)
    }

    /// Syntax scaffolding (literal `*`, `#`, `>`, backticks, brackets).
    /// Present but quiet — skippable by the reader's eye, findable by the
    /// writer's. Faded on inactive lines, fully visible on the active line.
    static var syntaxColor: NSColor {
        textColor.withAlphaComponent(0.32)
    }

    /// Horizontal rules, quaternary ink.
    static var quaternaryColor: NSColor {
        textColor.withAlphaComponent(0.2)
    }

    /// Links: system accent. Butterick: color alone is enough.
    static var linkColor: NSColor { .linkColor }

    /// Inline code background: ~6% of the text color — just enough to
    /// distinguish a code span without breaking the line's color.
    static var codeBackground: NSColor {
        textColor.withAlphaComponent(0.06)
    }

    /// Warm off-white in light mode (Tufte tradition `#FDFCF8`), pure black
    /// in dark mode for that true night-mode feel.
    static var editorBackground: NSColor {
        NSColor(name: "readerPage") { appearance in
            appearance.isDarkMode
                ? .black
                : NSColor(red: 0xFD/255, green: 0xFC/255, blue: 0xF8/255, alpha: 1)
        }
    }

    static var chromeBackground: NSColor {
        NSColor(name: "readerChrome") { appearance in
            appearance.isDarkMode
                ? .black
                : NSColor(red: 0xF7/255, green: 0xF5/255, blue: 0xEF/255, alpha: 1)
        }
    }

    static var separator: NSColor {
        textColor.withAlphaComponent(0.08)
    }

    /// Current-line tint — an almost-invisible warm glow that tells the eye
    /// "you are here" without drawing attention. Alpha 3% per Victor's
    /// immediate-connection principle: present in peripheral vision only.
    static var currentLineTint: NSColor {
        NSColor.controlAccentColor.withAlphaComponent(0.035)
    }

    /// The striking color reserved for "mode on" indicators — an active
    /// format toggle, preview mode, etc. Deep scarlet in light mode (rich
    /// book-jacket red, not fire-truck), warm coral in dark (easy on the
    /// retina but unmistakable).
    static var activeAccent: NSColor {
        NSColor(name: "readerActive") { appearance in
            appearance.isDarkMode
                ? NSColor(red: 0xF0/255, green: 0x82/255, blue: 0x72/255, alpha: 1.0)
                : NSColor(red: 0xB0/255, green: 0x20/255, blue: 0x30/255, alpha: 1.0)
        }
    }
}

private extension NSAppearance {
    var isDarkMode: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
