import Foundation

/// Everything an engine needs for one job.
public struct EngineContext: Sendable {
    public var options: ConversionOptions
    public var tools: ToolLocator
    /// Scratch space, deleted when the job ends.
    public var workDirectory: URL
    public var progress: (@Sendable (Double) -> Void)?
    /// Position of this file in the drop, and how many files were dropped (for numbering, e.g. Rename).
    public var itemIndex = 0
    public var itemCount = 1

    public init(options: ConversionOptions, tools: ToolLocator, workDirectory: URL, progress: (@Sendable (Double) -> Void)? = nil) {
        self.options = options
        self.tools = tools
        self.workDirectory = workDirectory
        self.progress = progress
    }

    /// Fresh path inside the work directory.
    func scratchURL(_ ext: String) -> URL {
        workDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
    }
}

/// Performs one hop of a conversion route.
public protocol ConversionEngine: Sendable {
    var id: EngineID { get }
    /// Converts `input` into `target`, writing to `output` (inside the work directory).
    /// Returns the produced URL, which may be a directory for multi-file results (e.g. PDF pages → PNGs).
    func convert(_ input: URL, from source: Format, to target: Format, output: URL, context: EngineContext) async throws -> URL
}

/// Result of running a tool.
public struct ToolOutcome: Sendable {
    public var outputs: [URL]
    /// Short message for the HUD ("1,204 words", "Saved 38%").
    public var message: String?
    /// Text the app should place on the clipboard.
    public var clipboardText: String?
    /// "file: reason" for inputs that failed while others succeeded.
    public var failures: [String]

    public init(outputs: [URL] = [], message: String? = nil, clipboardText: String? = nil, failures: [String] = []) {
        self.outputs = outputs
        self.message = message
        self.clipboardText = clipboardText
        self.failures = failures
    }
}

/// What a tool produced in the work directory, before it is moved next to the original.
struct ToolArtifact {
    var url: URL?
    var message: String?
    var clipboardText: String?
    /// Overrides the default "<name> (<suffix>)" naming.
    var preferredBaseName: String?
}

/// Front door to every conversion and tool.
public final class Converter: @unchecked Sendable {
    public let graph: ConversionGraph
    public let tools: ToolLocator
    let engines: [EngineID: any ConversionEngine]

    public init(graph: ConversionGraph = .standard, tools: ToolLocator = ToolLocator()) {
        self.graph = graph
        self.tools = tools
        self.engines = Self.makeEngines()
    }

    static func makeEngines() -> [EngineID: any ConversionEngine] {
        var engines: [EngineID: any ConversionEngine] = [
            .media: MediaEngine(),
            .archive: ArchiveEngine(),
            .data: DataEngine(),
            .subtitle: SubtitleEngine(),
            .office: OfficeEngine(),
            .pandoc: PandocEngine(),
        ]
        engines[.iwork] = IWorkEngine()
        engines[.image] = ImageEngine()
        engines[.pdf] = PDFEngine()
        engines[.document] = DocumentEngine()
        return engines
    }

    public var availableEngines: Set<EngineID> { Set(engines.keys) }

    public func catalog() -> Catalog {
        Catalog(graph: graph, engines: availableEngines, available: tools.availableDependencies)
    }

    // MARK: Conversion

    /// Converts `input` to `target`, saving next to the original (or wherever `options.outputLocation` says).
    /// - Returns: the final file (or folder, for multi-page results).
    @discardableResult
    public func convert(_ input: URL, to target: Format, options: ConversionOptions = ConversionOptions(),
                        progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        guard let source = FormatRegistry.format(for: input) else {
            throw KumquatError.unsupportedInput(input.lastPathComponent)
        }
        let available = tools.availableDependencies
        guard let route = graph.bestRoute(from: source, to: target, engines: availableEngines, available: available) else {
            throw KumquatError.noRoute(from: source.name, to: target.name)
        }
        let missing = route.requirements.subtracting(available)
        guard missing.isEmpty else {
            throw KumquatError.missingDependencies(missing.sorted { $0.rawValue < $1.rawValue })
        }

        let fm = FileManager.default
        let work = try fm.makeWorkDirectory()
        defer { try? fm.removeItem(at: work) }

        var current = input
        let steps = route.edges.count
        for (index, edge) in route.edges.enumerated() {
            try Task.checkCancellation()
            guard let engine = engines[edge.engine] else { throw KumquatError.engineUnavailable(edge.engine.rawValue) }
            let stepWork = work.appendingPathComponent("step\(index)", isDirectory: true)
            try fm.createDirectory(at: stepWork, withIntermediateDirectories: true)
            let context = EngineContext(options: options, tools: tools, workDirectory: stepWork) { fraction in
                progress?((Double(index) + min(max(fraction, 0), 1)) / Double(steps))
            }
            let output = stepWork.appendingPathComponent("\(FormatRegistry.baseName(of: input)).\(edge.to.fileExtension)")
            current = try await engine.convert(current, from: edge.from, to: edge.to, output: output, context: context)
        }
        progress?(1)

        let directory = OutputNamer.destinationDirectory(for: input, options: options, outputKind: target.kind)
        let base = FormatRegistry.baseName(of: input)
        let name = FileNameTemplate.render(options.fileNameTemplate, name: base, format: target.shortName)
        let placed = fm.isDirectory(current)
            ? try Self.moveIntoPlace(current, directory: directory, baseName: name == base ? "\(base) (\(target.shortName))" : name,
                                     extension: nil, conflict: options.conflictPolicy)
            : try Self.moveIntoPlace(current, directory: directory, baseName: name, extension: target.fileExtension,
                                     conflict: options.conflictPolicy)
        Self.finishOriginal(input, result: placed, options: options)
        return placed
    }

    /// Applies the "file dates" and "originals" settings once `result` is saved.
    static func finishOriginal(_ original: URL, result: URL, options: ConversionOptions) {
        let fm = FileManager.default
        if options.preserveFileDates, let attributes = try? fm.attributesOfItem(atPath: original.path) {
            var dates: [FileAttributeKey: Any] = [:]
            dates[.creationDate] = attributes[.creationDate]
            dates[.modificationDate] = attributes[.modificationDate]
            try? fm.setAttributes(dates, ofItemAtPath: result.path)
        }
        if options.originals == .trash,
           original.standardizedFileURL.path != result.standardizedFileURL.path,
           fm.fileExists(atPath: original.path) {
            try? UndoJournal.trash(original, fileManager: fm)
        }
    }

    /// Moves a finished result into place. With `.keepBoth`, names are reserved in-process first, because
    /// parallel jobs could otherwise pick the same name (photo.png and photo.jpg → photo.webp) and `rename`
    /// would silently overwrite the first result; a collision with another app retries with the next number.
    /// `.replace` moves an existing file to the Trash first; `.skip` throws instead of saving.
    static func moveIntoPlace(_ item: URL, directory: URL, baseName: String, extension ext: String?,
                              conflict: ConflictPolicy = .keepBoth) throws -> URL {
        let fm = FileManager.default
        if conflict != .keepBoth {
            let destination = OutputNamer.url(in: directory, baseName: baseName, extension: ext)
            // Another job in this batch is saving the same name: never replace a result we just made.
            if OutputNamer.reserve(destination) {
                defer { OutputNamer.release(destination) }
                // `fileExists` follows links, so check for a (possibly broken) symlink too.
                if fm.fileExists(atPath: destination.path) || (try? fm.destinationOfSymbolicLink(atPath: destination.path)) != nil {
                    if conflict == .skip {
                        throw KumquatError.nothingToDo("\(destination.lastPathComponent) already exists, so it was skipped.")
                    }
                    try UndoJournal.trash(destination, fileManager: fm)
                }
                try fm.moveItem(at: item, to: destination)
                return destination
            } else if conflict == .skip {
                throw KumquatError.nothingToDo("\(destination.lastPathComponent) already exists, so it was skipped.")
            }
        }
        var lastError: Error?
        for _ in 0..<20 {
            let destination = OutputNamer.reserveUniqueURL(in: directory, baseName: baseName, extension: ext)
            defer { OutputNamer.release(destination) }
            do {
                try fm.moveItem(at: item, to: destination)
                return destination
            } catch {
                lastError = error
                guard fm.fileExists(atPath: destination.path) else { throw error }
            }
        }
        throw lastError ?? KumquatError.conversionFailed("Couldn't save \(baseName).")
    }

    // MARK: Tools

    /// Runs a tool on the dropped files. Combining tools (merge, zip…) produce one result; others one per
    /// file, `concurrency` files at a time, with results reported in the order the files were given.
    public func run(_ tool: ToolID, inputs: [URL], parameter: String? = nil,
                    options: ConversionOptions = ConversionOptions(),
                    concurrency: Int = 1,
                    progress: (@Sendable (Double) -> Void)? = nil) async throws -> ToolOutcome {
        guard !inputs.isEmpty else { throw KumquatError.nothingToDo("Nothing to process.") }
        let missing = tool.requirements.subtracting(tools.availableDependencies)
        guard missing.isEmpty else { throw KumquatError.missingDependencies(missing.sorted { $0.rawValue < $1.rawValue }) }

        let fm = FileManager.default
        let work = try fm.makeWorkDirectory()
        defer { try? fm.removeItem(at: work) }
        let context = EngineContext(options: options, tools: tools, workDirectory: work, progress: progress)

        if tool.combinesInputs {
            let artifact = try await ToolRunner.runCombined(tool, inputs: inputs, context: context)
            return try finalize([artifact], for: [inputs[0]], tool: tool, options: options, combined: true)
        }

        let tracker = BatchProgress(count: inputs.count, report: progress)
        let results = try await withThrowingTaskGroup(of: (Int, Result<ToolArtifact, Error>).self) { group in
            var collected: [(Int, Result<ToolArtifact, Error>)] = []
            var next = 0
            func enqueue() throws {
                guard next < inputs.count else { return }
                let index = next
                next += 1
                // Each file gets its own scratch folder: tools name results after the input, and two
                // inputs can share a name ("scan.pdf" from two folders).
                var itemContext = context
                itemContext.workDirectory = work.appendingPathComponent("item\(index)", isDirectory: true)
                try fm.createDirectory(at: itemContext.workDirectory, withIntermediateDirectories: true)
                itemContext.progress = { tracker.update(index, $0) }
                itemContext.itemIndex = index
                itemContext.itemCount = inputs.count
                group.addTask {
                    do {
                        return (index, .success(try await ToolRunner.run(tool, input: inputs[index], parameter: parameter,
                                                                         context: itemContext)))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // Keep going: one bad file shouldn't throw away the others' results.
                        return (index, .failure(error))
                    }
                }
            }
            for _ in 0..<min(max(concurrency, 1), inputs.count) { try enqueue() }
            while let result = try await group.next() {
                collected.append(result)
                tracker.update(result.0, 1)
                try Task.checkCancellation()
                try enqueue()
            }
            return collected.sorted { $0.0 < $1.0 }
        }

        var artifacts: [ToolArtifact] = []
        var originals: [URL] = []
        var failures: [String] = []
        var firstError: Error?
        for (index, result) in results {
            switch result {
            case .success(let artifact):
                artifacts.append(artifact)
                originals.append(inputs[index])
            case .failure(let error):
                failures.append("\(inputs[index].lastPathComponent): \(error.localizedDescription)")
                firstError = firstError ?? error
            }
        }
        if artifacts.isEmpty, let firstError { throw firstError }
        progress?(1)
        var outcome = try finalize(artifacts, for: originals, tool: tool, options: options, combined: false)
        outcome.failures = failures + outcome.failures
        return outcome
    }

    /// Saves tool results. A file that can't be saved (e.g. skipped because the name exists) is reported
    /// in `failures` without losing the others; if nothing at all came out, the first error is thrown.
    private func finalize(_ artifacts: [ToolArtifact], for originals: [URL], tool: ToolID, options: ConversionOptions,
                          combined: Bool) throws -> ToolOutcome {
        let fm = FileManager.default
        var outcome = ToolOutcome()
        var messages: [String] = []
        var clipboard: [String] = []
        var firstError: Error?
        for (artifact, original) in zip(artifacts, originals) {
            if let message = artifact.message { messages.append(message) }
            if let text = artifact.clipboardText { clipboard.append(text) }
            guard let url = artifact.url else { continue }
            let kind: FileKind? = fm.isDirectory(url) ? nil : FormatRegistry.format(for: url)?.kind
            let directory = OutputNamer.destinationDirectory(for: original, options: options, outputKind: kind)
            let base: String
            if let preferred = artifact.preferredBaseName {
                base = preferred
            } else if let suffix = tool.outputSuffix {
                base = "\(FormatRegistry.baseName(of: original)) (\(suffix))"
            } else {
                base = FormatRegistry.baseName(of: original)
            }
            let ext: String? = fm.isDirectory(url) ? nil : FormatRegistry.format(for: url)?.fileExtension ?? url.pathExtension
            do {
                let placed = try Self.moveIntoPlace(url, directory: directory, baseName: base, extension: ext,
                                                    conflict: options.conflictPolicy)
                outcome.outputs.append(placed)
                // Combined results (merge, zip…) come from several files: leave those originals alone.
                if !combined { Self.finishOriginal(original, result: placed, options: options) }
            } catch {
                outcome.failures.append("\(original.lastPathComponent): \(error.localizedDescription)")
                firstError = firstError ?? error
            }
        }
        outcome.message = messages.isEmpty ? nil : (messages.count == 1 ? messages[0] : messages.joined(separator: " · "))
        outcome.clipboardText = clipboard.isEmpty ? nil : clipboard.joined(separator: "\n")
        if outcome.outputs.isEmpty, outcome.message == nil, outcome.clipboardText == nil, let firstError { throw firstError }
        return outcome
    }
}

/// Overall progress of files processed in parallel, each reporting its own 0…1 fraction.
private final class BatchProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var fractions: [Double]
    private let report: (@Sendable (Double) -> Void)?

    init(count: Int, report: (@Sendable (Double) -> Void)?) {
        fractions = Array(repeating: 0, count: count)
        self.report = report
    }

    func update(_ index: Int, _ fraction: Double) {
        guard let report else { return }
        lock.lock()
        fractions[index] = max(fractions[index], min(max(fraction, 0), 1))
        let overall = fractions.reduce(0, +) / Double(fractions.count)
        lock.unlock()
        report(overall)
    }
}

/// Routes each tool to the engine that implements it.
enum ToolRunner {
    static func run(_ tool: ToolID, input: URL, parameter: String?, context: EngineContext) async throws -> ToolArtifact {
        try rejectInteractive(tool)
        let kind = FormatRegistry.kind(for: input)
        let format = FormatRegistry.format(for: input)

        switch tool {
        case .extractArchive:
            guard let format else { throw KumquatError.unsupportedInput(input.lastPathComponent) }
            let extracted = try await ArchiveEngine.extractForUser(input, format: format, context: context)
            // A lone file keeps its own name; its extension is re-added when it's moved into place.
            let name = FileManager.default.isDirectory(extracted)
                ? extracted.lastPathComponent
                : FormatRegistry.baseName(of: extracted)
            return ToolArtifact(url: extracted, preferredBaseName: name)
        case .checksum:
            let digest = try await Checksum.sha256(of: input)
            return ToolArtifact(message: "SHA-256 copied", clipboardText: "\(digest)  \(input.lastPathComponent)")
        case .wordCount:
            let text = try await TextExtraction.text(of: input, format: format)
            let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
            let message = "\(words) words · \(text.count) characters"
            return ToolArtifact(message: message, clipboardText: nil)
        default:
            break
        }

        guard let format else { throw KumquatError.unsupportedInput(input.lastPathComponent) }
        switch kind {
        case .audio, .video:
            return try await MediaEngine.runTool(tool, input: input, source: format, parameter: parameter, context: context)
        case .image:
            return try await ImageEngine.runTool(tool, input: input, source: format, parameter: parameter, context: context)
        case .pdf:
            return try await PDFEngine.runTool(tool, input: input, parameter: parameter, context: context)
        default:
            throw KumquatError.nothingToDo("\(tool.title) doesn't apply to \(input.lastPathComponent).")
        }
    }

    static func runCombined(_ tool: ToolID, inputs: [URL], context: EngineContext) async throws -> ToolArtifact {
        switch tool {
        case .compressZip:
            let output = context.scratchURL("zip")
            try await ArchiveEngine.create(items: inputs, format: .zip, output: output)
            let name = inputs.count == 1 ? FormatRegistry.baseName(of: inputs[0]) : "Archive"
            return ToolArtifact(url: output, preferredBaseName: name)
        case .imagesToGIF:
            let output = context.scratchURL("gif")
            try await ImageEngine.makeAnimatedGIF(from: inputs, output: output, context: context)
            return ToolArtifact(url: output, preferredBaseName: FormatRegistry.baseName(of: inputs[0]))
        case .imagesToPDF, .pdfMerge:
            let output = context.scratchURL("pdf")
            if tool == .pdfMerge {
                try PDFEngine.merge(inputs, output: output)
            } else {
                try await PDFEngine.makePDF(fromImages: inputs, output: output, context: context)
            }
            let base = FormatRegistry.baseName(of: inputs[0])
            return ToolArtifact(url: output, preferredBaseName: tool == .pdfMerge ? "\(base) (merged)" : base)
        default:
            throw KumquatError.nothingToDo("\(tool.title) works on one file at a time.")
        }
    }

    /// Interactive tools are handled by the app, never by the background runner.
    static func rejectInteractive(_ tool: ToolID) throws {
        if tool.isInteractive {
            throw KumquatError.nothingToDo("\(tool.title) opens an editor in the Kumquat app.")
        }
    }
}

/// Plain text from documents, for word counts.
enum TextExtraction {
    static func text(of url: URL, format: Format?) async throws -> String {
        switch format {
        case .some(.txt), .some(.md), .some(.html), .some(.csv), .some(.srt), .some(.vtt):
            let text = try String.readText(from: url)
            return format == .html ? text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression) : text
        default:
            if format == .pdf { return PDFEngine.plainText(of: url) }
            if let format, DocumentEngine.readable.contains(format) {
                return try await DocumentEngine.read(url, format: format).string
            }
            throw KumquatError.nothingToDo("Can't count words in \(url.lastPathComponent).")
        }
    }
}
