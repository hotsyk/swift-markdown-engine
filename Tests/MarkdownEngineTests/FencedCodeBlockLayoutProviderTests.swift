import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@Suite("Fenced code block layout provider")
struct FencedCodeBlockLayoutProviderTests {
    private let fontSize: CGFloat = 14
    private var fontName: String { NSFont.systemFont(ofSize: fontSize).fontName }

    private struct FixedProvider: FencedCodeBlockLayoutProvider {
        let multiplier: CGFloat

        func lineHeightMultiplier(for request: FencedCodeBlockLayoutRequest) -> CGFloat {
            multiplier
        }

        func fingerprint() -> AnyHashable { multiplier }
    }

    private struct MermaidProvider: FencedCodeBlockLayoutProvider {
        func lineHeightMultiplier(for request: FencedCodeBlockLayoutRequest) -> CGFloat {
            request.infoString == "mermaid theme=dark" && request.code == "graph TD\n" ? 3 : 1
        }

        func fingerprint() -> AnyHashable { "mermaid-layout-v1" }
    }

    private func styles(
        for text: String,
        provider: any FencedCodeBlockLayoutProvider = NoOpFencedCodeBlockLayoutProvider()
    ) -> [StyledRange] {
        var configuration = MarkdownEditorConfiguration.default
        configuration.services.fencedCodeBlockLayout = provider
        return MarkdownASTStyler.styleAttributes(
            text: text,
            fontName: fontName,
            fontSize: fontSize,
            configuration: configuration
        )
    }

    private func paragraphStyle(in styles: [StyledRange], at location: Int) -> NSParagraphStyle? {
        styles.last { NSLocationInRange(location, $0.range) && $0.attributes[.paragraphStyle] != nil }?
            .attributes[.paragraphStyle] as? NSParagraphStyle
    }

    private var defaultCodeLineHeight: CGFloat {
        let configuration = MarkdownEditorConfiguration.default
        let codeFont = configuration.services.syntaxHighlighter.codeFont(
            size: round(fontSize * configuration.codeBlock.fontSizeScale)
        )
        return ceil(codeFont.ascender - codeFont.descender + codeFont.leading)
    }

    @Test("default provider preserves code paragraph metrics")
    func defaultMetricsAreUnchanged() {
        let text = "```swift\nlet x = 1\n```\nafter"
        let style = paragraphStyle(in: styles(for: text), at: 0)

        #expect(style?.minimumLineHeight == defaultCodeLineHeight)
        #expect(style?.maximumLineHeight == defaultCodeLineHeight)
    }

    @Test("matching info string enlarges only its fenced block")
    func languageSpecificMultiplierDoesNotAffectSecondBlock() {
        let text = "```mermaid theme=dark\ngraph TD\n```\n\n```swift\nlet x = 1\n```\nafter"
        let styled = styles(for: text, provider: MermaidProvider())
        let ns = text as NSString
        let mermaid = paragraphStyle(in: styled, at: ns.range(of: "graph TD").location)
        let swift = paragraphStyle(in: styled, at: ns.range(of: "let x = 1").location)

        #expect(mermaid?.minimumLineHeight == defaultCodeLineHeight * 3)
        #expect(mermaid?.maximumLineHeight == defaultCodeLineHeight * 3)
        #expect(swift?.minimumLineHeight == defaultCodeLineHeight)
        #expect(swift?.maximumLineHeight == defaultCodeLineHeight)
    }

    @MainActor
    @Test("multiplied paragraph metrics push following content without changing source")
    func multiplierChangesTextLayout() {
        let text = "```mermaid\ngraph TD\n```\nafter"

        func followingLineY(provider: any FencedCodeBlockLayoutProvider) -> CGFloat {
            let storage = NSTextStorage(string: text, attributes: [.font: NSFont.systemFont(ofSize: fontSize)])
            for (range, attributes) in styles(for: text, provider: provider) {
                storage.addAttributes(attributes, range: range)
            }
            #expect(storage.string == text)
            let layoutManager = NSLayoutManager()
            let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
            storage.addLayoutManager(layoutManager)
            layoutManager.addTextContainer(container)
            layoutManager.ensureLayout(for: container)
            let glyph = layoutManager.glyphIndexForCharacter(at: (text as NSString).range(of: "after").location)
            return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
        }

        let defaultY = followingLineY(provider: NoOpFencedCodeBlockLayoutProvider())
        let enlargedY = followingLineY(provider: FixedProvider(multiplier: 3))

        #expect(enlargedY > defaultY)
    }

    @Test("multipliers below one and non-finite values preserve default metrics")
    func shrinkingAndInvalidMultipliersFallBack() {
        let text = "```\ncode\n```"
        for value in [CGFloat.nan, .infinity, -.infinity, -1, 0, 0.01, 0.5] {
            let style = paragraphStyle(in: styles(for: text, provider: FixedProvider(multiplier: value)), at: 0)
            #expect(style?.minimumLineHeight == defaultCodeLineHeight)
            #expect(style?.maximumLineHeight == defaultCodeLineHeight)
        }
    }

    @MainActor
    @Test("changing only the fenced-code provider fingerprint is detected")
    func fencedCodeFingerprintTriggersServiceRefresh() {
        let coordinator = NativeTextViewCoordinator(
            text: .constant(""),
            fontName: fontName,
            fontSize: fontSize,
            isWikiLinkActive: .constant(false),
            onLinkClick: nil,
            onInlineSelectionChange: nil
        )
        var services = MarkdownEditorServices.default
        services.fencedCodeBlockLayout = FixedProvider(multiplier: 1)
        _ = coordinator.updateServiceFingerprints(for: services)

        services.fencedCodeBlockLayout = FixedProvider(multiplier: 2)
        let changes = coordinator.updateServiceFingerprints(for: services)

        #expect(changes.images == false)
        #expect(changes.wikiLinks == false)
        #expect(changes.fencedCodeBlockLayout == true)
        #expect(coordinator.lastFencedCodeBlockLayoutFingerprint == AnyHashable(CGFloat(2)))
    }

    @Test("finite multipliers have an upper sanity bound")
    func multiplierIsBounded() {
        let text = "```\ncode\n```"
        let style = paragraphStyle(in: styles(for: text, provider: FixedProvider(multiplier: 1_000)), at: 0)

        #expect(style?.minimumLineHeight == defaultCodeLineHeight * 20)
        #expect(style?.maximumLineHeight == defaultCodeLineHeight * 20)
    }
}
