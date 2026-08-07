//
//  MarkdownHTMLRendererTests.swift
//  MarkdownEngineTests
//
//  Test-first specification for the clean Markdown→HTML renderer used by the
//  editor's rich-copy path. Asserts the exact HTML fragment produced for each
//  representative construct.
//

import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Markdown → HTML renderer")
struct MarkdownHTMLRendererTests {

    private func html(_ md: String) -> String { MarkdownHTMLRenderer.html(from: md) }

    @Test("core element mapping — headings, emphasis, code, link, blockquote, escaping")
    func coreElementMapping() {
        #expect(html("# Title") == "<h1>Title</h1>")
        #expect(html("*i*") == "<p><em>i</em></p>")
        #expect(html("**b**") == "<p><strong>b</strong></p>")
        #expect(html("`code`") == "<p><code>code</code></p>")
        #expect(html("[text](http://x.com)") == "<p><a href=\"http://x.com\">text</a></p>")
        #expect(html("> hello") == "<blockquote>hello</blockquote>")
        #expect(html("a < b & c > d") == "<p>a &lt; b &amp; c &gt; d</p>")
    }

    @Test("fenced code block — language class, no language, html escaping")
    func fencedCode() {
        #expect(html("```swift\nlet x = 1\n```") == "<pre><code class=\"language-swift\">let x = 1</code></pre>")
        #expect(html("```\nplain\n```") == "<pre><code>plain</code></pre>")
        #expect(html("```\n<a> & <b>\n```") == "<pre><code>&lt;a&gt; &amp; &lt;b&gt;</code></pre>")
    }

    @Test("unordered and ordered lists")
    func unorderedList() {
        #expect(html("- a\n- b") == "<ul>\n<li>a</li>\n<li>b</li>\n</ul>")
        #expect(html("1. a\n2. b") == "<ol>\n<li>a</li>\n<li>b</li>\n</ol>")
    }

    @Test("task list keeps GFM checkbox markup (rich flavors strip it)")
    func taskList() {
        #expect(html("- [ ] todo\n- [x] done") == "<ul>\n<li><input type=\"checkbox\" disabled> todo</li>\n<li><input type=\"checkbox\" checked disabled> done</li>\n</ul>")
    }

    @Test("thematic break becomes hr")
    func thematicBreak() {
        #expect(html("---").contains("<hr"))
    }

    @Test("GFM table renders semantic inline content in cells")
    func tableInlineContent() {
        let md = """
        | Feature | Example | Status |
        |:--------|:-------:|-------:|
        | Bold | **strong** | Ready |
        | Link | [open](https://example.com) | Ready |
        | Code | `let value = 1` | Ready |
        | Emoji | 🌈 | Ready |
        """
        #expect(html(md) == "<table><thead><tr><th>Feature</th><th>Example</th><th>Status</th></tr></thead><tbody><tr><td>Bold</td><td><strong>strong</strong></td><td>Ready</td></tr><tr><td>Link</td><td><a href=\"https://example.com\">open</a></td><td>Ready</td></tr><tr><td>Code</td><td><code>let value = 1</code></td><td>Ready</td></tr><tr><td>Emoji</td><td>🌈</td><td>Ready</td></tr></tbody></table>")
    }

    @Test("GFM table without outer pipes")
    func tableWithoutOuterPipes() {
        let md = """
        Name | Value | Notes
        :---- | :----: | ----:
        Alpha | 1 | Left aligned
        Beta | 2 | Center aligned
        Gamma | 3 | Right aligned
        """
        #expect(html(md) == "<table><thead><tr><th>Name</th><th>Value</th><th>Notes</th></tr></thead><tbody><tr><td>Alpha</td><td>1</td><td>Left aligned</td></tr><tr><td>Beta</td><td>2</td><td>Center aligned</td></tr><tr><td>Gamma</td><td>3</td><td>Right aligned</td></tr></tbody></table>")
    }

    @Test("GFM table renders empty body cells")
    func tableWithEmptyBodyCells() {
        let md = """
        | Name | Value | Notes |
        | --- | --- | --- |
        | Alpha | | Ready |
        | Beta | 2 | |
        """
        #expect(html(md) == "<table><thead><tr><th>Name</th><th>Value</th><th>Notes</th></tr></thead><tbody><tr><td>Alpha</td><td></td><td>Ready</td></tr><tr><td>Beta</td><td>2</td><td></td></tr></tbody></table>")
    }
}
