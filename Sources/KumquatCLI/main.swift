import Foundation
import KumquatCore
import AppKit

let usage = """
kumquat-cli — Kumquat's converter from the command line

USAGE
  kumquat-cli convert <file>... --to <format> [--out <folder>] [--quality 0-1] [--crf N] [--bitrate kbps]
  kumquat-cli tool <tool-id> <file>... [--param <value>] [--out <folder>]
  kumquat-cli targets <file>        Formats a file can be converted to
  kumquat-cli tools <file>...       Tools that apply to the files
  kumquat-cli formats               Every known format
  kumquat-cli doctor                Which optional helpers are installed
  kumquat-cli recipes               Your recipes (~/Library/Application Support/Kumquat/recipes) and any problems
  kumquat-cli count                 Number of supported conversions
  kumquat-cli version               Kumquat version (also --version)

OUTPUT OPTIONS (convert and tool)
  --name <template>         Result name, e.g. "{name}-web" ({name} {format} {date} {time}); convert only
  --on-conflict <policy>    keepBoth (default), replace (existing file goes to the Trash) or skip
  --originals <policy>      keep (default) or trash
  --metadata <policy>       keep (default), removeLocation or removeAll
  --keep-dates <yes|no>     Copy the original's creation/modification dates
  --max-size <px>           Longest side of converted images
  --max-height <px>         Maximum video height, e.g. 1080
  --encoder <name>          automatic, hardware (VideoToolbox) or software
  --pdf-compression <level> light, balanced (default) or strong, for the pdfCompress tool
  --jobs <n>                Files a tool processes at once, 1-8 (default 3)

EXAMPLES
  kumquat-cli convert IMG_0001.HEIC --to jpg
  kumquat-cli convert talk.mov --to mp4
  kumquat-cli tool pdfMerge a.pdf b.pdf
  kumquat-cli tool pdfEncrypt report.pdf --param s3cret
"""

struct Arguments {
    var positional: [String] = []
    var flags: [String: String] = [:]

    init(_ raw: [String]) {
        var index = 0
        while index < raw.count {
            let item = raw[index]
            if item.hasPrefix("--"), index + 1 < raw.count {
                flags[String(item.dropFirst(2))] = raw[index + 1]
                index += 2
            } else {
                positional.append(item)
                index += 1
            }
        }
    }
}

func fileURL(_ path: String) -> URL {
    URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL
}

func makeOptions(_ args: Arguments) -> ConversionOptions {
    var options = ConversionOptions()
    if let quality = args.flags["quality"].flatMap(Double.init) { options.imageQuality = min(max(quality, 0.05), 1) }
    if let crf = args.flags["crf"].flatMap(Int.init) { options.videoCRF = crf }
    if let bitrate = args.flags["bitrate"].flatMap(Int.init) { options.audioBitrateKbps = bitrate }
    if let out = args.flags["out"] { options.outputLocation = .folder(out) }
    if let name = args.flags["name"] { options.fileNameTemplate = name }
    if let value = args.flags["on-conflict"] {
        guard let policy = ConflictPolicy(rawValue: value) else { fail("--on-conflict must be keepBoth, replace or skip") }
        options.conflictPolicy = policy
    }
    if let value = args.flags["originals"] {
        guard let policy = OriginalsPolicy(rawValue: value) else { fail("--originals must be keep or trash") }
        options.originals = policy
    }
    if let value = args.flags["metadata"] {
        guard let policy = MetadataPolicy(rawValue: value) else { fail("--metadata must be keep, removeLocation or removeAll") }
        options.metadata = policy
    }
    if let value = args.flags["keep-dates"] { options.preserveFileDates = ["yes", "true", "1"].contains(value.lowercased()) }
    if let size = args.flags["max-size"].flatMap(Int.init) { options.maxImageDimension = max(size, 0) }
    if let height = args.flags["max-height"].flatMap(Int.init) { options.maxVideoHeight = max(height, 0) }
    if let value = args.flags["encoder"] {
        guard let preference = VideoEncoderPreference(rawValue: value) else { fail("--encoder must be automatic, hardware or software") }
        options.videoEncoder = preference
    }
    if let value = args.flags["pdf-compression"] {
        guard let level = PDFCompression(rawValue: value) else { fail("--pdf-compression must be light, balanced or strong") }
        options.pdfCompression = level
    }
    return options
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

/// The version of the Kumquat.app this CLI ships in (Contents/Resources/bin/kumquat-cli), following
/// symlinks such as /usr/local/bin/kumquat-cli; "dev" for a build outside the app.
func cliVersion() -> String {
    // argv[0] is often just "kumquat-cli"; the executable URL is the real path the system launched.
    guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return "dev" }
    let plist = executable.deletingLastPathComponent()   // bin
        .deletingLastPathComponent()                      // Resources
        .deletingLastPathComponent()                      // Contents
        .appendingPathComponent("Info.plist")
    let info = NSDictionary(contentsOf: plist)
    return info?["CFBundleShortVersionString"] as? String ?? "dev"
}

func printProgress(_ fraction: Double) {
    let percent = Int(fraction * 100)
    FileHandle.standardError.write(Data("\r  \(percent)%".utf8))
}

// HTML import and PDF printing use AppKit; make sure an application object exists.
_ = NSApplication.shared

let args = Arguments(Array(CommandLine.arguments.dropFirst()))
let recipes = UserRecipes.load()
let converter = Converter(recipes: recipes.recipes)
let catalog = converter.catalog()

guard let command = args.positional.first else {
    print(usage)
    exit(0)
}
let operands = Array(args.positional.dropFirst())

switch command {
case "version", "--version", "-v":
    print("kumquat-cli \(cliVersion())")
    exit(0)

case "convert":
    recipes.problems.forEach { FileHandle.standardError.write(Data("warning: recipe \($0)\n".utf8)) }
    guard let to = args.flags["to"], let target = FormatRegistry.format(id: to) ?? FormatRegistry.format(forExtension: to) else {
        fail("--to <format> is required (see `kumquat-cli formats`).")
    }
    guard !operands.isEmpty else { fail("No input files.") }
    var failed = false
    for path in operands {
        let url = fileURL(path)
        do {
            let output = try await converter.convert(url, to: target, options: makeOptions(args)) { printProgress($0) }
            FileHandle.standardError.write(Data("\r".utf8))
            print("✓ \(url.lastPathComponent) → \(output.path)")
        } catch {
            FileHandle.standardError.write(Data("\r".utf8))
            print("✗ \(url.lastPathComponent): \(error.localizedDescription)")
            failed = true
        }
    }
    exit(failed ? 1 : 0)

case "tool":
    guard let id = operands.first, let tool = ToolID(rawValue: id) else {
        fail("Unknown tool. Available: " + ToolID.allCases.map(\.rawValue).joined(separator: ", "))
    }
    let urls = operands.dropFirst().map(fileURL)
    guard !urls.isEmpty else { fail("No input files.") }
    do {
        let jobs = args.flags["jobs"].flatMap(Int.init).map { min(max($0, 1), 8) } ?? 3
        let outcome = try await converter.run(tool, inputs: Array(urls), parameter: args.flags["param"], options: makeOptions(args),
                                              concurrency: jobs)
        FileHandle.standardError.write(Data("\r".utf8))
        outcome.outputs.forEach { print("✓ \($0.path)") }
        if let message = outcome.message { print(message) }
        if let text = outcome.clipboardText { print(text) }
        outcome.failures.forEach { print("✗ \($0)") }
        if !outcome.failures.isEmpty { exit(1) }
    } catch {
        fail(error.localizedDescription)
    }

case "targets":
    guard let path = operands.first else { fail("No input file.") }
    let items = catalog.conversions(for: [fileURL(path)])
    if items.isEmpty { print("No conversions for this file.") }
    for item in items {
        print(item.isAvailable ? "  \(item.title)" : "  \(item.title)  (\(item.unavailableReason ?? ""))")
    }

case "tools":
    let items = catalog.tools(for: operands.map(fileURL))
    for item in items {
        guard case .tool(let tool) = item.payload else { continue }
        let status = item.isAvailable ? "" : "  (\(item.unavailableReason ?? ""))"
        print("  \(tool.rawValue.padding(toLength: 24, withPad: " ", startingAt: 0)) \(tool.detail)\(status)")
    }

case "formats":
    for kind in FileKind.allCases {
        let formats = FormatRegistry.all.filter { $0.kind == kind }
        guard !formats.isEmpty else { continue }
        print("\(kind.displayName): " + formats.map { "\($0.shortName.lowercased())" }.joined(separator: ", "))
    }

case "doctor":
    let locator = ToolLocator()
    for dependency in Dependency.allCases {
        let mark = locator.isAvailable(dependency) ? "✓" : "✗"
        print("\(mark) \(dependency.displayName.padding(toLength: 12, withPad: " ", startingAt: 0)) \(dependency.purpose)")
        if !locator.isAvailable(dependency) { print("    → \(dependency.installHint)") }
    }
    print("\nEngines: " + converter.availableEngines.map(\.rawValue).sorted().joined(separator: ", "))

case "recipes":
    print("Folder: \(UserRecipes.directory.path)")
    if recipes.recipes.isEmpty && recipes.problems.isEmpty { print("No recipes yet (see README ▸ User recipes).") }
    for recipe in recipes.recipes {
        let from = recipe.from.map { $0.shortName.lowercased() }.joined(separator: ", ")
        print("✓ \(recipe.name): \(from) → \(recipe.to.shortName.lowercased())  (\(recipe.file.lastPathComponent), timeout \(Int(recipe.timeout))s)")
    }
    recipes.problems.forEach { print("✗ \($0)") }
    exit(recipes.problems.isEmpty ? 0 : 1)

case "count":
    print("\(converter.graph.conversionCount(engines: converter.availableEngines)) conversions, \(ToolID.allCases.count) tools, \(ActionID.allCases.count) actions")

default:
    print(usage)
    exit(1)
}
