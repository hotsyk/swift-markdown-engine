//
//  TypewriterFocusTests.swift
//  MarkdownEngineTests
//
//  Deterministic centering geometry and a real TextKit 2 scroll-stack check.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Typewriter focus centering")
struct TypewriterFocusTests {
    @Test("target places the line in the unobscured viewport center")
    func targetOffsetUsesViewportInsets() {
        let target = TypewriterCenteringGeometry.targetScrollOriginY(
            lineRect: CGRect(x: 0, y: 900, width: 400, height: 20),
            viewportBounds: CGRect(x: 0, y: 125, width: 600, height: 500),
            contentInsets: NSEdgeInsets(top: 40, left: 0, bottom: 20, right: 0)
        )

        // Line midpoint 910; unobscured center is 40 + (500 - 60) / 2 = 260.
        #expect(target == 650)
    }

    @Test("top and bottom slack cover both distances from the viewport center")
    func requiredSlackUsesDistancesAroundViewportCenter() {
        let insets = NSEdgeInsets(top: 20, left: 0, bottom: 40, right: 0)
        let topSlack = TypewriterCenteringGeometry.requiredTopSlack(
            viewportHeight: 800,
            contentInsets: insets
        )
        let bottomSlack = TypewriterCenteringGeometry.requiredBottomSlack(
            viewportHeight: 800,
            contentInsets: insets
        )

        // Unobscured center is 20 + 740 / 2 = 390; 410 points remain below it.
        #expect(topSlack == 390)
        #expect(bottomSlack == 410)
    }

    @Test("final TextKit line can be centered and survives scroll clamping")
    func finalLineCentersInRealScrollStack() {
        _ = NSApplication.shared
        let viewport = NSSize(width: 600, height: 800)
        let scrollView = ClampedScrollView(frame: NSRect(origin: .zero, size: viewport))
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: viewport.width, height: 0))
        var configuration = MarkdownEditorConfiguration.default
        configuration.focusMode = .typewriter
        configuration.overscroll.maxPoints = 24 // deliberately below the required half viewport
        textView.configuration = configuration
        textView.autoresizingMask = []

        let container = NativeTextViewContainer(frame: NSRect(origin: .zero, size: viewport))
        container.autoresizingMask = [.width]
        container.textView = textView
        container.addSubview(textView)
        scrollView.documentView = container

        let text = (0..<100).map { "Line \($0)" }.joined(separator: "\n")
        textView.string = text
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))

        let coordinator = NativeTextViewCoordinator(
            text: .constant(text),
            fontName: "SF Pro",
            fontSize: 16,
            isWikiLinkActive: .constant(false),
            onLinkClick: nil,
            onInlineSelectionChange: nil
        )
        coordinator.configuration = configuration
        coordinator.textView = textView
        textView.delegate = coordinator

        textView.pendingFullLayoutMeasure = true
        textView.recalcOverscroll(for: scrollView, debugTag: "typewriter-test")
        coordinator.centerTypewriterCaret(in: textView)

        guard let localLine = textView.typewriterLineRect(atUTF16Offset: (text as NSString).length) else {
            Issue.record("TextKit did not resolve the final visual line")
            return
        }
        let documentLine = localLine.offsetBy(dx: textView.frame.minX, dy: textView.frame.minY)
        let expectedY = TypewriterCenteringGeometry.targetScrollOriginY(
            lineRect: documentLine,
            viewportBounds: scrollView.contentView.bounds,
            contentInsets: scrollView.contentInsets
        )
        let actualY = scrollView.contentView.bounds.origin.y
        let maxY = max(
            -scrollView.contentInsets.top,
            container.scrollableContentHeight - scrollView.contentView.bounds.height
        )

        #expect(textView.activeTopOverscroll >= viewport.height / 2)
        #expect(textView.activeBottomOverscroll >= viewport.height / 2)
        #expect(expectedY <= maxY + 0.5)
        #expect(abs(actualY - expectedY) <= 0.5)

        // The first line also has real document space above it, so centering is
        // not truncated by the clip view's minimum origin.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.centerTypewriterCaret(in: textView)
        guard let firstLocalLine = textView.typewriterLineRect(atUTF16Offset: 0) else {
            Issue.record("TextKit did not resolve the first visual line")
            return
        }
        let firstDocumentLine = firstLocalLine.offsetBy(
            dx: textView.frame.minX,
            dy: textView.frame.minY
        )
        let expectedFirstY = TypewriterCenteringGeometry.targetScrollOriginY(
            lineRect: firstDocumentLine,
            viewportBounds: scrollView.contentView.bounds,
            contentInsets: scrollView.contentInsets
        )
        #expect(expectedFirstY >= -scrollView.contentInsets.top)
        #expect(abs(scrollView.contentView.bounds.origin.y - expectedFirstY) <= 0.5)

        coordinator.configuration.focusMode = .disabled
        textView.configuration.focusMode = .disabled
        coordinator.applyFocusRendering(to: textView)
        #expect(textView.activeTopOverscroll == 0)
        #expect(textView.activeBottomOverscroll <= configuration.overscroll.maxPoints)
        #expect(textView.frame.minY == container.headerHeight)
    }
}
