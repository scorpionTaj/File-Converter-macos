import Foundation

/// A conversion the user adds by dropping a JSON file into the recipes folder. It becomes an edge of the
/// conversion graph, so it shows on the Convert wheel and can be chained with built-in conversions.
///
///     {
///       "name": "Markdown → PDF with my style",
///       "from": ["md"],
///       "to": "pdf",
///       "command": ["/opt/homebrew/bin/pandoc", "{input}", "-o", "{output}", "--css", "/Users/me/style.css"],
///       "timeout": 120
///     }
///
/// Safety: the command is an argument list run directly, never through a shell, so file names can't inject
/// commands; `{input}` and `{output}` are replaced inside each argument. Only regular files owned by you and
/// not writable by others, directly in the folder, are loaded. Each run has a timeout, and failures report
/// the command's own error output.
public struct UserRecipe: Equatable, Sendable {
    public var name: String
    public var from: [Format]
    public var to: Format
    /// Program and arguments. The program is an absolute path or a name found on the helper search path.
    public var command: [String]
    public var timeout: TimeInterval
    /// The JSON file it came from.
    public var file: URL

    public static let defaultTimeout: TimeInterval = 300
    public static let maximumTimeout: TimeInterval = 3600

    public init(name: String, from: [Format], to: Format, command: [String], timeout: TimeInterval = defaultTimeout, file: URL) {
        self.name = name
        self.from = from
        self.to = to
        self.command = command
        self.timeout = timeout
        self.file = file
    }

    /// Arguments with the placeholders filled in.
    public func arguments(input: URL, output: URL) -> [String] {
        command.dropFirst().map {
            $0.replacingOccurrences(of: "{input}", with: input.path).replacingOccurrences(of: "{output}", with: output.path)
        }
    }
}

/// Loads recipes and reports, rather than hides, every file it skipped and why.
public enum UserRecipes {
    public struct LoadResult: Equatable, Sendable {
        public var recipes: [UserRecipe] = []
        /// "file.json: reason" for files that weren't loaded.
        public var problems: [String] = []

        public init(recipes: [UserRecipe] = [], problems: [String] = []) {
            self.recipes = recipes
            self.problems = problems
        }
    }

    /// ~/Library/Application Support/Kumquat/recipes
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Kumquat/recipes", isDirectory: true)
    }

    static let maximumFileSize = 64 * 1024

    public static func load(from directory: URL = directory) -> LoadResult {
        var result = LoadResult()
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return result }
        if let problem = unsafeOwnership(of: directory, isFolder: true) {
            result.problems.append("\(directory.lastPathComponent): \(problem)")
            return result
        }
        let files: [URL]
        do {
            files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                .filter { $0.pathExtension.lowercased() == "json" }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        } catch {
            result.problems.append("\(directory.lastPathComponent): \(error.localizedDescription)")
            return result
        }
        var pairs = Set<String>()
        for file in files {
            do {
                if let problem = unsafeOwnership(of: file, isFolder: false) { throw KumquatError.invalidInput(problem) }
                let recipe = try parse(try Data(contentsOf: file), file: file)
                let duplicates = recipe.from.filter { pairs.contains("\($0.id)>\(recipe.to.id)") }
                guard duplicates.isEmpty else {
                    throw KumquatError.invalidInput("another recipe already converts \(duplicates.map(\.shortName).joined(separator: ", ")) to \(recipe.to.shortName)")
                }
                recipe.from.forEach { pairs.insert("\($0.id)>\(recipe.to.id)") }
                result.recipes.append(recipe)
            } catch {
                result.problems.append("\(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return result
    }

    /// Changes whenever a recipe file is added, removed, edited or has its permissions changed, so callers can
    /// reload only when needed.
    public static func fingerprint(of directory: URL = directory) -> String {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
        return ([directory.path] + names).map { name -> String in
            let path = name == directory.path ? name : directory.appendingPathComponent(name).path
            var info = stat()
            guard lstat(path, &info) == 0 else { return name }
            return "\(name):\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec):\(info.st_size):\(info.st_mode):\(info.st_uid)"
        }.joined(separator: "|")
    }

    /// Creates the recipes folder (writable only by you) with an example recipe that stays inactive until
    /// it's renamed to .json.
    public static func createFolder(at directory: URL = directory) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: directory.path) else { return }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let example = """
        {
          "name": "Markdown to PDF with my stylesheet",
          "from": ["md"],
          "to": "pdf",
          "command": ["/opt/homebrew/bin/pandoc", "{input}", "-o", "{output}", "--css", "/path/to/style.css"],
          "timeout": 120
        }

        """
        try example.write(to: directory.appendingPathComponent("example.json.disabled"), atomically: true, encoding: .utf8)
    }

    /// Why a recipe file or the folder can't be trusted, or nil. Links are refused so a recipe can only be
    /// a file actually placed in the folder; files others can write could be changed behind your back.
    static func unsafeOwnership(of url: URL, isFolder: Bool) -> String? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return "can't be read" }
        let type = info.st_mode & S_IFMT
        if type == S_IFLNK { return "is a link; put the recipe file itself in the folder" }
        if isFolder ? type != S_IFDIR : type != S_IFREG { return isFolder ? "isn't a folder" : "isn't a regular file" }
        if info.st_uid != getuid() { return "isn't owned by you" }
        if info.st_mode & (S_IWGRP | S_IWOTH) != 0 { return "can be changed by other users (chmod go-w)" }
        if !isFolder, info.st_size > maximumFileSize { return "is larger than 64 KB" }
        return nil
    }

    public static func parse(_ data: Data, file: URL) throws -> UserRecipe {
        guard let json = try? JSONSerialization.jsonObject(with: data), let object = json as? [String: Any] else {
            throw KumquatError.invalidInput("isn't a JSON object")
        }
        func format(_ value: Any?, _ key: String) throws -> Format {
            guard let text = value as? String,
                  let format = FormatRegistry.format(id: text.lowercased()) ?? FormatRegistry.format(forExtension: text) else {
                throw KumquatError.invalidInput("“\(key)”: \(value.map { "\($0)" } ?? "missing") isn't a format Kumquat knows (see kumquat-cli formats)")
            }
            return format
        }
        let fromValues: [Any] = (object["from"] as? [Any]) ?? (object["from"].map { [$0] } ?? [])
        guard !fromValues.isEmpty else { throw KumquatError.invalidInput("“from” is missing") }
        let from = try fromValues.map { try format($0, "from") }
        let to = try format(object["to"], "to")
        guard !from.contains(to) else { throw KumquatError.invalidInput("“from” and “to” are the same format") }

        guard let command = object["command"] as? [String], let program = command.first, !program.isEmpty else {
            throw KumquatError.invalidInput("“command” must be a list of strings, program first, e.g. [\"/usr/local/bin/tool\", \"{input}\", \"{output}\"]")
        }
        guard !program.contains("{") else { throw KumquatError.invalidInput("the program can't be a placeholder") }
        guard command.dropFirst().contains(where: { $0.contains("{input}") }) else {
            throw KumquatError.invalidInput("“command” never uses {input}")
        }
        guard command.dropFirst().contains(where: { $0.contains("{output}") }) else {
            throw KumquatError.invalidInput("“command” never uses {output}, so the result can't be found")
        }
        var timeout = UserRecipe.defaultTimeout
        if let value = object["timeout"] {
            guard let seconds = value as? Double, seconds > 0 else {
                throw KumquatError.invalidInput("“timeout” must be a number of seconds")
            }
            timeout = min(seconds, UserRecipe.maximumTimeout)
        }
        let name = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return UserRecipe(name: name?.isEmpty == false ? name! : file.deletingPathExtension().lastPathComponent,
                          from: from, to: to, command: command, timeout: timeout, file: file)
    }

    /// Graph edges for `recipes`. Cost 0, so a recipe wins over a built-in conversion for the same formats.
    static func edges(for recipes: [UserRecipe]) -> [ConversionEdge] {
        recipes.flatMap { recipe in
            recipe.from.map { ConversionEdge(from: $0, to: recipe.to, engine: .recipe, requires: nil, cost: 0) }
        }
    }
}

/// Runs user recipes.
struct RecipeEngine: ConversionEngine {
    let id = EngineID.recipe
    let recipes: [String: UserRecipe]

    init(_ recipes: [UserRecipe]) {
        var table: [String: UserRecipe] = [:]
        for recipe in recipes {
            for source in recipe.from where table["\(source.id)>\(recipe.to.id)"] == nil {
                table["\(source.id)>\(recipe.to.id)"] = recipe
            }
        }
        self.recipes = table
    }

    func convert(_ input: URL, from source: Format, to target: Format, output: URL, context: EngineContext) async throws -> URL {
        guard let recipe = recipes["\(source.id)>\(target.id)"] else { throw KumquatError.noRoute(from: source.name, to: target.name) }
        let program = recipe.command[0]
        let executable: URL
        if program.hasPrefix("/") || program.hasPrefix("~") {
            executable = URL(fileURLWithPath: NSString(string: program).expandingTildeInPath)
        } else if let found = context.tools.path(for: program) {
            executable = found
        } else {
            throw KumquatError.conversionFailed("Recipe “\(recipe.name)”: \(program) wasn't found. Use its full path in \(recipe.file.lastPathComponent).")
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw KumquatError.conversionFailed("Recipe “\(recipe.name)”: \(executable.path) isn't an executable program.")
        }
        let result = try await ProcessRunner.run(executable, recipe.arguments(input: input, output: output),
                                                 currentDirectory: context.workDirectory, timeout: recipe.timeout)
        try Task.checkCancellation()
        if result.timedOut {
            throw KumquatError.conversionFailed("Recipe “\(recipe.name)” didn't finish within \(Int(recipe.timeout)) seconds and was stopped.")
        }
        guard result.status == 0 else {
            let detail = (result.stderr.isEmpty ? result.stdout : result.stderr)
                .split(separator: "\n").suffix(4).joined(separator: "\n")
            throw KumquatError.conversionFailed("Recipe “\(recipe.name)” failed (exit \(result.status))" + (detail.isEmpty ? "." : ": \(detail)"))
        }
        guard FileManager.default.fileExists(atPath: output.path), SizeReport.size(of: output) > 0 || FileManager.default.isDirectory(output) else {
            throw KumquatError.conversionFailed("Recipe “\(recipe.name)” finished but didn't write {output}.")
        }
        return output
    }
}
