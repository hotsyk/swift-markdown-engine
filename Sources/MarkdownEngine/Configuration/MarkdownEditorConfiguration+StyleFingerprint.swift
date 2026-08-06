//
//  MarkdownEditorConfiguration+StyleFingerprint.swift
//  MarkdownEngine
//
//  Runtime change detection for style-only configuration.
//

import AppKit
import Foundation

extension MarkdownEditorConfiguration {
    /// Fingerprint over the style-only knobs (theme palette, typography
    /// metrics, syntax highlighter) that require an in-place restyle when the
    /// embedder hands the view a new configuration at runtime.
    ///
    /// Without this, a theme or typography change is inert until the embedder
    /// recreates the whole view — which drops undo history and scroll
    /// position. Cheap enough to evaluate on every SwiftUI update pass.
    var styleFingerprint: Int {
        var hasher = Hasher()
        // Theme palette: reflect over the struct so newly added colors are
        // covered automatically.
        for child in Mirror(reflecting: theme).children {
            if let color = child.value as? NSColor {
                hasher.combine(color)
            }
        }
        hasher.combine(markers.hiddenMarkerFontSize)
        hasher.combine(markers.inlineCodeMarkerAlpha)
        hasher.combine(markers.findMatchHighlightAlpha)
        hasher.combine(codeBlock.fontSizeScale)
        hasher.combine(codeBlock.paragraphSpacing)
        hasher.combine(codeBlock.horizontalIndent)
        hasher.combine(inlineCode.fontSizeScale)
        hasher.combine(taskCheckbox.uncheckedSymbolName)
        hasher.combine(taskCheckbox.checkedSymbolName)
        hasher.combine(headings.fontMultipliers)
        hasher.combine(headings.topSpacingEm)
        hasher.combine(imageEmbed.minimumWidth)
        hasher.combine(imageEmbed.fallbackMaxWidth)
        hasher.combine(imageEmbed.unreasonableMaxWidth)
        hasher.combine(imageEmbed.paragraphSpacing)
        hasher.combine(imageEmbed.imageGap)
        hasher.combine(blockLatex.paragraphSpacingBefore)
        hasher.combine(blockLatex.paragraphSpacing)
        hasher.combine(blockLatex.singleLetterPaddingBottom)
        hasher.combine(blockquote.extraLineHeight)
        hasher.combine(link.activeLinkAlpha)
        hasher.combine(link.incompleteLinkAlpha)
        hasher.combine(paragraph.spacingFactor)
        hasher.combine(paragraph.lineHeightExtraSpacing)
        hasher.combine(lists.indentPerLevel)
        hasher.combine(lists.extraLineHeight)
        hasher.combine(readingWidth)
        hasher.combine(String(reflecting: type(of: services.syntaxHighlighter)))
        hasher.combine(services.syntaxHighlighter.styleFingerprint)
        return hasher.finalize()
    }

    /// Copy the style-only fields from `other`, leaving the behavior,
    /// service, and lifecycle fields (already synced separately by
    /// `updateNSView`) untouched.
    mutating func adoptStyle(from other: MarkdownEditorConfiguration) {
        theme = other.theme
        markers = other.markers
        codeBlock = other.codeBlock
        inlineCode = other.inlineCode
        taskCheckbox = other.taskCheckbox
        headings = other.headings
        imageEmbed = other.imageEmbed
        blockLatex = other.blockLatex
        inlineLatex = other.inlineLatex
        blockquote = other.blockquote
        link = other.link
        paragraph = other.paragraph
        readingWidth = other.readingWidth
        services.syntaxHighlighter = other.services.syntaxHighlighter
    }
}
