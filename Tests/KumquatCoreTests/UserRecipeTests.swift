import XCTest
@testable import KumquatCore

final class UserRecipeTests: TemporaryDirectoryTestCase {
    var recipes: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        recipes = directory.appendingPathComponent("recipes", isDirectory: true)
        try FileManager.default.createDirectory(at: recipes, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: recipes.path)
    }

    @discardableResult
    func recipe(_ name: String, _ json: String, permissions: Int = 0o644) throws -> URL {
        let url = recipes.appendingPathComponent(name)
        try json.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        return url
    }

    func testParsing() throws {
        let file = URL(fileURLWithPath: "/tmp/upper.json")
        let parsed = try UserRecipes.parse(Data("""
        {"name": " Shout ", "from": ["txt", "MD"], "to": "html", "command": ["tr", "{input}", "--out={output}"], "timeout": 99999}
        """.utf8), file: file)
        XCTAssertEqual(parsed.name, "Shout")
        XCTAssertEqual(parsed.from, [.txt, .md])
        XCTAssertEqual(parsed.to, .html)
        XCTAssertEqual(parsed.timeout, UserRecipe.maximumTimeout, "capped at an hour")
        XCTAssertEqual(parsed.arguments(input: URL(fileURLWithPath: "/a b/in.txt"), output: URL(fileURLWithPath: "/w/out.html")),
                       ["/a b/in.txt", "--out=/w/out.html"], "one argument each, spaces and all: no shell")

        let single = try UserRecipes.parse(Data(#"{"from": "csv", "to": "json", "command": ["/bin/x", "{input}", "{output}"]}"#.utf8), file: file)
        XCTAssertEqual(single.name, "upper")
        XCTAssertEqual(single.timeout, UserRecipe.defaultTimeout)

        let bad: [String: String] = [
            "not json": "nope",
            "unknown format": #"{"from": "xyz", "to": "pdf", "command": ["/bin/x", "{input}", "{output}"]}"#,
            "same format": #"{"from": "pdf", "to": "pdf", "command": ["/bin/x", "{input}", "{output}"]}"#,
            "shell string": #"{"from": "md", "to": "pdf", "command": "pandoc {input} -o {output}"}"#,
            "no output": #"{"from": "md", "to": "pdf", "command": ["/bin/x", "{input}"]}"#,
            "no input": #"{"from": "md", "to": "pdf", "command": ["/bin/x", "{output}"]}"#,
            "placeholder program": #"{"from": "md", "to": "pdf", "command": ["{input}", "{output}"]}"#,
            "bad timeout": #"{"from": "md", "to": "pdf", "command": ["/bin/x", "{input}", "{output}"], "timeout": -1}"#,
            "no from": #"{"to": "pdf", "command": ["/bin/x", "{input}", "{output}"]}"#,
        ]
        for (label, json) in bad {
            XCTAssertThrowsError(try UserRecipes.parse(Data(json.utf8), file: file), label)
        }
    }

    func testLoadingReportsEveryProblem() throws {
        try recipe("a-good.json", #"{"from": "txt", "to": "md", "command": ["/bin/cp", "{input}", "{output}"]}"#)
        try recipe("b-broken.json", #"{"from": "txt""#)
        try recipe("c-duplicate.json", #"{"from": ["txt"], "to": "md", "command": ["/bin/cp", "{input}", "{output}"]}"#)
        try recipe("d-shared.json", #"{"from": "csv", "to": "md", "command": ["/bin/cp", "{input}", "{output}"]}"#, permissions: 0o666)
        try FileManager.default.createSymbolicLink(at: recipes.appendingPathComponent("e-link.json"),
                                                   withDestinationURL: recipes.appendingPathComponent("a-good.json"))
        try "ignored".write(to: recipes.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let result = UserRecipes.load(from: recipes)
        XCTAssertEqual(result.recipes.map(\.file.lastPathComponent), ["a-good.json"])
        XCTAssertEqual(result.problems.count, 4, result.problems.description)
        XCTAssertTrue(result.problems.contains { $0.hasPrefix("b-broken.json:") })
        XCTAssertTrue(result.problems.contains { $0.hasPrefix("c-duplicate.json:") && $0.contains("already") })
        XCTAssertTrue(result.problems.contains { $0.hasPrefix("d-shared.json:") && $0.contains("other users") })
        XCTAssertTrue(result.problems.contains { $0.hasPrefix("e-link.json:") && $0.contains("link") })

        XCTAssertEqual(UserRecipes.load(from: directory.appendingPathComponent("missing")), UserRecipes.LoadResult())
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: recipes.path)
        let open = UserRecipes.load(from: recipes)
        XCTAssertTrue(open.recipes.isEmpty, "a folder anyone can write to is not trusted")
        XCTAssertEqual(open.problems.count, 1)
    }

    func testFingerprintAndNewFolder() throws {
        let before = UserRecipes.fingerprint(of: recipes)
        XCTAssertEqual(UserRecipes.fingerprint(of: recipes), before)
        let file = try recipe("a.json", #"{"from": "txt", "to": "md", "command": ["/bin/cp", "{input}", "{output}"]}"#)
        let added = UserRecipes.fingerprint(of: recipes)
        XCTAssertNotEqual(added, before)
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: file.path)
        XCTAssertNotEqual(UserRecipes.fingerprint(of: recipes), added, "a permission change counts")

        let fresh = directory.appendingPathComponent("new/recipes")
        try UserRecipes.createFolder(at: fresh)
        let loaded = UserRecipes.load(from: fresh)
        XCTAssertEqual(loaded, UserRecipes.LoadResult(), "the example stays inactive")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.appendingPathComponent("example.json.disabled").path))
        // Enabling the example gives a valid recipe.
        try FileManager.default.moveItem(at: fresh.appendingPathComponent("example.json.disabled"),
                                         to: fresh.appendingPathComponent("example.json"))
        XCTAssertEqual(UserRecipes.load(from: fresh).recipes.first?.to, .pdf)
    }

    func testRecipeBecomesAConversionAndRuns() async throws {
        // A target the built-in policy wouldn't offer (CSV → TXT), chained after a built-in hop (TSV → CSV).
        try recipe("csv-to-text.json", """
        {"name": "Copy as text", "from": "csv", "to": "txt", "command": ["/bin/cp", "{input}", "{output}"], "timeout": 10}
        """)
        let loaded = UserRecipes.load(from: recipes)
        XCTAssertEqual(loaded.problems, [])
        let converter = Converter(recipes: loaded.recipes)
        let csv = try file("table.csv", "a,b\n1,2\n")
        XCTAssertTrue(converter.catalog().conversions(for: [csv]).contains { $0.payload == .convert(.txt) })
        XCTAssertFalse(Converter().catalog().conversions(for: [csv]).contains { $0.payload == .convert(.txt) },
                       "only with the recipe")

        let output = try await converter.convert(csv, to: .txt)
        XCTAssertEqual(output.lastPathComponent, "table.txt")
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "a,b\n1,2\n")

        let tsv = try file("sheet.tsv", "a\tb\n")
        let chained = try await converter.convert(tsv, to: .txt)
        XCTAssertEqual(try String(contentsOf: chained, encoding: .utf8), "a,b\n")
    }

    func testRecipeFailuresAreReported() async throws {
        func run(_ command: String, timeout: Int = 30) async -> String {
            try? FileManager.default.removeItem(at: recipes.appendingPathComponent("r.json"))
            try? recipe("r.json", #"{"name": "R", "from": "csv", "to": "txt", "command": \#(command), "timeout": \#(timeout)}"#)
            let converter = Converter(recipes: UserRecipes.load(from: recipes).recipes)
            do {
                let csv = try file("in-\(UUID().uuidString).csv", "x\n")
                _ = try await converter.convert(csv, to: .txt)
                return "succeeded"
            } catch {
                return error.localizedDescription
            }
        }
        let failing = await run(#"["/bin/sh", "-c", "echo broken pipe >&2; exit 3", "{input}", "{output}"]"#)
        XCTAssertTrue(failing.contains("exit 3") && failing.contains("broken pipe"), failing)
        let silent = await run(#"["/usr/bin/true", "{input}", "{output}"]"#)
        XCTAssertTrue(silent.contains("didn't write"), silent)
        let missing = await run(#"["no-such-tool-kumquat", "{input}", "{output}"]"#)
        XCTAssertTrue(missing.contains("wasn't found"), missing)
        let slow = await run(#"["/bin/sh", "-c", "sleep 5", "{input}", "{output}"]"#, timeout: 1)
        XCTAssertTrue(slow.contains("1 seconds"), slow)
    }
}
