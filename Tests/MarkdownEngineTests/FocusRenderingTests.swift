//
//  FocusRenderingTests.swift
//  MarkdownEngineTests
//
//  Focus dimming must remain a transient TextKit rendering concern. Authored
//  Markdown, extension, and find attributes must survive toggling it off.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

private struct FocusInvertingHighlight: MarkdownExtension {
    var id: String { "focus-rendering-highlight" }
    var inline: InlineSyntax? { InlineSyntax(open: "==", close: "==") }

    func contentAttributes(theme: MarkdownEditorTheme) -> [NSAttributedString.Key: Any] {
        [.backgroundColor: NSColor.white, .foregroundColor: NSColor.black]
    }

    func html(childrenHTML: String) -> String { "<mark>\(childrenHTML)</mark>" }
}

@MainActor
@Suite("Focus rendering is non-destructive")
struct FocusRenderingTests {
    private static let text = "plain ==marked==. Tail sentence."
    private static let markedLocation = 8
    private static let tailLocation = 19

    private func makeEditor(
        mode: FocusMode,
        text: Binding<String>? = nil
    ) -> (NativeTextViewCoordinator, NativeTextView) {
        _ = NSApplication.shared
        let coordinator = NativeTextViewCoordinator(
            text: text ?? .constant(Self.text),
            fontName: "SF Pro",
            fontSize: 16,
            isWikiLinkActive: .constant(false),
            onLinkClick: nil,
            onInlineSelectionChange: nil
        )
        coordinator.configuration.extensions = [FocusInvertingHighlight()]
        coordinator.configuration.focusMode = mode

        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        textView.isEditable = true
        textView.delegate = coordinator
        textView.setSelectedRange(NSRange(location: Self.tailLocation, length: 0))
        coordinator.textView = textView
        coordinator.rebuildTextStorageAndStyle(textView, from: Self.text)
        return (coordinator, textView)
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

    @Test("sentence dimming overlays but never rewrites extension ink")
    func dimmingLeavesAuthoredForegroundUntouched() {
        let (_, textView) = makeEditor(mode: .sentence)

        let storedForeground = textView.textStorage?.attribute(
            .foregroundColor,
            at: Self.markedLocation,
            effectiveRange: nil
        ) as? NSColor
        #expect(storedForeground == .black)
        #expect(renderingAttributes(textView, at: Self.markedLocation)[.foregroundColor] as? NSColor
                == textView.configuration.theme.mutedText)
        #expect(renderingAttributes(textView, at: Self.tailLocation)[.foregroundColor] == nil)
    }

    @Test("theme changes and Markdown restyles preserve both styling owners")
    func themeAndRestyleRefreshFocusWithoutRewritingExtensionInk() {
        let (coordinator, textView) = makeEditor(mode: .sentence)
        let fullRange = NSRange(location: 0, length: (Self.text as NSString).length)

        coordinator.configuration.theme.bodyText = .systemGreen
        coordinator.configuration.theme.mutedText = .systemPurple
        coordinator.rebuildTextStorageAndStyle(textView, from: Self.text, invalidateLayout: true)

        #expect(textView.textStorage?.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor == .systemGreen)
        #expect(textView.textStorage?.attribute(.foregroundColor, at: Self.markedLocation, effectiveRange: nil) as? NSColor == .black)
        #expect(textView.textStorage?.attribute(.backgroundColor, at: Self.markedLocation, effectiveRange: nil) as? NSColor == .white)
        #expect(renderingAttributes(textView, at: Self.markedLocation)[.foregroundColor] as? NSColor == .systemPurple)
        #expect(renderingAttributes(textView, at: Self.tailLocation)[.foregroundColor] == nil)

        coordinator.restyleTextView(textView, paragraphCandidates: [fullRange])

        #expect(textView.textStorage?.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor == .systemGreen)
        #expect(textView.textStorage?.attribute(.foregroundColor, at: Self.markedLocation, effectiveRange: nil) as? NSColor == .black)
        #expect(textView.textStorage?.attribute(.backgroundColor, at: Self.markedLocation, effectiveRange: nil) as? NSColor == .white)
        #expect(renderingAttributes(textView, at: Self.markedLocation)[.foregroundColor] as? NSColor == .systemPurple)
        #expect(renderingAttributes(textView, at: Self.tailLocation)[.foregroundColor] == nil)
    }

    @Test("disabled and enabled transitions restore and reapply focus exactly")
    func focusTransitionsRestoreAuthoredAppearance() {
        let (coordinator, textView) = makeEditor(mode: .sentence)

        #expect(renderingAttributes(textView, at: Self.markedLocation)[.foregroundColor] as? NSColor
                == coordinator.configuration.theme.mutedText)
        coordinator.configuration.focusMode = .disabled
        coordinator.applyFocusRendering(to: textView)
        #expect(renderingAttributes(textView, at: Self.markedLocation)[.foregroundColor] == nil)
        #expect(textView.textStorage?.attribute(.foregroundColor, at: Self.markedLocation, effectiveRange: nil) as? NSColor == .black)
        #expect(textView.textStorage?.attribute(.backgroundColor, at: Self.markedLocation, effectiveRange: nil) as? NSColor == .white)

        coordinator.configuration.focusMode = .sentence
        coordinator.applyFocusRendering(to: textView)
        #expect(renderingAttributes(textView, at: Self.markedLocation)[.foregroundColor] as? NSColor
                == coordinator.configuration.theme.mutedText)
        #expect(renderingAttributes(textView, at: Self.tailLocation)[.foregroundColor] == nil)
        #expect(textView.textStorage?.attribute(.foregroundColor, at: Self.tailLocation, effectiveRange: nil) as? NSColor
                == coordinator.configuration.theme.bodyText)
    }

    @Test("disabling removes only focus foreground and reveals authored appearance")
    func disablingRestoresExtensionAndFindAppearance() {
        let (coordinator, textView) = makeEditor(mode: .paragraph)
        guard let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager,
              let start = contentManager.location(
                contentManager.documentRange.location,
                offsetBy: Self.markedLocation
              ),
              let end = contentManager.location(start, offsetBy: 6),
              let markedRange = NSTextRange(location: start, end: end) else {
            Issue.record("TextKit range setup failed")
            return
        }

        // Model find's independent rendering owner. Focus clearing must not
        // blanket-clear rendering attributes or authored storage attributes.
        layoutManager.addRenderingAttribute(.backgroundColor, value: NSColor.systemYellow, for: markedRange)
        coordinator.applyFocusRendering(to: textView)

        coordinator.configuration.focusMode = .disabled
        coordinator.applyFocusRendering(to: textView)

        let rendered = renderingAttributes(textView, at: Self.markedLocation)
        #expect(rendered[.foregroundColor] == nil)
        #expect(rendered[.backgroundColor] as? NSColor == .systemYellow)
        #expect(textView.textStorage?.attribute(.foregroundColor, at: Self.markedLocation, effectiveRange: nil) as? NSColor == .black)
        #expect(textView.textStorage?.attribute(.backgroundColor, at: Self.markedLocation, effectiveRange: nil) as? NSColor == .white)
    }

    @Test("focus rendering never changes bound text or the undo stack")
    func focusIsNotAnEditingOperation() {
        var boundText = Self.text
        let binding = Binding(
            get: { boundText },
            set: { boundText = $0 }
        )
        let (coordinator, textView) = makeEditor(mode: .sentence, text: binding)
        coordinator.documentId = "focus-rendering-document"
        guard let undoManager = coordinator.undoManager(for: textView) else {
            Issue.record("Coordinator did not provide an undo manager")
            return
        }
        let undoTarget = NSObject()
        undoManager.groupsByEvent = false
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: undoTarget) { _ in }
        undoManager.endUndoGrouping()
        #expect(undoManager.canUndo)

        textView.setSelectedRange(NSRange(location: 1, length: 0))
        coordinator.applyFocusRendering(to: textView)
        coordinator.configuration.focusMode = .disabled
        coordinator.applyFocusRendering(to: textView)
        coordinator.configuration.focusMode = .paragraph
        coordinator.applyFocusRendering(to: textView)

        #expect(boundText == Self.text)
        #expect(textView.string == Self.text)
        #expect(undoManager.canUndo)

        // A clean stack also stays clean, proving focus did not merely preserve
        // availability while appending another action above the sentinel.
        undoManager.removeAllActions()
        coordinator.configuration.focusMode = .sentence
        coordinator.applyFocusRendering(to: textView)
        coordinator.configuration.focusMode = .disabled
        coordinator.applyFocusRendering(to: textView)
        #expect(!undoManager.canUndo)
        #expect(boundText == Self.text)
    }
}
