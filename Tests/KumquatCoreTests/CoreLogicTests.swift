import XCTest
@testable import KumquatCore

final class FormatRegistryTests: XCTestCase {
    func testDetectsFormatsCaseInsensitively() {
        XCTAssertEqual(FormatRegistry.format(for: URL(fileURLWithPath: "/tmp/IMG_0001.HEIC")), .heic)
        XCTAssertEqual(FormatRegistry.format(for: URL(fileURLWithPath: "/tmp/photo.jpeg")), .jpg)
        XCTAssertEqual(FormatRegistry.format(for: URL(fileURLWithPath: "/tmp/scan.TIF")), .tiff)
        XCTAssertEqual(FormatRegistry.format(for: URL(fileURLWithPath: "/tmp/raw.CR3")), .raw)
        XCTAssertNil(FormatRegistry.format(for: URL(fileURLWithPath: "/tmp/README")))
    }

    func testCompoundExtensions() {
        let url = URL(fileURLWithPath: "/tmp/backup.2024.tar.gz")
        XCTAssertEqual(FormatRegistry.format(for: url), .tgz)
        XCTAssertEqual(FormatRegistry.baseName(of: url), "backup.2024")
        XCTAssertEqual(FormatRegistry.format(for: URL(fileURLWithPath: "/tmp/notes.gz")), .gz)
    }

    func testBaseNameKeepsDots() {
        XCTAssertEqual(FormatRegistry.baseName(of: URL(fileURLWithPath: "/tmp/v1.2 final.docx")), "v1.2 final")
    }

    func testAllFormatsHaveUniqueIDs() {
        XCTAssertEqual(Set(FormatRegistry.all.map(\.id)).count, FormatRegistry.all.count)
    }
}

final class ConversionGraphTests: XCTestCase {
    let graph = ConversionGraph.standard
    let everyEngine = Set(EngineID.allCases)

    func testDirectRoute() throws {
        let route = try XCTUnwrap(graph.route(from: .heic, to: .jpg))
        XCTAssertEqual(route.edges.count, 1)
        XCTAssertEqual(route.edges[0].engine, .image)
    }

    func testMultiHopRoutes() throws {
        let sheet = try XCTUnwrap(graph.route(from: .xlsx, to: .json))
        XCTAssertEqual(sheet.edges.map(\.to), [.csv, .json])

        let pdfToWord = try XCTUnwrap(graph.route(from: .pdf, to: .docx))
        XCTAssertEqual(pdfToWord.target, .docx)
        XCTAssertLessThanOrEqual(pdfToWord.edges.count, 3)
    }

    func testPrefersInstalledDependencies() throws {
        let withOffice = try XCTUnwrap(graph.bestRoute(from: .docx, to: .pdf, engines: everyEngine, available: [.libreOffice]))
        XCTAssertEqual(withOffice.edges.map(\.engine), [.office])
        let native = try XCTUnwrap(graph.bestRoute(from: .docx, to: .pdf, engines: everyEngine, available: []))
        XCTAssertEqual(native.edges.map(\.engine), [.document])
    }

    func testReportsMissingDependencyRoute() throws {
        let route = try XCTUnwrap(graph.bestRoute(from: .mov, to: .mp4, engines: everyEngine, available: []))
        XCTAssertEqual(route.requirements, [.ffmpeg])
    }

    func testTargetPolicyBlocksNonsense() {
        let jpgTargets = graph.targets(for: .jpg)
        XCTAssertTrue(jpgTargets.contains(.png))
        XCTAssertTrue(jpgTargets.contains(.pdf))
        XCTAssertFalse(jpgTargets.contains(.txt))
        XCTAssertFalse(jpgTargets.contains(.jpg))
        XCTAssertFalse(graph.targets(for: .mp3).contains(.mp4))
        XCTAssertTrue(graph.targets(for: .mp4).contains(.mp3))
        XCTAssertTrue(graph.targets(for: .gif).contains(.mp4))
    }

    func testRespectsEngineAvailability() {
        let noImages = everyEngine.subtracting([.image])
        XCTAssertTrue(graph.targets(for: .png, engines: noImages).isEmpty)
    }

    func testCoverageIsBroad() {
        // Tangerine advertises 275 conversions; Kumquat should cover at least as many.
        XCTAssertGreaterThanOrEqual(graph.conversionCount(), 275)
    }
}

final class CatalogTests: XCTestCase {
    func catalog(_ available: Set<Dependency> = Set(Dependency.allCases)) -> Catalog {
        Catalog(engines: Set(EngineID.allCases), available: available, macOSMajorVersion: 15)
    }

    func testConversionsIntersectAcrossFiles() {
        let items = catalog().conversions(for: [URL(fileURLWithPath: "/a.png"), URL(fileURLWithPath: "/b.mp4")])
        XCTAssertTrue(items.isEmpty)
        let images = catalog().conversions(for: [URL(fileURLWithPath: "/a.png"), URL(fileURLWithPath: "/b.heic")])
        XCTAssertTrue(images.contains { $0.payload == .convert(.jpg) })
        XCTAssertTrue(images.contains { $0.payload == .convert(.png) }, "HEIC can still become PNG")
    }

    func testUnavailableReasonNamesTheHelper() throws {
        let items = catalog([]).conversions(for: [URL(fileURLWithPath: "/clip.mov")])
        let mp4 = try XCTUnwrap(items.first { $0.payload == .convert(.mp4) })
        XCTAssertFalse(mp4.isAvailable)
        XCTAssertTrue(mp4.unavailableReason?.contains("brew install ffmpeg") ?? false)
    }

    func testToolsForMultiplePDFsIncludeMerge() {
        let tools = catalog().tools(for: [URL(fileURLWithPath: "/a.pdf"), URL(fileURLWithPath: "/b.pdf")])
        XCTAssertTrue(tools.contains { $0.payload == .tool(.pdfMerge) })
        let single = catalog().tools(for: [URL(fileURLWithPath: "/a.pdf")])
        XCTAssertFalse(single.contains { $0.payload == .tool(.pdfMerge) })
        XCTAssertTrue(single.contains { $0.payload == .tool(.pdfRedactPersonalInfo) })
    }

    func testBackgroundRemovalNeedsSonoma() throws {
        let old = Catalog(engines: Set(EngineID.allCases), available: [], macOSMajorVersion: 13)
        let item = try XCTUnwrap(old.tools(for: [URL(fileURLWithPath: "/p.jpg")]).first { $0.payload == .tool(.imageRemoveBackground) })
        XCTAssertEqual(item.unavailableReason, "Requires macOS 14")
    }

    func testActionsAlwaysOffered() {
        XCTAssertEqual(catalog().actions(for: [URL(fileURLWithPath: "/anything.xyz")]).count, ActionID.allCases.count)
    }
}

final class OutputNamerTests: XCTestCase {
    func testUniqueNames() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = OutputNamer.uniqueURL(in: dir, baseName: "photo", extension: "jpg")
        XCTAssertEqual(first.lastPathComponent, "photo.jpg")
        FileManager.default.createFile(atPath: first.path, contents: Data())
        XCTAssertEqual(OutputNamer.uniqueURL(in: dir, baseName: "photo", extension: "jpg").lastPathComponent, "photo 2.jpg")

        let archive = dir.appendingPathComponent("logs.tar.gz")
        FileManager.default.createFile(atPath: archive.path, contents: Data())
        XCTAssertEqual(OutputNamer.uniqueURL(in: dir, fileName: "logs.tar.gz").lastPathComponent, "logs 2.tar.gz")
    }
}

final class SubtitleTests: XCTestCase {
    let srt = """
    1
    00:00:01,000 --> 00:00:03,500
    Hello <i>world</i>

    2
    00:01:02,250 --> 00:01:04,000
    Second line
    continues here

    """

    func testParsesSRT() {
        let cues = Subtitles.parse(srt)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].start, 1.0, accuracy: 0.0001)
        XCTAssertEqual(cues[1].start, 62.25, accuracy: 0.0001)
        XCTAssertEqual(cues[1].text, "Second line\ncontinues here")
    }

    func testRoundTripThroughVTT() {
        let vtt = Subtitles.vtt(from: Subtitles.parse(srt))
        XCTAssertTrue(vtt.hasPrefix("WEBVTT"))
        XCTAssertTrue(vtt.contains("00:01:02.250 --> 00:01:04.000"))
        XCTAssertEqual(Subtitles.parse(vtt), Subtitles.parse(srt))
    }

    func testParsesShortVTTTimestampsAndSettings() {
        let vtt = "WEBVTT\n\nNOTE comment\n\n01:02.500 --> 01:03.000 align:start\n<v Bob>Hi</v>\n"
        let cues = Subtitles.parse(vtt)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].start, 62.5, accuracy: 0.0001)
        XCTAssertTrue(Subtitles.srt(from: cues).contains("\nHi\n"))
    }

    func testPlainText() {
        XCTAssertEqual(Subtitles.plainText(from: Subtitles.parse(srt)), "Hello world\nSecond line\ncontinues here\n")
    }
}

final class TableTests: XCTestCase {
    func testParsesQuotedFields() {
        let rows = Table.parse("name,quote\n\"Smith, J\",\"He said \"\"hi\"\"\"\r\nDoe,\"multi\nline\"\n")
        XCTAssertEqual(rows, [["name", "quote"], ["Smith, J", "He said \"hi\""], ["Doe", "multi\nline"]])
    }

    func testSerializeRoundTrip() {
        let rows = [["a", "b,c"], ["\"q\"", "line\nbreak"]]
        XCTAssertEqual(Table.parse(Table.serialize(rows)), rows)
    }

    func testTSV() {
        XCTAssertEqual(Table.parse("a\tb\n1\t2", delimiter: "\t"), [["a", "b"], ["1", "2"]])
    }

    func testJSONKeepsColumnOrder() throws {
        let json = Table.json(from: [["zeta", "alpha"], ["1", "two \"2\""]])
        XCTAssertTrue(json.contains("\"zeta\": \"1\",\n    \"alpha\": \"two \\\"2\\\"\""))
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: String]]
        XCTAssertEqual(parsed?.first?["alpha"], "two \"2\"")
    }

    func testRowsFromJSON() throws {
        let rows = try Table.rows(fromJSON: Data(#"[{"b":2,"a":"x"},{"a":"y","c":null}]"#.utf8))
        XCTAssertEqual(rows, [["a", "b", "c"], ["x", "2", ""], ["y", "", ""]])
    }

    func testMarkdownTable() {
        XCTAssertEqual(Table.markdown(from: [["h1", "h2"], ["a|b", "c"]]), "| h1 | h2 |\n| --- | --- |\n| a\\|b | c |\n")
    }
}

final class MarkdownTests: XCTestCase {
    func render(_ markdown: String) -> String { MarkdownRenderer.renderBody(markdown) }

    func testHeadingsAndParagraphs() {
        XCTAssertEqual(render("# Title\n\nSome *text* and **bold**."),
                       "<h1>Title</h1>\n<p>Some <em>text</em> and <strong>bold</strong>.</p>")
        XCTAssertEqual(render("Setext\n---"), "<h2>Setext</h2>")
    }

    func testLinksAndCodeAreNotMangled() {
        XCTAssertEqual(render("See [the_docs](https://x.com/a_b_c) and `a*b*c`."),
                       "<p>See <a href=\"https://x.com/a_b_c\">the_docs</a> and <code>a*b*c</code>.</p>")
        XCTAssertEqual(render("snake_case_name stays"), "<p>snake_case_name stays</p>")
    }

    func testEscapesHTML() {
        XCTAssertEqual(render("1 < 2 & \"q\""), "<p>1 &lt; 2 &amp; &quot;q&quot;</p>")
    }

    func testLists() {
        XCTAssertEqual(render("- one\n- two\n  - nested\n- [x] done"),
                       "<ul>\n<li>one</li>\n<li>two\n<ul>\n<li>nested</li>\n</ul></li>\n<li><input type=\"checkbox\" disabled checked> done</li>\n</ul>")
        XCTAssertEqual(render("3. c\n4. d"), "<ol start=\"3\">\n<li>c</li>\n<li>d</li>\n</ol>")
    }

    func testFencedCodeAndQuote() {
        XCTAssertEqual(render("```swift\nlet x = 1 < 2\n```"),
                       "<pre><code class=\"language-swift\">let x = 1 &lt; 2</code></pre>")
        XCTAssertEqual(render("> quoted"), "<blockquote>\n<p>quoted</p>\n</blockquote>")
    }

    func testTables() {
        XCTAssertEqual(render("| a | b |\n|:--|--:|\n| 1 | 2 |"),
                       "<table>\n<thead><tr><th style=\"text-align: left\">a</th><th style=\"text-align: right\">b</th></tr></thead>\n<tbody>\n<tr><td style=\"text-align: left\">1</td><td style=\"text-align: right\">2</td></tr>\n</tbody>\n</table>")
    }

    func testRuleAndImage() {
        XCTAssertEqual(render("***"), "<hr>")
        XCTAssertEqual(render("![logo](img/logo.png)"), "<p><img src=\"img/logo.png\" alt=\"logo\"></p>")
    }
}

final class FFmpegRecipeTests: XCTestCase {
    func testRemuxWhenCompatible() {
        let probe = MediaProbe(duration: 3, videoCodec: "h264", audioCodec: "aac")
        XCTAssertTrue(FFmpegRecipes.canRemux(probe, into: .mp4))
        let args = FFmpegRecipes.conversionArguments(input: "in.mov", output: "out.mp4", source: .mov, target: .mp4,
                                                     probe: probe, options: ConversionOptions())
        XCTAssertTrue(args.contains("copy"))
        XCTAssertFalse(args.contains("libx264"))
    }

    func testReencodesWhenIncompatible() {
        let probe = MediaProbe(videoCodec: "vp9", audioCodec: "opus")
        XCTAssertFalse(FFmpegRecipes.canRemux(probe, into: .mp4))
        let args = FFmpegRecipes.conversionArguments(input: "in.webm", output: "out.mp4", source: .webm, target: .mp4,
                                                     probe: probe, options: ConversionOptions())
        XCTAssertTrue(args.contains("libx264"))
        XCTAssertEqual(args.last, "out.mp4")
    }

    func testHEVCGetsAppleTag() {
        let args = FFmpegRecipes.conversionArguments(input: "a.mkv", output: "a.mov", source: .mkv, target: .mov,
                                                     probe: MediaProbe(videoCodec: "hevc", audioCodec: "aac"), options: ConversionOptions())
        XCTAssertTrue(args.contains("hvc1"))
    }

    func testAudioExtraction() {
        var options = ConversionOptions()
        options.audioBitrateKbps = 256
        let args = FFmpegRecipes.conversionArguments(input: "v.mp4", output: "a.mp3", source: .mp4, target: .mp3, probe: nil, options: options)
        XCTAssertTrue(args.contains("-vn"))
        XCTAssertTrue(args.contains("256k"))
    }

    func testProbeParsingSkipsCoverArt() {
        let json = #"{"streams":[{"codec_type":"video","codec_name":"mjpeg"},{"codec_type":"audio","codec_name":"mp3","sample_rate":"44100"}],"format":{"duration":"12.5"}}"#
        let probe = FFmpegRecipes.parseProbe(Data(json.utf8))
        XCTAssertEqual(probe, MediaProbe(duration: 12.5, videoCodec: nil, audioCodec: "mp3", sampleRate: 44100))
    }

    func testProgressParsing() {
        XCTAssertEqual(FFmpegRecipes.progressSeconds(fromLine: "out_time_us=2500000"), 2.5)
        XCTAssertNil(FFmpegRecipes.progressSeconds(fromLine: "frame=10"))
    }

    func testToolOutputFormats() {
        XCTAssertEqual(FFmpegRecipes.toolOutputFormat(.videoExtractAudio, source: .mov), .m4a)
        XCTAssertEqual(FFmpegRecipes.toolOutputFormat(.audioCompress, source: .wav), .m4a)
        XCTAssertEqual(FFmpegRecipes.toolOutputFormat(.audioCompress, source: .mp3), .mp3)
        XCTAssertEqual(FFmpegRecipes.toolOutputFormat(.videoMute, source: .flv), .mkv)
    }
}

final class IWorkScriptTests: XCTestCase {
    func testExportScript() throws {
        let script = try XCTUnwrap(IWorkScripts.script(input: "/a/My \"Doc\".pages", output: "/b/out.pdf", source: .pages, target: .pdf))
        XCTAssertTrue(script.contains("tell application \"Pages\""))
        XCTAssertTrue(script.contains("export theDoc to outFile as PDF"))
        XCTAssertTrue(script.contains("POSIX file \"/a/My \\\"Doc\\\".pages\""))
    }

    func testImportScriptSavesNatively() throws {
        let script = try XCTUnwrap(IWorkScripts.script(input: "/a.pptx", output: "/a.key", source: .pptx, target: .key))
        XCTAssertTrue(script.contains("tell application \"Keynote\""))
        XCTAssertTrue(script.contains("save theDoc in outFile"))
    }
}
