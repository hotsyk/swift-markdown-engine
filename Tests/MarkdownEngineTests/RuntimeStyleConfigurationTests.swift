import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

private struct FingerprintedHighlighter: SyntaxHighlighter {
    let styleFingerprint: Int

    func codeFont(size: CGFloat) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    func backgroundColor() -> NSColor { .clear }

    func highlight(code: String, language: String?) -> NSAttributedString? { nil }

    var appearanceDidChangeNotification: Notification.Name? { nil }
}

@Suite("Runtime style configuration")
struct RuntimeStyleConfigurationTests {
    @Test func fingerprintTracksRestyledFieldsAndAdoptionCopiesHighlighter() {
        let baseline = MarkdownEditorConfiguration.default.styleFingerprint
        var source = MarkdownEditorConfiguration.default
        source.theme.bodyText = .systemRed
        source.paragraph.lineHeightExtraSpacing += 1
        source.blockquote.extraLineHeight += 1
        source.headings.fontMultipliers[0] += 0.1
        source.services.syntaxHighlighter = FingerprintedHighlighter(styleFingerprint: 42)

        #expect(source.styleFingerprint != baseline)

        var target = MarkdownEditorConfiguration.default
        target.adoptStyle(from: source)

        #expect(target.theme.bodyText == source.theme.bodyText)
        #expect(target.paragraph.lineHeightExtraSpacing == source.paragraph.lineHeightExtraSpacing)
        #expect(target.blockquote.extraLineHeight == source.blockquote.extraLineHeight)
        #expect(target.headings.fontMultipliers == source.headings.fontMultipliers)
        #expect(target.services.syntaxHighlighter.styleFingerprint == 42)
        #expect(target.styleFingerprint == source.styleFingerprint)
    }
}
