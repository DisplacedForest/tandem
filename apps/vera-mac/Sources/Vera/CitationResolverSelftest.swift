import Foundation

enum CitationResolverSelftest {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    static let cold = PulseSource(n: 1, title: "Cold frames guide", url: "https://example.org/cold")
    static let glazing = PulseSource(n: 2, title: "Glazing basics", url: "https://example.com/glazing")
    static let three = PulseSource(n: 3, title: "Heater sizing", url: "https://example.net/three")
    static let four = PulseSource(n: 4, title: "Barrel mass", url: "https://example.net/four")
    static let five = PulseSource(n: 5, title: "Vent openers", url: "https://example.net/five")
    static let all = [cold, glazing, three, four, five]

    static func single(_ text: String, _ sources: [PulseSource] = all) throws -> CitationBlock {
        let found = CitationResolver.blocks(text: text, sources: sources)
        guard found.count == 1, let block = found.first else {
            throw Failure(description: "Expected one block for \(text.debugDescription), got \(found)")
        }
        return block
    }

    static func expect(_ text: String, becomes drawn: String, refs: [Int], _ sources: [PulseSource] = all) throws {
        let block = try single(text, sources)
        try check(block.text == drawn, "\(text.debugDescription) draws as \(drawn.debugDescription), got \(block.text.debugDescription)")
        try check(block.refs == refs, "\(text.debugDescription) cites \(refs), got \(block.refs)")
        try check(!block.isCode, "\(text.debugDescription) is not code")
    }

    static func unchanged(_ text: String, _ sources: [PulseSource] = all) throws {
        try expect(text, becomes: text, refs: [], sources)
    }

    static func run() throws {
        try expect("Rain is likely [1].", becomes: "Rain is likely.", refs: [1])
        try expect("A [1] B", becomes: "A B", refs: [1])
        try expect("Snow [1][2] tonight.", becomes: "Snow tonight.", refs: [1, 2])
        try expect("Frost [1, 2] early.", becomes: "Frost early.", refs: [1, 2])
        try expect("Frost [1,2] early.", becomes: "Frost early.", refs: [1, 2])
        try expect("Wind [1-3] all week.", becomes: "Wind all week.", refs: [1, 2, 3])
        try expect("Wind [1, 3-5] all week.", becomes: "Wind all week.", refs: [1, 3, 4, 5])
        try expect("Wind [2\u{2013}4] all week.", becomes: "Wind all week.", refs: [2, 3, 4])
        try expect("B [2] then A [1] and [2, 1].", becomes: "B then A and.", refs: [1, 2])
        try expect("[1] Rain falls.", becomes: " Rain falls.", refs: [1])
        try expect("First line\n[1] second line", becomes: "First line\n second line", refs: [1])
        try expect("  Indented  double  spaces [1]\nnext\tline [2]\n\tlast", becomes: "  Indented  double  spaces\nnext\tline\n\tlast", refs: [1, 2])
        try expect("One [1]. Two [1]. Three [1].", becomes: "One. Two. Three.", refs: [1])

        let sameHost = [
            PulseSource(n: 1, title: "Part one", url: "https://example.org/a"),
            PulseSource(n: 2, title: "Part two", url: "https://example.org/b"),
        ]
        try expect("First [1], second [2].", becomes: "First, second.", refs: [1, 2], sameHost)
        let sameHostResolved = CitationResolver.resolve(text: "First [1], second [2].", sources: sameHost)
        try check(sameHostResolved.sources.map(\.url) == ["https://example.org/a", "https://example.org/b"]
                  && Set(sameHostResolved.sources.map(\.id)).count == 2, "Two sources on one host keep separate identities")

        try unchanged("Fact [7].")
        try unchanged("Fact [1, 7].")
        try unchanged("Fact [5-1] and [1-30].")
        try unchanged("Built in [2024], see arr[3] too.", [cold])
        try expect("Use `arr[1]` here [1].", becomes: "Use `arr[1]` here.", refs: [1])
        try unchanged("Use ``arr[1] `x` [1]`` here.")
        try unchanged("See [1](https://example.org/x) for more.")
        try unchanged("A picture ![1](https://example.org/i.png) here.")
        try unchanged("[1]: https://example.org/x")
        try unchanged("Read [the guide][1] first.")
        try unchanged("A note[^1] here.")
        try unchanged("Escaped \\[1\\] stays.")

        let fenced = "Intro [1].\n\n```swift\nlet x = a[1]\n\nlet y = b[2]\n```\n\nOutro [2]."
        let fencedBlocks = CitationResolver.blocks(text: fenced, sources: all)
        try check(fencedBlocks.count == 3, "Prose, code and prose make three blocks, got \(fencedBlocks)")
        try check(fencedBlocks.first == CitationBlock(text: "Intro.", refs: [1], isCode: false), "Prose before the fence is cited")
        try check(fencedBlocks.dropFirst().first == CitationBlock(text: "```swift\nlet x = a[1]\n\nlet y = b[2]\n```", refs: [], isCode: true),
                  "A fence with blank lines is one untouched code block")
        try check(fencedBlocks.last == CitationBlock(text: "Outro.", refs: [2], isCode: false), "Prose after the fence is cited")
        let tilde = CitationResolver.blocks(text: "~~~\nvalue [1]\n~~~", sources: all)
        try check(tilde == [CitationBlock(text: "~~~\nvalue [1]\n~~~", refs: [], isCode: true)], "A tilde fence is untouched code")
        let unclosed = CitationResolver.blocks(text: "Text [1]\n\n```\ncode [1]\n\nmore [2]", sources: all)
        try check(unclosed == [
            CitationBlock(text: "Text", refs: [1], isCode: false),
            CitationBlock(text: "```\ncode [1]\n\nmore [2]", refs: [], isCode: true),
        ], "An unclosed fence runs to the end untouched, got \(unclosed)")

        try expect("- one [1]\n\n- two [2]\n\n- three", becomes: "- one\n\n- two\n\n- three", refs: [1, 2])
        try expect("1. first [1]\n\n   more about it\n\n2. second [3]", becomes: "1. first\n\n   more about it\n\n2. second", refs: [1, 3])
        try expect("| Crop | Note |\n| --- | --- |\n| Kale [1] | Hardy [2] |", becomes: "| Crop | Note |\n| --- | --- |\n| Kale | Hardy |", refs: [1, 2])

        let layout = "# Title\n\nPara one.\n\n\n- a\n\n- b\n\n```\nx\n\ny\n```\n\nEnd [9]."
        let plain = CitationResolver.blocks(text: layout, sources: [])
        try check(plain.map(\.text).joined(separator: "\n\n") == "# Title\n\nPara one.\n\n- a\n\n- b\n\n```\nx\n\ny\n```\n\nEnd [9].",
                  "Blocks joined with a blank line keep every visible line")
        try check(plain.allSatisfy { $0.refs.isEmpty }, "No sources means no refs")
        try check(CitationResolver.blocks(text: "Fact [1].", sources: []) == [CitationBlock(text: "Fact [1].", refs: [], isCode: false)],
                  "No sources leaves markers as written")

        let headings = ["Sources", "Sources:", "# Sources", "## Sources", "### Sources:", "#### Sources", "**Sources**",
                        "**Sources:**", "**Sources**:", "  sources  ", "References", "## References:", "**References:**"]
        for heading in headings {
            let text = "Rain [1] and wind [2].\n\n\(heading)\n1. https://example.org/rain\n2. https://example.com/wind\n"
            guard let recovered = CitationResolver.recover(text) else { throw Failure(description: "Recovery accepts \(heading.debugDescription)") }
            try check(recovered.body == "Rain [1] and wind [2].", "The recovered body drops the list under \(heading.debugDescription)")
            try check(recovered.sources == [
                PulseSource(n: 1, title: "", url: "https://example.org/rain"),
                PulseSource(n: 2, title: "", url: "https://example.com/wind"),
            ], "Recovered sources under \(heading.debugDescription)")
        }
        try check(CitationResolver.recover("Rain [1].\n\n##### Sources\n1. https://example.org/rain") == nil, "Five hashes are not a heading")

        let shapes = """
            A [1]. B [2]. C [3]. D [4]. E [5]. F [6]. G [1][6].

            ## Sources

            1. Rain report (https://example.org/rain)
            [2] <https://example.com/wind>
            3) [Wind study](https://example.com/study)
            - 4. Storm notes - https://example.net/storm
            * [5] https://example.net/five
            6. https://example.net/six.
            """
        guard let shaped = CitationResolver.recover(shapes) else { throw Failure(description: "Every entry shape is recovered") }
        try check(shaped.sources == [
            PulseSource(n: 1, title: "Rain report", url: "https://example.org/rain"),
            PulseSource(n: 2, title: "", url: "https://example.com/wind"),
            PulseSource(n: 3, title: "Wind study", url: "https://example.com/study"),
            PulseSource(n: 4, title: "Storm notes", url: "https://example.net/storm"),
            PulseSource(n: 5, title: "", url: "https://example.net/five"),
            PulseSource(n: 6, title: "", url: "https://example.net/six"),
        ], "Entry titles and addresses, got \(shaped.sources)")
        try check(shaped.body == "A [1]. B [2]. C [3]. D [4]. E [5]. F [6]. G [1][6].", "The body no longer holds the list")
        let reordered = CitationResolver.recover("X [2] Y [1].\n\nSources:\n2. https://example.com/b\n1. https://example.org/a")
        try check(reordered?.sources.map(\.n) == [1, 2], "Recovered sources sort by number")

        let refusals: [(String, String)] = [
            ("A [1] B [3].\n\n## Sources\n1. https://example.org/a\n2. https://example.org/b", "a cited number missing from the list"),
            ("A [1].\n\n## Sources\n1. https://example.org/a\n1. https://example.org/b", "a duplicate number"),
            ("A [1].\n\n## Sources\n1. https://example.org/a https://example.org/b", "two addresses on one line"),
            ("A [1].\n\n## Sources\n1. Rain report", "an entry without an address"),
            ("Plain text.\n\n## Sources\n1. https://example.org/a", "a body without markers"),
            ("A [1] in [2024].\n\n## Sources\n1. https://example.org/a", "a stray year in brackets"),
            ("A [1] B [2].\n\n## Sources\n1. https://example.org/a", "a body marker not in the list"),
            ("A [1].\n\n## Sources\n1. https://example.org/a\n\nThat is all.", "a paragraph after the list"),
            ("A [1].\n\n## Sources\n1. https://example.org/a\n\n## Next steps\n- Build it", "another section after the list"),
            ("A [1].\n\n## Sources\n1. ftp://example.org/a", "a non web address"),
            ("A [1].\n\n## Sources\n1. file:///tmp/a.md", "a file address"),
            ("A [1].\n\n## Sources\n1. https://user:secret@example.org/a", "an address with credentials"),
            ("A [1].\n\n```\n## Sources\n1. https://example.org/a\n```", "a heading only inside a fence"),
            ("A [1].\n\n## Sources\n1. https://example.org/a\n\n## Sources\n2. https://example.org/b", "two lists"),
            ("## Sources\n1. https://example.org/a", "a heading on the first line with nothing above it"),
        ]
        for (text, reason) in refusals {
            try check(CitationResolver.recover(text) == nil, "Recovery refuses \(reason)")
        }

        let midDocument = "Intro [1].\n\n## Sources\n\n1. Cold frames guide\n\n## Next steps\n\nBuild it."
        try check(CitationResolver.withoutMatchingList(midDocument, sources: [cold]) == midDocument, "A mid document Sources section stays")
        try check(CitationResolver.recover(midDocument) == nil, "A mid document Sources section is not recovered")

        let urlList = "Text [1] [2].\n\n## Sources\n\n1. https://example.org/cold/\n2. Glazing (https://example.com/glazing)\n"
        try check(CitationResolver.withoutMatchingList(urlList, sources: [cold, glazing]) == "Text [1] [2].", "A matching address list is removed")
        let titleList = "Text [1].\n\n**Sources**\n1. Cold frames guide\n2. Glazing basics"
        try check(CitationResolver.withoutMatchingList(titleList, sources: [cold, glazing]) == "Text [1].", "A matching title list is removed")
        let containedTitle = "Text [1].\n\nReferences:\n- [1] Cold frames"
        try check(CitationResolver.withoutMatchingList(containedTitle, sources: [cold]) == "Text [1].", "A shortened title still matches")
        let disagreeing = "Text [1] [2].\n\n## Sources\n1. https://example.org/cold\n2. https://example.com/other"
        try check(CitationResolver.withoutMatchingList(disagreeing, sources: [cold, glazing]) == disagreeing, "A disagreeing entry keeps the list")
        let unknownEntry = "Text [1].\n\n## Sources\n1. Cold frames guide\n3. Something else"
        try check(CitationResolver.withoutMatchingList(unknownEntry, sources: [cold, glazing]) == unknownEntry, "An entry with no source keeps the list")

        let foreignList = "Rain [1].\n\n## Sources\n1. https://example.net/elsewhere"
        let structured = CitationResolver.resolve(text: foreignList, sources: [cold])
        try check(!structured.recovered && structured.sources == [cold], "Structured sources never run recovery")
        try check(structured.blocks.contains { $0.text.contains("example.net/elsewhere") }, "A list that disagrees stays visible")
        let recoverable = "Rain [1].\n\n## Sources\n1. https://example.org/rain"
        let held = CitationResolver.resolve(text: recoverable, sources: [], allowRecovery: false)
        try check(!held.recovered && held.sources.isEmpty && held.blocks.allSatisfy({ $0.refs.isEmpty })
                  && held.blocks.first?.text == "Rain [1].", "Without recovery the text is drawn as written")
        let recovered = CitationResolver.resolve(text: recoverable, sources: [])
        try check(recovered.recovered && recovered.sources.count == 1 && recovered.blocks == [CitationBlock(text: "Rain.", refs: [1], isCode: false)],
                  "With recovery the list becomes sources, got \(recovered)")

        try check(CitationResolver.exportText("Rain [1].", sources: []) == "Rain [1].", "Export without sources is unchanged")
        try check(CitationResolver.exportText(recoverable, sources: [cold]) == recoverable, "Export keeps a text that has its own list")
        try check(CitationResolver.exportText("Rain [9].", sources: [cold]) == "Rain [9].", "Export without a resolving marker is unchanged")
        let untitled = PulseSource(n: 2, title: "", url: "https://example.com/glazing")
        let local = PulseSource(n: 3, title: "Saved notes", url: "knowledge")
        try check(CitationResolver.exportText("Rain [1] and wind [2] and [3].\n", sources: [local, untitled, cold])
                  == "Rain [1] and wind [2] and [3].\n\n## Sources\n\n1. Cold frames guide (https://example.org/cold)\n2. https://example.com/glazing\n",
                  "Export appends titled and untitled entries and skips a source with no web address")

        try expect("Read [1]before proceeding.", becomes: "Read before proceeding.", refs: [1])
        try expect("Read [1][2]before proceeding.", becomes: "Read before proceeding.", refs: [1, 2])
        try expect("Read [1]`code` next.", becomes: "Read `code` next.", refs: [1])
        try expect("Read [1][more](https://example.org/more).", becomes: "Read [more](https://example.org/more).", refs: [1])
        try expect("Read [1]", becomes: "Read", refs: [1])

        let quotedFence = "> ~~~\n> values[1]\n> ~~~\n\nAfter [1]."
        let quotedBlocks = CitationResolver.blocks(text: quotedFence, sources: all)
        try check(quotedBlocks.first == CitationBlock(text: "> ~~~\n> values[1]\n> ~~~", refs: [], isCode: false),
                  "A fence inside a quote is untouched, got \(quotedBlocks)")
        try check(quotedBlocks.last == CitationBlock(text: "After.", refs: [1], isCode: false), "Prose after a quoted fence is cited")
        let quotedOpen = CitationResolver.blocks(text: "> ```\n> a[1]\n\nLater [2].", sources: all)
        try check(quotedOpen.first?.text == "> ```\n> a[1]" && quotedOpen.last == CitationBlock(text: "Later.", refs: [2], isCode: false),
                  "An unclosed quoted fence ends with its quote, got \(quotedOpen)")
        try expect("> Quoted prose [1].", becomes: "> Quoted prose.", refs: [1])

        let flood = String(repeating: "[", count: 100_000) + " tail [1]."
        let started = Date()
        let flooded = CitationResolver.scan(flood, known: [1])
        try check(flooded.refs == [1] && flooded.text.hasSuffix(" tail."), "A flood of open brackets still resolves what follows")
        let parens = CitationResolver.scan(String(repeating: "[x](", count: 30_000), known: [1])
        try check(parens.refs.isEmpty, "A flood of open links cites nothing")
        let ticks = CitationResolver.scan((1...300).map { String(repeating: "`", count: $0) }.joined(separator: " "), known: [1])
        try check(ticks.refs.isEmpty, "A flood of code marks cites nothing")
        let spaced = CitationResolver.scan(String(repeating: " ", count: 100_000) + String(repeating: "[1]", count: 100_000), known: [1])
        try check(spaced.refs == [1] && spaced.text.count == 100_000, "Leading spaces before a run of markers are kept")
        let manyTicks = CitationResolver.scan((1...1500).map { String(repeating: "`", count: $0) }.joined(separator: " "), known: [1])
        try check(manyTicks.refs.isEmpty, "A longer flood of code marks cites nothing")
        let nested = CitationResolver.scan(
            String(repeating: "[", count: 100_000) + "x" + String(repeating: "]", count: 100_000) + " end [1].", known: [1])
        try check(nested.refs == [1] && nested.text.hasSuffix(" end."), "Deeply nested brackets still resolve what follows")
        let tailed = CitationResolver.recover("Fact [1].\n\n## Sources\n1. https://example.org/a" + String(repeating: ")", count: 3000))
        try check(tailed?.sources.first?.url == "https://example.org/a", "Surplus closing marks after an address are dropped, got \(String(describing: tailed?.sources.first?.url.count))")
        try check(CitationResolver.recover("Fact [1].\n\n## Sources\n1. " + String(repeating: "[", count: 100_000) + " https://example.org/a") == nil,
                  "An oversized entry is not recovered")
        let many = (1...10_000).map { PulseSource(n: $0, title: "Source \($0)", url: "https://example.org/\($0)") }
        let manyList = "Fact [1].\n\n## Sources\n" + many.map { "\($0.n). \($0.title)" }.joined(separator: "\n")
        try check(CitationResolver.withoutMatchingList(manyList, sources: many) == manyList, "An oversized list is left as written")
        let five = (1...500).map { PulseSource(n: $0, title: "Source \($0)", url: "https://example.org/\($0)") }
        let heavyBullets = "Fact [1].\n\n## Sources\n1. https://example.org/1\n"
            + (0..<900).map { _ in "- " + String(repeating: "[", count: 3900) + " https://example.org/500" }.joined(separator: "\n")
        try check(CitationResolver.withoutMatchingList(heavyBullets, sources: five) == "Fact [1].", "Heavy bullet entries are each read once")
        let heavyLinks = "Fact [1].\n\n## Sources\n"
            + (0..<900).map { _ in "1. " + String(repeating: "[a](x", count: 790) }.joined(separator: "\n")
        try check(CitationResolver.recover(heavyLinks) == nil, "A flood of open links in entries is not recovered")
        try check(Date().timeIntervalSince(started) < 5, "Hostile bracket floods are scanned in linear time")

        let fatTitle = "Fact [1].\n\n## Sources\n1. " + String(repeating: "a", count: 4001)
        try check(CitationResolver.withoutMatchingList(fatTitle, sources: [PulseSource(n: 1, title: "a", url: "https://example.org/a")]) == fatTitle,
                  "An oversized title entry keeps the list")
        let longTitle = "Fact [1].\n\n## Sources\n1. " + String(repeating: "a", count: 301)
        try check(CitationResolver.withoutMatchingList(longTitle, sources: [PulseSource(n: 1, title: "a", url: "https://example.org/a")]) == longTitle,
                  "A very long title entry keeps the list")
        let nestedLabel = CitationResolver.recover("Fact [1].\n\n## Sources\n1. [[1] Frost guide](https://example.org/frost)")
        try check(nestedLabel?.sources.first?.url == "https://example.org/frost", "A label with its own brackets still gives its address")

        try unchanged("Use `arr[1]\\`.")
        try expect("Use \\`not code [1] here`.", becomes: "Use \\`not code here`.", refs: [1])
        try expect("Text[1] [2].", becomes: "Text.", refs: [1, 2])
        try expect("Text[1] [2]", becomes: "Text", refs: [1, 2])
        try expect("  [1] [2] lead", becomes: "    lead", refs: [1, 2])
        let wikiTail = CitationResolver.recover("Fact [1].\n\n## Sources\n1. (https://example.org/Frost_(weather)).")
        try check(wikiTail?.sources.first?.url == "https://example.org/Frost_(weather)", "Balanced marks inside an address are kept")

        let splitFence = "> ~~~\n> quoted\n~~~\nvalue[1]\n~~~"
        try check(CitationResolver.scan(splitFence, known: [1]) == CitationResolver.Scan(text: splitFence, refs: [], markers: []),
                  "A fence after a quoted fence is its own code")
        try check(CitationResolver.blocks(text: splitFence, sources: all).allSatisfy { $0.refs.isEmpty }
                  && CitationResolver.blocks(text: splitFence, sources: all).map(\.text).joined(separator: "\n") == splitFence,
                  "Blocks keep both fences untouched")
        let longLink = "[1](https://example.org/?q=" + String(repeating: "a", count: 5000) + ")"
        try unchanged(longLink)
        try expect("Read [1][draft", becomes: "Read [draft", refs: [1])
        try expect("Read  [1]\n[2] next", becomes: "Read\n next", refs: [1, 2])

        let shouted = CitationResolver.resolve(text: "Rain [1].\n\n## Sources\n1. HTTPS://example.org/rain", sources: [])
        try check(shouted.recovered && sourceIsLinked(shouted.sources[0].url)
                  && NativeResearchReportSafety.destination(shouted.sources[0].url) != nil,
                  "A recovered address with a capital scheme is still a link")
        try check(!sourceIsLinked("knowledge") && !sourceIsLinked("javascript:alert(1)") && !sourceIsLinked("HTTPS:example"),
                  "Only web addresses count as links")

        let proseHeading = "## Sources\nWe interviewed several growers.\n\n## Findings\nFrost is likely [1]."
        try check(CitationResolver.exportText(proseHeading, sources: [cold])
                  == proseHeading + "\n\n## Sources\n\n1. Cold frames guide (https://example.org/cold)\n",
                  "A Sources heading over prose is not a written list, so export adds one")
        let bulleted = "Frost [1].\n\n## Sources\n- Cold frames guide"
        try check(CitationResolver.exportText(bulleted, sources: [cold]) == bulleted, "A bulleted written list is left as it is")

        print("  citation resolver OK")
    }
}
