//
//  NativeTextViewCoordinator+Focus.swift
//  MarkdownEngine
//
//  Pure UTF-16 range resolution shared by focus-mode styling paths.
//

import AppKit
import Foundation

extension NativeTextViewCoordinator {
    /// Synchronizes the runtime focus mode across the coordinator and text view.
    ///
    /// This is the single transition path used by SwiftUI updates and tests. A
    /// mismatch in either runtime owner counts as a transition, so geometry and
    /// rendering are repaired even if one owner was updated independently.
    func synchronizeFocusMode(_ focusMode: FocusMode, to textView: NativeTextView) {
        let changed = configuration.focusMode != focusMode
            || textView.configuration.focusMode != focusMode
        configuration.focusMode = focusMode
        textView.configuration.focusMode = focusMode
        if changed {
            applyFocusRendering(to: textView)
        }
    }

    /// Replaces the focus-mode rendering overlay without touching text storage.
    ///
    /// Markdown styling, extension ink, and find backgrounds remain authored
    /// attributes. Focus mode uses TextKit rendering attributes only, so removing
    /// the overlay reveals those attributes exactly as they were before.
    func applyFocusRendering(to textView: NSTextView) {
        let focusMode = configuration.focusMode
        let nativeTextView = textView as? NativeTextView
        if nativeTextView?.configuration.focusMode != focusMode {
            nativeTextView?.configuration.focusMode = focusMode
        }

        // Selection and edit callbacks already refresh focus rendering. Queueing
        // centering from that shared path makes typewriter mode run after AppKit's
        // own caret reveal and the edit's synchronous layout work. Other modes
        // immediately return to the ordinary overscroll policy, removing the
        // typewriter-only bottom slack when the mode is switched off.
        if focusMode == .typewriter {
            scheduleTypewriterCentering(for: textView)
        } else {
            let scrollView = textView.enclosingScrollView
            let clampedScrollView = scrollView as? ClampedScrollView
            // Invalidate queued caret work before changing any geometry. A block
            // from the previous typewriter mode may already be on the main queue.
            clampedScrollView?.cancelPendingTypewriterCentering()

            if let nativeTextView, let scrollView {
                nativeTextView.reapplyOverscrollPolicy(for: scrollView)
                // Removing top slack changes the text view's origin even when its
                // viewport-filling size is unchanged, so restack explicitly rather
                // than relying only on a frame-size notification.
                (nativeTextView.superview as? NativeTextViewContainer)?.restack(
                    propagateWidth: false
                )
                clampedScrollView?.clampToInsets()
            }
        }

        guard let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager else {
            return
        }

        let documentRange = contentManager.documentRange
        // Focus owns a dedicated rendering key. Using `.foregroundColor` here
        // is ineffective for runs that already have an authored foreground
        // (extensions and syntax styling win when TextKit builds its line).
        // The custom layout fragment resolves this key at draw time instead.
        // Find continues to own `.backgroundColor` independently.
        layoutManager.removeRenderingAttribute(.markdownFocusForeground, for: documentRange)
        // Rendering attributes are maintained outside text storage. Rebuild the
        // affected fragments after the overlay has been fully replaced so both
        // adding focus and removing it immediately change effective glyph ink.
        defer { layoutManager.invalidateLayout(for: documentRange) }

        let text = textView.string as NSString
        guard text.length > 0,
              let focusRange = FocusRangeResolver.resolve(
                in: text,
                selection: textView.selectedRange(),
                mode: focusMode
              ) else {
            return
        }

        let clampedFocus = NSIntersectionRange(
            focusRange,
            NSRange(location: 0, length: text.length)
        )
        let dimmedRanges = [
            NSRange(location: 0, length: clampedFocus.location),
            NSRange(
                location: NSMaxRange(clampedFocus),
                length: text.length - NSMaxRange(clampedFocus)
            )
        ]

        for range in dimmedRanges where range.length > 0 {
            guard let start = contentManager.location(
                documentRange.location,
                offsetBy: range.location
            ), let end = contentManager.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else {
                continue
            }
            layoutManager.addRenderingAttribute(
                .markdownFocusForeground,
                value: configuration.theme.mutedText,
                for: textRange
            )
        }
    }

    /// Centers the selected caret/current line in the unobscured viewport.
    ///
    /// The geometry is resolved only when the queued operation runs, avoiding
    /// stale line frames during edits and following AppKit's post-edit caret
    /// reveal. The existing overscroll policy supplies bottom
    /// slack, and `clampToInsets` enforces the container's real scroll range.
    func centerTypewriterCaret(in textView: NSTextView) {
        guard configuration.focusMode == .typewriter,
              let textView = textView as? NativeTextView,
              textView.configuration.heightBehavior == .scrolls,
              let scrollView = textView.enclosingScrollView else {
            return
        }

        let selection = textView.selectedRange()
        guard selection.location != NSNotFound else { return }

        textView.recalcOverscroll(for: scrollView, debugTag: "typewriter")
        guard let localLineRect = textView.typewriterLineRect(
            atUTF16Offset: selection.location
        ) else { return }

        // TextKit's segment is text-view-local. Moving it into document-view
        // coordinates incorporates both the scrolling header and the text view's
        // position inside a centered reading-width container.
        let documentLineRect = localLineRect.offsetBy(
            dx: textView.frame.origin.x,
            dy: textView.frame.origin.y
        )
        let clipView = scrollView.contentView
        let targetY = TypewriterCenteringGeometry.targetScrollOriginY(
            lineRect: documentLineRect,
            viewportBounds: clipView.bounds,
            contentInsets: scrollView.contentInsets
        )
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: targetY))
        scrollView.reflectScrolledClipView(clipView)
        (scrollView as? ClampedScrollView)?.clampToInsets()
    }

    @discardableResult
    func scheduleTypewriterCentering(for textView: NSTextView) -> UInt? {
        guard configuration.focusMode == .typewriter,
              let scrollView = textView.enclosingScrollView as? ClampedScrollView else {
            return nil
        }
        // Issuing a new request also supersedes any older caret position that is
        // still waiting for AppKit's synchronous layout/reveal work to finish.
        let generation = scrollView.beginTypewriterCenteringRequest()
        DispatchQueue.main.async { [weak self, weak textView, weak scrollView] in
            guard let self, let textView, let scrollView,
                  scrollView.isCurrentTypewriterCenteringRequest(generation) else {
                return
            }
            self.centerTypewriterCaret(in: textView)
        }
        return generation
    }
}

/// Resolves the UTF-16 range that remains emphasized by focus mode.
///
/// The resolver is deliberately independent of `NSTextView` and TextKit, so
/// callers can use a selection from either AppKit or another UTF-16-based API.
/// Its behavior at editing boundaries is:
///
/// - An empty document resolves to `{0, 0}` for sentence and paragraph modes.
/// - A non-empty selection is itself the focus range; it is not expanded to a
///   sentence or paragraph. Out-of-document portions are clamped away.
/// - Sentence-ending punctuation belongs to the sentence before it.
/// - Whitespace separators emitted by Foundation's sentence segmentation
///   belong to the preceding sentence. A caret exactly at the next sentence's
///   first UTF-16 unit focuses that next sentence.
/// - Paragraph separators belong to the paragraph before them. An empty line
///   is its own paragraph, matching `NSString.paragraphRange(for:)`.
/// - A caret at the end of a non-empty document focuses the final sentence or
///   paragraph rather than producing an empty range.
/// - Disabled and typewriter modes do not define a text focus range.
public enum FocusRangeResolver {
    /// Returns a range in the same UTF-16 coordinate space as `selection`.
    ///
    /// `nil` means that `mode` has no text-range focus, or that the supplied
    /// selection has `NSNotFound` as its location.
    public static func resolve(
        in text: String,
        selection: NSRange,
        mode: FocusMode
    ) -> NSRange? {
        resolve(in: text as NSString, selection: selection, mode: mode)
    }

    /// `NSString` overload for callers that already keep text in UTF-16 form.
    public static func resolve(
        in utf16Text: NSString,
        selection: NSRange,
        mode: FocusMode
    ) -> NSRange? {
        let hasSelection = selection.length > 0
        guard let selection = clamped(selection, to: utf16Text.length) else {
            return nil
        }

        switch mode {
        case .disabled, .typewriter:
            return nil
        case .sentence where hasSelection,
             .paragraph where hasSelection:
            return selection
        case .sentence:
            return sentenceRange(in: utf16Text, caretLocation: selection.location)
        case .paragraph:
            return utf16Text.paragraphRange(for: selection)
        }
    }

    private static func clamped(_ range: NSRange, to documentLength: Int) -> NSRange? {
        guard range.location != NSNotFound else { return nil }
        let location = min(max(0, range.location), documentLength)
        let requestedLength = max(0, range.length)
        let length = min(requestedLength, documentLength - location)
        return NSRange(location: location, length: length)
    }

    private static func sentenceRange(in text: NSString, caretLocation: Int) -> NSRange {
        guard text.length > 0 else { return NSRange(location: 0, length: 0) }

        // End-of-document is not contained by any half-open sentence range.
        // Looking up the preceding UTF-16 unit gives it final-sentence affinity.
        let lookupLocation = min(caretLocation, text.length - 1)
        var resolvedRange: NSRange?
        let wholeDocument = NSRange(location: 0, length: text.length)
        text.enumerateSubstrings(
            in: wholeDocument,
            options: [.bySentences, .substringNotRequired]
        ) { _, sentenceRange, _, stop in
            guard NSLocationInRange(lookupLocation, sentenceRange) else { return }
            resolvedRange = sentenceRange
            stop.pointee = true
        }

        // Sentence enumeration can yield no ranges for unusual separator-only
        // input. Keeping that document focused is safer than dimming all of it.
        return resolvedRange ?? wholeDocument
    }
}
