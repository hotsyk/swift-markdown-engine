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
        let layoutDelegate = MarkdownLayoutManagerDelegate()
        coordinator.layoutDelegate = layoutDelegate
        textView.textLayoutManager?.delegate = layoutDelegate
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

    private func renderedBitmap(_ textView: NSTextView) -> NSBitmapImageRep {
        let manager = textView.textLayoutManager!
        manager.ensureLayout(for: manager.textContentManager!.documentRange)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 600,
            pixelsHigh: 400,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 600, height: 400)).fill()
        manager.enumerateTextLayoutFragments(
            from: manager.textContentManager!.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            fragment.draw(at: fragment.layoutFragmentFrame.origin, in: NSGraphicsContext.current!.cgContext)
            return true
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private func segmentRect(_ textView: NSTextView, range: NSRange) -> CGRect {
        let manager = textView.textLayoutManager!
        let content = manager.textContentManager!
        let documentStart = content.documentRange.location
        let start = content.location(documentStart, offsetBy: range.location)!
        let end = content.location(start, offsetBy: range.length)!
        var result = CGRect.null
        manager.enumerateTextSegments(
            in: NSTextRange(location: start, end: end)!,
            type: .selection,
            options: []
        ) { _, frame, _, _ in
            result = result.union(frame)
            return true
        }
        return result
    }

    private func differentPixels(
        _ lhs: NSBitmapImageRep,
        _ rhs: NSBitmapImageRep,
        in viewRect: CGRect
    ) -> Int {
        let scale = CGFloat(lhs.pixelsWide) / 600
        let x0 = max(0, Int(viewRect.minX * scale))
        let x1 = min(lhs.pixelsWide, Int(ceil(viewRect.maxX * scale)))
        let y0 = max(0, Int((400 - viewRect.maxY) * scale))
        let y1 = min(lhs.pixelsHigh, Int(ceil((400 - viewRect.minY) * scale)))
        var count = 0
        for y in y0..<y1 {
            for x in x0..<x1 where lhs.colorAt(x: x, y: y) != rhs.colorAt(x: x, y: y) {
                count += 1
            }
        }
        return count
    }

    private func matchingColorPixels(
        in bitmap: NSBitmapImageRep,
        viewRect: CGRect,
        color: NSColor
    ) -> Int {
        let expected = color.usingColorSpace(.deviceRGB)!
        let scale = CGFloat(bitmap.pixelsWide) / 600
        let x0 = max(0, Int(viewRect.minX * scale))
        let x1 = min(bitmap.pixelsWide, Int(ceil(viewRect.maxX * scale)))
        let y0 = max(0, Int((400 - viewRect.maxY) * scale))
        let y1 = min(bitmap.pixelsHigh, Int(ceil((400 - viewRect.minY) * scale)))
        var count = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if abs(pixel.redComponent - expected.redComponent) < 0.02,
                   abs(pixel.greenComponent - expected.greenComponent) < 0.02,
                   abs(pixel.blueComponent - expected.blueComponent) < 0.02 {
                    count += 1
                }
            }
        }
        return count
    }

    @Test("actual glyph output dims surrounding text and preserves the caret sentence")
    func actualGlyphOutputUsesFocusForeground() {
        let controlledText = "Dim sentence.\nFocus sentence."
        let focusLocation = (controlledText as NSString).range(of: "Focus").location
        let (coordinator, textView) = makeEditor(mode: .disabled)
        coordinator.configuration.theme.bodyText = .systemGreen
        coordinator.configuration.theme.mutedText = .magenta
        textView.drawsBackground = true
        textView.backgroundColor = .white
        coordinator.rebuildTextStorageAndStyle(textView, from: controlledText, invalidateLayout: true)
        textView.setSelectedRange(NSRange(location: focusLocation, length: 0))

        let authored = renderedBitmap(textView)
        let dimmedRect = segmentRect(textView, range: NSRange(location: 0, length: 13))
        let focusedRect = segmentRect(
            textView,
            range: NSRange(location: focusLocation, length: 5)
        )

        coordinator.configuration.focusMode = .sentence
        coordinator.applyFocusRendering(to: textView)
        let focused = renderedBitmap(textView)

        // The first layout fragment visibly changes ink; the independent caret
        // fragment remains pixel-identical and keeps its authored storage color.
        #expect(differentPixels(authored, focused, in: dimmedRect) > 20)
        #expect(differentPixels(authored, focused, in: focusedRect) == 0)
        #expect(renderingAttributes(textView, at: 1)[.markdownFocusForeground] as? NSColor == .magenta)
        #expect(renderingAttributes(textView, at: focusLocation)[.markdownFocusForeground] == nil)
        #expect(textView.textStorage?.attribute(.foregroundColor, at: focusLocation, effectiveRange: nil) as? NSColor == .systemGreen)
    }

    @Test("runtime transitions, caret movement, and edits update effective glyph ink")
    func runtimeChangesUpdateEffectiveGlyphInk() {
        let original = "First sentence.\nSecond sentence.\nFinal paragraph."
        let nsOriginal = original as NSString
        let first = nsOriginal.range(of: "First sentence.")
        let second = nsOriginal.range(of: "Second sentence.")
        let final = nsOriginal.range(of: "Final paragraph.")
        let (coordinator, textView) = makeEditor(mode: .disabled)
        coordinator.configuration.rawSourceMode = true
        coordinator.configuration.theme.bodyText = .systemGreen
        coordinator.configuration.theme.mutedText = .magenta
        coordinator.rebuildTextStorageAndStyle(textView, from: original, invalidateLayout: true)
        textView.setSelectedRange(NSRange(location: second.location + 2, length: 0))

        coordinator.synchronizeFocusMode(.typewriter, to: textView)
        let authored = renderedBitmap(textView)

        coordinator.synchronizeFocusMode(.sentence, to: textView)
        let sentence = renderedBitmap(textView)
        #expect(differentPixels(authored, sentence, in: segmentRect(textView, range: first)) > 20)
        #expect(differentPixels(authored, sentence, in: segmentRect(textView, range: second)) == 0)
        #expect(differentPixels(authored, sentence, in: segmentRect(textView, range: final)) > 20)

        coordinator.synchronizeFocusMode(.paragraph, to: textView)
        let paragraph = renderedBitmap(textView)
        #expect(differentPixels(authored, paragraph, in: segmentRect(textView, range: first)) > 20)
        #expect(differentPixels(authored, paragraph, in: segmentRect(textView, range: second)) == 0)
        #expect(differentPixels(authored, paragraph, in: segmentRect(textView, range: final)) > 20)

        textView.setSelectedRange(NSRange(location: final.location + 2, length: 0))
        coordinator.textViewDidChangeSelection(Notification(
            name: NSTextView.didChangeSelectionNotification,
            object: textView
        ))
        let movedCaret = renderedBitmap(textView)
        #expect(differentPixels(authored, movedCaret, in: segmentRect(textView, range: first)) > 20)
        #expect(differentPixels(authored, movedCaret, in: segmentRect(textView, range: final)) == 0)

        // Splitting the focused paragraph must refresh the effective drawing on
        // textDidChange: "Final" becomes muted while the caret paragraph keeps
        // authored ink. A separate disabled editor supplies a rendering baseline
        // for the new document, so this verifies pixels rather than overlay data.
        textView.textStorage?.replaceCharacters(
            in: NSRange(location: final.location + 5, length: 1),
            with: "\n"
        )
        let paragraphWord = NSRange(location: final.location + 6, length: 10)
        textView.setSelectedRange(NSRange(location: paragraphWord.location, length: 0))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))

        let editedText = textView.string
        let (baselineCoordinator, baselineView) = makeEditor(mode: .disabled)
        baselineCoordinator.configuration.theme.bodyText = .systemGreen
        baselineCoordinator.configuration.theme.mutedText = .magenta
        baselineCoordinator.rebuildTextStorageAndStyle(
            baselineView,
            from: editedText,
            invalidateLayout: true
        )
        let editedAuthored = renderedBitmap(baselineView)
        let editedFocused = renderedBitmap(textView)
        let finalWord = NSRange(location: final.location, length: 5)
        #expect(differentPixels(
            editedAuthored,
            editedFocused,
            in: segmentRect(textView, range: finalWord)
        ) > 10)
        #expect(differentPixels(
            editedAuthored,
            editedFocused,
            in: segmentRect(textView, range: paragraphWord)
        ) == 0)

        coordinator.synchronizeFocusMode(.disabled, to: textView)
        let disabled = renderedBitmap(textView)
        #expect(differentPixels(
            editedAuthored,
            disabled,
            in: segmentRect(textView, range: NSRange(location: 0, length: (editedText as NSString).length))
        ) == 0)
    }

    @Test("custom list markers use focused and unfocused effective ink")
    func listMarkersUseFocusForeground() {
        // Repeated authored `1.` markers force the second and third ordered
        // items through the custom display-number painter as `2.` and `3.`.
        let listText = "- Dim bullet.\n- Focus bullet.\n\n1. Prelude ordered.\n1. Dim ordered.\n1. Focus ordered."
        let nsText = listText as NSString
        let dimBullet = nsText.range(of: "-")
        let focusBulletLine = nsText.range(of: "- Focus bullet.")
        let focusBullet = NSRange(location: focusBulletLine.location, length: 1)
        let dimOrderedLine = nsText.range(of: "1. Dim ordered.")
        let focusOrderedLine = nsText.range(of: "1. Focus ordered.")
        let dimOrdered = NSRange(location: dimOrderedLine.location, length: 2)
        let focusOrdered = NSRange(location: focusOrderedLine.location, length: 2)
        let (coordinator, textView) = makeEditor(mode: .disabled)
        coordinator.configuration.theme.bodyText = .systemGreen
        coordinator.configuration.theme.mutedText = .magenta
        coordinator.rebuildTextStorageAndStyle(textView, from: listText, invalidateLayout: true)

        guard let storage = textView.textStorage else {
            Issue.record("Missing text storage")
            return
        }
        #expect(storage.attribute(.bulletMarker, at: dimBullet.location, effectiveRange: nil) as? Bool == true)
        #expect(storage.attribute(.bulletMarker, at: focusBullet.location, effectiveRange: nil) as? Bool == true)
        #expect(storage.attribute(.orderedMarker, at: dimOrdered.location, effectiveRange: nil) != nil)
        #expect(storage.attribute(.orderedMarker, at: focusOrdered.location, effectiveRange: nil) != nil)

        let authoredBulletColor = storage.attribute(
            .foregroundColor,
            at: dimBullet.location,
            effectiveRange: nil
        ) as? NSColor
        let authoredOrderedColor = storage.attribute(
            .foregroundColor,
            at: dimOrdered.location,
            effectiveRange: nil
        ) as? NSColor
        let authored = renderedBitmap(textView)
        func markerRect(_ range: NSRange) -> CGRect {
            segmentRect(textView, range: range).insetBy(dx: -2, dy: -2)
        }

        // With the second bullet focused, its custom marker keeps authored ink;
        // both custom marker kinds outside that paragraph use muted focus ink.
        textView.setSelectedRange(NSRange(location: focusBulletLine.location + 3, length: 0))
        coordinator.synchronizeFocusMode(.paragraph, to: textView)
        let bulletFocused = renderedBitmap(textView)
        #expect(differentPixels(authored, bulletFocused, in: markerRect(dimBullet)) > 2)
        #expect(differentPixels(authored, bulletFocused, in: markerRect(focusBullet)) == 0)
        #expect(differentPixels(authored, bulletFocused, in: markerRect(dimOrdered)) > 2)

        // Moving focus to the final ordered item restores that marker while the
        // other ordered marker remains visibly dimmed.
        textView.setSelectedRange(NSRange(location: focusOrdered.location + 3, length: 0))
        coordinator.applyFocusRendering(to: textView)
        let orderedFocused = renderedBitmap(textView)
        #expect(differentPixels(authored, orderedFocused, in: markerRect(dimOrdered)) > 2)
        #expect(differentPixels(authored, orderedFocused, in: markerRect(focusOrdered)) == 0)

        // Rendering overlays must not replace the authored clear marker ink.
        #expect(storage.attribute(.foregroundColor, at: dimBullet.location, effectiveRange: nil) as? NSColor == authoredBulletColor)
        #expect(storage.attribute(.foregroundColor, at: dimOrdered.location, effectiveRange: nil) as? NSColor == authoredOrderedColor)
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
        #expect(renderingAttributes(textView, at: Self.markedLocation)[.markdownFocusForeground] as? NSColor
                == textView.configuration.theme.mutedText)
        #expect(renderingAttributes(textView, at: Self.tailLocation)[.markdownFocusForeground] == nil)
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
        #expect(renderingAttributes(textView, at: Self.markedLocation)[.markdownFocusForeground] as? NSColor == .systemPurple)
        #expect(renderingAttributes(textView, at: Self.tailLocation)[.markdownFocusForeground] == nil)

        coordinator.restyleTextView(textView, paragraphCandidates: [fullRange])

        #expect(textView.textStorage?.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor == .systemGreen)
        #expect(textView.textStorage?.attribute(.foregroundColor, at: Self.markedLocation, effectiveRange: nil) as? NSColor == .black)
        #expect(textView.textStorage?.attribute(.backgroundColor, at: Self.markedLocation, effectiveRange: nil) as? NSColor == .white)
        #expect(renderingAttributes(textView, at: Self.markedLocation)[.markdownFocusForeground] as? NSColor == .systemPurple)
        #expect(renderingAttributes(textView, at: Self.tailLocation)[.markdownFocusForeground] == nil)
    }

    @Test("disabled and enabled transitions restore and reapply focus exactly")
    func focusTransitionsRestoreAuthoredAppearance() {
        let (coordinator, textView) = makeEditor(mode: .sentence)

        #expect(renderingAttributes(textView, at: Self.markedLocation)[.markdownFocusForeground] as? NSColor
                == coordinator.configuration.theme.mutedText)
        coordinator.configuration.focusMode = .disabled
        coordinator.applyFocusRendering(to: textView)
        #expect(renderingAttributes(textView, at: Self.markedLocation)[.markdownFocusForeground] == nil)
        #expect(textView.textStorage?.attribute(.foregroundColor, at: Self.markedLocation, effectiveRange: nil) as? NSColor == .black)
        #expect(textView.textStorage?.attribute(.backgroundColor, at: Self.markedLocation, effectiveRange: nil) as? NSColor == .white)

        coordinator.configuration.focusMode = .sentence
        coordinator.applyFocusRendering(to: textView)
        #expect(renderingAttributes(textView, at: Self.markedLocation)[.markdownFocusForeground] as? NSColor
                == coordinator.configuration.theme.mutedText)
        #expect(renderingAttributes(textView, at: Self.tailLocation)[.markdownFocusForeground] == nil)
        #expect(textView.textStorage?.attribute(.foregroundColor, at: Self.tailLocation, effectiveRange: nil) as? NSColor
                == coordinator.configuration.theme.bodyText)
    }

    @Test("focus ink coexists visually with extension and find backgrounds")
    func disablingRestoresExtensionAndFindAppearance() {
        let (coordinator, textView) = makeEditor(mode: .sentence)
        let visualText = "plain ==marked==.\nTail sentence."
        textView.setSelectedRange(NSRange(location: Self.tailLocation, length: 0))
        coordinator.rebuildTextStorageAndStyle(textView, from: visualText, invalidateLayout: true)
        guard let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager,
              let start = contentManager.location(contentManager.documentRange.location, offsetBy: 0),
              let end = contentManager.location(start, offsetBy: 5),
              let findRange = NSTextRange(location: start, end: end) else {
            Issue.record("TextKit range setup failed")
            return
        }

        // Find owns a yellow rendering background over `plain`; the Markdown
        // extension independently owns the white storage background over
        // `marked`. Both sit in the muted sentence before the caret sentence.
        layoutManager.addRenderingAttribute(.backgroundColor, value: NSColor.systemYellow, for: findRange)
        coordinator.applyFocusRendering(to: textView)
        let focused = renderedBitmap(textView)

        coordinator.configuration.focusMode = .disabled
        coordinator.applyFocusRendering(to: textView)
        let authored = renderedBitmap(textView)

        let plainRect = segmentRect(textView, range: NSRange(location: 0, length: 5))
        let markedRect = segmentRect(textView, range: NSRange(location: Self.markedLocation, length: 6))
        let tailRect = segmentRect(textView, range: NSRange(location: Self.tailLocation, length: 13))
        #expect(differentPixels(authored, focused, in: plainRect) > 5)
        #expect(differentPixels(authored, focused, in: markedRect) > 5)
        #expect(differentPixels(authored, focused, in: tailRect) == 0)

        let authoredFindPixels = matchingColorPixels(in: authored, viewRect: plainRect, color: .systemYellow)
        let focusedFindPixels = matchingColorPixels(in: focused, viewRect: plainRect, color: .systemYellow)
        let authoredExtensionPixels = matchingColorPixels(in: authored, viewRect: markedRect, color: .white)
        let focusedExtensionPixels = matchingColorPixels(in: focused, viewRect: markedRect, color: .white)
        #expect(authoredFindPixels > 20)
        #expect(focusedFindPixels >= authoredFindPixels * 8 / 10)
        #expect(authoredExtensionPixels > 20)
        #expect(focusedExtensionPixels >= authoredExtensionPixels * 8 / 10)

        let rendered = renderingAttributes(textView, at: 1)
        #expect(rendered[.markdownFocusForeground] == nil)
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
