//
//  FocusRangeTests.swift
//  MarkdownEngineTests
//
//  Deterministic UTF-16 focus-range behavior at editing boundaries.
//

import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Focus range resolution")
struct FocusRangeTests {
    @Test func configurationDefaultsToDisabled() {
        #expect(MarkdownEditorConfiguration.default.focusMode == .disabled)
        #expect(MarkdownEditorConfiguration(focusMode: .typewriter).focusMode == .typewriter)
    }

    @Test func sentenceIncludesTerminatingPunctuationAndFollowingWhitespace() {
        let text = "First sentence!  Second sentence?"

        #expect(resolve(text, caret: 5, mode: .sentence) == range(of: "First sentence!  ", in: text))
        #expect(resolve(text, caret: 14, mode: .sentence) == range(of: "First sentence!  ", in: text))
        #expect(resolve(text, caret: 15, mode: .sentence) == range(of: "First sentence!  ", in: text))
    }

    @Test func caretAtSentenceStartUsesFollowingSentence() {
        let text = "First sentence!  Second sentence?"
        let second = range(of: "Second sentence?", in: text)

        #expect(resolve(text, caret: second.location, mode: .sentence) == second)
    }

    @Test func sentenceAtEndOfDocumentUsesFinalSentence() {
        let text = "One. Final sentence!"
        let expected = range(of: "Final sentence!", in: text)
        let end = (text as NSString).length

        #expect(resolve(text, caret: end, mode: .sentence) == expected)
        #expect(resolve(text, caret: end + 100, mode: .sentence) == expected)
    }

    @Test func sentenceRangesUseUTF16Coordinates() {
        let text = "😀 starts here. Café ends."
        let nsText = text as NSString
        let expected = nsText.range(of: "Café ends.")

        #expect(resolve(text, caret: expected.location, mode: .sentence) == expected)
        #expect(NSMaxRange(expected) == nsText.length)
    }

    @Test func paragraphIncludesItsLineSeparator() {
        let text = "Alpha\nBeta\n\nGamma"

        #expect(resolve(text, caret: 0, mode: .paragraph) == NSRange(location: 0, length: 6))
        #expect(resolve(text, caret: 5, mode: .paragraph) == NSRange(location: 0, length: 6))
        #expect(resolve(text, caret: 6, mode: .paragraph) == NSRange(location: 6, length: 5))
    }

    @Test func emptyLineIsAParagraphAndEndUsesFinalParagraph() {
        let text = "Alpha\nBeta\n\nGamma"
        let end = (text as NSString).length

        #expect(resolve(text, caret: 11, mode: .paragraph) == NSRange(location: 11, length: 1))
        #expect(resolve(text, caret: end, mode: .paragraph) == NSRange(location: 12, length: 5))
    }

    @Test func nonemptySelectionIsFocusedExactly() {
        let text = "First sentence. Second paragraph."
        let selection = NSRange(location: 3, length: 20)

        #expect(FocusRangeResolver.resolve(in: text, selection: selection, mode: .sentence) == selection)
        #expect(FocusRangeResolver.resolve(in: text, selection: selection, mode: .paragraph) == selection)
    }

    @Test func selectionsAreClampedToTheDocument() {
        let text = "Short"

        #expect(
            FocusRangeResolver.resolve(
                in: text,
                selection: NSRange(location: 3, length: 100),
                mode: .sentence
            ) == NSRange(location: 3, length: 2)
        )
        #expect(
            FocusRangeResolver.resolve(
                in: text,
                selection: NSRange(location: 100, length: 4),
                mode: .paragraph
            ) == NSRange(location: 5, length: 0)
        )
    }

    @Test func emptyDocumentHasAnEmptyTextFocusRange() {
        let empty = NSRange(location: 0, length: 0)

        #expect(resolve("", caret: 0, mode: .sentence) == empty)
        #expect(resolve("", caret: 0, mode: .paragraph) == empty)
    }

    @Test func disabledAndTypewriterHaveNoTextFocusRange() {
        for mode in [FocusMode.disabled, .typewriter] {
            #expect(resolve("Some text.", caret: 2, mode: mode) == nil)
            #expect(
                FocusRangeResolver.resolve(
                    in: "Some text.",
                    selection: NSRange(location: 1, length: 3),
                    mode: mode
                ) == nil
            )
        }
    }

    @Test func notFoundSelectionDoesNotResolve() {
        #expect(
            FocusRangeResolver.resolve(
                in: "Some text.",
                selection: NSRange(location: NSNotFound, length: 0),
                mode: .sentence
            ) == nil
        )
    }

    private func resolve(_ text: String, caret: Int, mode: FocusMode) -> NSRange? {
        FocusRangeResolver.resolve(
            in: text,
            selection: NSRange(location: caret, length: 0),
            mode: mode
        )
    }

    private func range(of substring: String, in text: String) -> NSRange {
        (text as NSString).range(of: substring)
    }
}
