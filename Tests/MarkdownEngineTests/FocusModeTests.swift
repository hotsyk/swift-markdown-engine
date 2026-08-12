//
//  FocusModeTests.swift
//  MarkdownEngineTests
//
//  Regression coverage for focus ranges, transient rendering, edit refreshes,
//  and deterministic typewriter geometry.
//

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MarkdownEngine

@Suite("Focus mode semantics")
struct FocusModeRangeTests {
    @Test("sentence punctuation and separators stay with the preceding sentence")
    func sentencePunctuation() {
        let text = "Question? Exclamation! Statement. Next"
        let nsText = text as NSString

        #expect(resolve(text, at: 3, mode: .sentence) == nsText.range(of: "Question? "))
        #expect(resolve(text, at: 14, mode: .sentence) == nsText.range(of: "Exclamation! "))
        #expect(resolve(text, at: 27, mode: .sentence) == nsText.range(of: "Statement. "))
    }

    @Test("the final unterminated sentence owns an end-of-document caret")
    func finalUnterminatedSentenceAndEndCaret() {
        let text = "Finished. Still being written"
        let expected = (text as NSString).range(of: "Still being written")

        #expect(resolve(text, at: expected.location + 2, mode: .sentence) == expected)
        #expect(resolve(text, at: (text as NSString).length, mode: .sentence) == expected)
    }

    @Test("a nonempty selection is the focus instead of its containing unit")
    func selectionIsExactFocus() {
        let text = "First sentence.\nSecond paragraph."
        let selection = NSRange(location: 4, length: 19)

        #expect(FocusRangeResolver.resolve(in: text, selection: selection, mode: .sentence) == selection)
        #expect(FocusRangeResolver.resolve(in: text, selection: selection, mode: .paragraph) == selection)
    }

    @Test("ranges use UTF-16 coordinates for emoji and composed characters")
    func unicodeUsesUTF16Offsets() {
        let text = "👩🏽‍💻 writes. Cafe\u{301} continues"
        let nsText = text as NSString
        let second = nsText.range(of: "Cafe\u{301} continues")

        #expect(resolve(text, at: second.location, mode: .sentence) == second)
        #expect(resolve(text, at: nsText.length, mode: .sentence) == second)
    }

    @Test("empty text is safe for both range-based modes")
    func emptyText() {
        let empty = NSRange(location: 0, length: 0)

        #expect(resolve("", at: 0, mode: .sentence) == empty)
        #expect(resolve("", at: 0, mode: .paragraph) == empty)
    }

    @Test("paragraph modes respect CRLF and Unicode paragraph separators")
    func paragraphSeparators() {
        let text = "Alpha\r\nBeta\u{2029}Gamma"
        let nsText = text as NSString

        #expect(resolve(text, at: 1, mode: .paragraph) == nsText.range(of: "Alpha\r\n"))
        #expect(resolve(text, at: 8, mode: .paragraph) == nsText.range(of: "Beta\u{2029}"))
        #expect(resolve(text, at: nsText.length, mode: .paragraph) == nsText.range(of: "Gamma"))
    }

    @Test("typewriter target includes viewport origin and asymmetric safe-area insets")
    func typewriterTargetOffsets() {
        let target = TypewriterCenteringGeometry.targetScrollOriginY(
            lineRect: CGRect(x: 80, y: 735, width: 300, height: 30),
            viewportBounds: CGRect(x: 0, y: 140, width: 700, height: 460),
            contentInsets: NSEdgeInsets(top: 50, left: 12, bottom: 10, right: 12)
        )

        // The target is a scroll origin, so the existing viewport origin is not
        // added again: line midpoint 750 - unobscured center offset 250.
        #expect(target == 500)
    }

    private func resolve(_ text: String, at location: Int, mode: FocusMode) -> NSRange? {
        FocusRangeResolver.resolve(
            in: text,
            selection: NSRange(location: location, length: 0),
            mode: mode
        )
    }
}

@MainActor
@Suite("Focus coordinator updates")
struct FocusModeCoordinatorTests {
    private func makeEditor(
        _ text: String,
        mode: FocusMode,
        rawSource: Bool = false
    ) -> (NativeTextViewCoordinator, NativeTextView) {
        _ = NSApplication.shared
        let coordinator = NativeTextViewCoordinator(
            text: .constant(text),
            fontName: "SF Pro",
            fontSize: 16,
            isWikiLinkActive: .constant(false),
            onLinkClick: nil,
            onInlineSelectionChange: nil
        )
        coordinator.configuration.focusMode = mode
        coordinator.configuration.rawSourceMode = rawSource

        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        textView.isEditable = true
        textView.delegate = coordinator
        coordinator.textView = textView
        coordinator.rebuildTextStorageAndStyle(textView, from: text)
        return (coordinator, textView)
    }

    @Test("disabling focus removes every dimming overlay")
    func disablingRestoresRendering() {
        let text = "First paragraph.\nSecond paragraph."
        let (coordinator, textView) = makeEditor(text, mode: .paragraph)
        textView.setSelectedRange(NSRange(location: 20, length: 0))
        coordinator.applyFocusRendering(to: textView)

        #expect(renderedForeground(textView, at: 1) == coordinator.configuration.theme.mutedText)
        coordinator.configuration.focusMode = .disabled
        coordinator.applyFocusRendering(to: textView)
        #expect(renderedForeground(textView, at: 1) == nil)
        #expect(renderedForeground(textView, at: 20) == nil)
    }

    @Test("changing modes immediately switches the focused range")
    func modeChangesApplyImmediately() {
        let text = "First sentence. Second sentence.\nFinal paragraph."
        let (coordinator, textView) = makeEditor(text, mode: .sentence)
        let caret = (text as NSString).range(of: "Second").location
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        coordinator.applyFocusRendering(to: textView)

        #expect(renderedForeground(textView, at: 1) == coordinator.configuration.theme.mutedText)
        #expect(renderedForeground(textView, at: caret) == nil)

        coordinator.configuration.focusMode = .paragraph
        coordinator.applyFocusRendering(to: textView)
        #expect(renderedForeground(textView, at: 1) == nil)
        #expect(renderedForeground(textView, at: (text as NSString).range(of: "Final").location)
                == coordinator.configuration.theme.mutedText)
    }

    @Test("selection changes switch paragraph focus without rebuilding storage")
    func paragraphSwitching() {
        let text = "Alpha\nBeta\nGamma"
        let (coordinator, textView) = makeEditor(text, mode: .paragraph)

        textView.setSelectedRange(NSRange(location: 1, length: 0))
        coordinator.textViewDidChangeSelection(Notification(
            name: NSTextView.didChangeSelectionNotification,
            object: textView
        ))
        #expect(renderedForeground(textView, at: 7) == coordinator.configuration.theme.mutedText)

        textView.setSelectedRange(NSRange(location: 7, length: 0))
        coordinator.textViewDidChangeSelection(Notification(
            name: NSTextView.didChangeSelectionNotification,
            object: textView
        ))
        #expect(renderedForeground(textView, at: 1) == coordinator.configuration.theme.mutedText)
        #expect(renderedForeground(textView, at: 7) == nil)
    }

    @Test("textDidChange recomputes focus after sentence boundaries are edited")
    func editsUpdateFocus() {
        let original = "One Two."
        let (coordinator, textView) = makeEditor(original, mode: .sentence, rawSource: true)
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        coordinator.applyFocusRendering(to: textView)
        #expect(renderedForeground(textView, at: 1) == nil)

        textView.textStorage?.replaceCharacters(in: NSRange(location: 3, length: 0), with: ".")
        textView.setSelectedRange(NSRange(location: 6, length: 0))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))

        #expect(textView.string == "One. Two.")
        #expect(renderedForeground(textView, at: 1) == coordinator.configuration.theme.mutedText)
        #expect(renderedForeground(textView, at: 6) == nil)
    }

    private func renderedForeground(_ textView: NSTextView, at offset: Int) -> NSColor? {
        guard let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager else { return nil }
        let documentStart = contentManager.documentRange.location
        var color: NSColor?
        layoutManager.enumerateRenderingAttributes(from: documentStart, reverse: false) {
            _, attributes, range in
            let start = contentManager.offset(from: documentStart, to: range.location)
            let end = contentManager.offset(from: documentStart, to: range.endLocation)
            if offset >= start && offset < end {
                color = attributes[.markdownFocusForeground] as? NSColor
                return false
            }
            return true
        }
        return color
    }
}
