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

    @Test("runtime typewriter-to-Off transition cancels queued centering and normalizes geometry")
    func runtimeOffTransitionCancelsQueuedCentering() async {
        _ = NSApplication.shared
        let viewport = NSSize(width: 600, height: 320)
        let scrollView = ClampedScrollView(frame: NSRect(origin: .zero, size: viewport))
        let textView = NativeTextView(
            frame: NSRect(x: 0, y: 0, width: viewport.width, height: 0)
        )
        var typewriterConfiguration = MarkdownEditorConfiguration.default
        typewriterConfiguration.focusMode = .typewriter
        typewriterConfiguration.overscroll.maxPoints = 24
        textView.configuration = typewriterConfiguration
        textView.overscrollPercent = typewriterConfiguration.overscroll.percent
        textView.maxOverscrollPoints = typewriterConfiguration.overscroll.maxPoints
        textView.minOverscrollPoints = typewriterConfiguration.overscroll.minPoints
        textView.autoresizingMask = []

        let container = NativeTextViewContainer(frame: NSRect(origin: .zero, size: viewport))
        container.autoresizingMask = [.width]
        container.textView = textView
        container.addSubview(textView)
        scrollView.documentView = container
        container.headerHeight = 36

        let text = (0..<80).map { "Line \($0)" }.joined(separator: "\n")
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
        coordinator.configuration = typewriterConfiguration
        coordinator.textView = textView
        textView.delegate = coordinator

        textView.pendingFullLayoutMeasure = true
        textView.recalcOverscroll(for: scrollView, debugTag: "runtime-off-transition-test")
        #expect(textView.activeTopOverscroll >= viewport.height / 2)
        let typewriterBottomOverscroll = textView.activeBottomOverscroll

        guard let queuedGeneration = coordinator.scheduleTypewriterCentering(for: textView) else {
            Issue.record("Typewriter centering request was not queued")
            return
        }
        #expect(scrollView.isCurrentTypewriterCenteringRequest(queuedGeneration))

        // Give the production update boundary an invalid origin to normalize.
        // The queued block cannot drain in this main-actor turn.
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 10_000))
        var offConfiguration = typewriterConfiguration
        offConfiguration.focusMode = .disabled
        let wrapper = NativeTextViewWrapper(
            text: .constant(text),
            configuration: offConfiguration
        )
        wrapper.synchronizeFocusMode(to: textView, coordinator: coordinator)

        #expect(coordinator.configuration.focusMode == .disabled)
        #expect(textView.configuration.focusMode == .disabled)
        #expect(!scrollView.isCurrentTypewriterCenteringRequest(queuedGeneration))
        #expect(textView.activeTopOverscroll == 0)
        #expect(textView.activeBottomOverscroll < typewriterBottomOverscroll)
        #expect(textView.activeBottomOverscroll <= typewriterConfiguration.overscroll.maxPoints)
        #expect(textView.frame.minY == container.headerHeight)
        #expect(
            abs(container.scrollableContentHeight
                - (container.headerHeight + textView.scrollableContentHeight)) <= 0.5
        )
        #expect(abs(container.frame.height - max(textView.frame.maxY, viewport.height)) <= 0.5)

        let minY = -scrollView.contentInsets.top
        let maxY = max(minY, container.scrollableContentHeight - viewport.height)
        let normalizedOrigin = scrollView.contentView.bounds.origin
        #expect(normalizedOrigin.y >= minY)
        #expect(normalizedOrigin.y <= maxY)

        // Drain the stale request and prove it cannot re-center the clip view.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
        #expect(scrollView.contentView.bounds.origin == normalizedOrigin)
    }

    private func renderingAttributes(
        _ textView: NSTextView,
        at utf16Location: Int
    ) -> [NSAttributedString.Key: Any] {
        guard let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager else { return [:] }
        let documentStart = contentManager.documentRange.location
        var result: [NSAttributedString.Key: Any] = [:]
        layoutManager.enumerateRenderingAttributes(from: documentStart, reverse: false) {
            _, attributes, textRange in
            let start = contentManager.offset(from: documentStart, to: textRange.location)
            let end = contentManager.offset(from: documentStart, to: textRange.endLocation)
            if utf16Location >= start && utf16Location < end {
                result = attributes
                return false
            }
            return true
        }
        return result
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

        coordinator.synchronizeFocusMode(.disabled, to: textView)
        #expect(textView.activeTopOverscroll == 0)
        #expect(textView.activeBottomOverscroll <= configuration.overscroll.maxPoints)
        #expect(textView.frame.minY == container.headerHeight)
    }

    @Test(
        "runtime transition from typewriter synchronizes rendering and geometry",
        arguments: [FocusMode.sentence, .paragraph, .disabled]
    )
    func runtimeTransitionFromTypewriter(destination: FocusMode) async {
        _ = NSApplication.shared
        let viewport = NSSize(width: 600, height: 320)
        let scrollView = ClampedScrollView(frame: NSRect(origin: .zero, size: viewport))
        let textView = NativeTextView(
            frame: NSRect(x: 0, y: 0, width: viewport.width, height: 0)
        )
        var configuration = MarkdownEditorConfiguration.default
        configuration.focusMode = .typewriter
        configuration.overscroll.maxPoints = 24
        textView.configuration = configuration
        textView.overscrollPercent = configuration.overscroll.percent
        textView.maxOverscrollPoints = configuration.overscroll.maxPoints
        textView.minOverscrollPoints = configuration.overscroll.minPoints
        textView.autoresizingMask = []

        let container = NativeTextViewContainer(frame: NSRect(origin: .zero, size: viewport))
        container.autoresizingMask = [.width]
        container.textView = textView
        container.addSubview(textView)
        scrollView.documentView = container
        container.headerHeight = 36

        let text = "First sentence. Focus sentence.\nSecond paragraph."
        let focusLocation = (text as NSString).range(of: "Focus").location
        let secondParagraphLocation = (text as NSString).range(of: "Second").location
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
        coordinator.rebuildTextStorageAndStyle(textView, from: text, invalidateLayout: true)
        textView.setSelectedRange(NSRange(location: focusLocation, length: 0))

        textView.pendingFullLayoutMeasure = true
        textView.recalcOverscroll(for: scrollView, debugTag: "focus-transition-test")
        #expect(textView.activeTopOverscroll >= viewport.height / 2)
        #expect(textView.activeBottomOverscroll >= viewport.height / 2)
        let typewriterBottomOverscroll = textView.activeBottomOverscroll

        // Leave both a known centering request and an out-of-range origin for
        // the transition to cancel and clamp synchronously.
        guard let queuedGeneration = coordinator.scheduleTypewriterCentering(for: textView) else {
            Issue.record("Typewriter centering request was not queued")
            return
        }
        #expect(scrollView.isCurrentTypewriterCenteringRequest(queuedGeneration))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 10_000))
        var destinationConfiguration = configuration
        destinationConfiguration.focusMode = destination
        NativeTextViewWrapper(
            text: .constant(text),
            configuration: destinationConfiguration
        ).synchronizeFocusMode(to: textView, coordinator: coordinator)

        #expect(coordinator.configuration.focusMode == destination)
        #expect(!scrollView.isCurrentTypewriterCenteringRequest(queuedGeneration))
        #expect(textView.configuration.focusMode == destination)
        #expect(textView.activeTopOverscroll == 0)
        #expect(textView.activeBottomOverscroll < typewriterBottomOverscroll)
        #expect(
            textView.activeBottomOverscroll
                <= max(configuration.overscroll.minPoints, configuration.overscroll.maxPoints)
        )
        #expect(textView.frame.minY == container.headerHeight)
        let minY = -scrollView.contentInsets.top
        let maxY = max(minY, container.scrollableContentHeight - scrollView.contentView.bounds.height)
        #expect(scrollView.contentView.bounds.origin.y >= minY)
        #expect(scrollView.contentView.bounds.origin.y <= maxY)

        let muted = configuration.theme.mutedText
        let firstRendering = renderingAttributes(textView, at: 1)[.markdownFocusForeground] as? NSColor
        let focusRendering = renderingAttributes(textView, at: focusLocation)[.markdownFocusForeground]
        let secondRendering = renderingAttributes(
            textView,
            at: secondParagraphLocation
        )[.markdownFocusForeground] as? NSColor
        switch destination {
        case .sentence:
            #expect(firstRendering == muted)
            #expect(focusRendering == nil)
            #expect(secondRendering == muted)
        case .paragraph:
            #expect(firstRendering == nil)
            #expect(focusRendering == nil)
            #expect(secondRendering == muted)
        case .disabled:
            #expect(firstRendering == nil)
            #expect(focusRendering == nil)
            #expect(secondRendering == nil)
        case .typewriter:
            Issue.record("Typewriter is not a transition destination in this test")
        }

        let normalizedOrigin = scrollView.contentView.bounds.origin
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(scrollView.contentView.bounds.origin == normalizedOrigin)
    }
}
