import BlockerKit
import Darwin
import Foundation
import WebKit

@main
struct FilterAssetsReproducer {
    static func main() async {
        do {
            try await run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            writeError(error.localizedDescription)
            exit(1)
        }
    }

    private static func run(arguments: [String]) async throws {
        guard let command = arguments.first else {
            printHelp()
            return
        }

        let options = try Options(arguments.dropFirst())

        switch command {
        case "convert-adblock":
            try await convertAdBlock(options: options)
        case "compile-content-rules":
            try await compileContentRules(options: options)
        case "generate-public-metadata":
            try PublicMetadataGenerator.run(options: options)
        case "source-plan":
            try SourceManifestPlan.printPlan(options: options)
        case "--help", "-h", "help":
            printHelp()
        default:
            throw ToolError("Unknown command: \(command)")
        }
    }

    @MainActor
    private static func convertAdBlock(options: Options) async throws {
        let inputDirectoryURL = try options.directoryURL(for: "--input-dir")
        let outputDirectoryURL = try options.directoryURL(for: "--output-dir")
        let outputPrefix = try options.value(for: "--output-prefix")
        let reportDirectoryURL = options.optionalDirectoryURL(for: "--report-dir")
        let maxRulesPerChunk = try options.optionalInt(for: "--max-rules-per-chunk") ?? 3000
        let prettyPrintedJSON = options.contains("--pretty")

        guard maxRulesPerChunk > 0 else {
            throw ToolError("--max-rules-per-chunk must be greater than zero.")
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: outputDirectoryURL, withIntermediateDirectories: true)
        if let reportDirectoryURL {
            try fileManager.createDirectory(at: reportDirectoryURL, withIntermediateDirectories: true)
        }

        let filterFileURLs = try fileManager.contentsOfDirectory(
            at: inputDirectoryURL,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "txt" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let compiler = BlockerKitCompiler(
            options: BlockerKitCompiler.Options(
                includeNativeCosmeticRules: true,
                includeUserScriptRuntime: false,
                includeURLSchemeHandlerRules: false,
                prettyPrintedJSON: prettyPrintedJSON,
                contentRuleListMaxRuleCountPerChunk: maxRulesPerChunk
            )
        )

        for filterFileURL in filterFileURLs {
            let filterText = try String(contentsOf: filterFileURL, encoding: .utf8)
            let bundle = try await compiler.compile(filterText, progress: nil)
            let validation = try await validatedContentRuleListJSONChunks(
                bundle.contentRuleListJSONChunks,
                sourceFileURL: filterFileURL,
                outputPrefix: outputPrefix
            )
            let outputFileNames = try writeContentRuleListJSONChunks(
                validation.chunks,
                sourceFileURL: filterFileURL,
                outputDirectoryURL: outputDirectoryURL,
                outputPrefix: outputPrefix
            )

            if let reportDirectoryURL {
                try writeReport(
                    bundle.compilationReport,
                    sourceFileURL: filterFileURL,
                    outputFileNames: outputFileNames,
                    webKitValidationSkippedRuleCount: validation.skippedRuleCount,
                    webKitValidationSkippedRules: validation.skippedRules,
                    outputDirectoryURL: reportDirectoryURL,
                    outputPrefix: outputPrefix
                )
            }

            print(
                "Converted \(filterFileURL.lastPathComponent): "
                    + "\(bundle.statistics.generatedContentRuleCount) native rule(s), "
                    + "\(validation.chunks.count) WebKit-ready chunk(s), "
                    + "\(bundle.statistics.unsupportedRuleCount) unsupported rule(s), "
                    + "\(validation.skippedRuleCount) WebKit-invalid rule(s) skipped"
            )
        }
    }

    @MainActor
    private static func compileContentRules(options: Options) async throws {
        let inputDirectoryURL = try options.directoryURL(for: "--input-dir")
        let outputDirectoryURL = try options.directoryURL(for: "--output-dir")

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: outputDirectoryURL, withIntermediateDirectories: true)

        guard let store = WKContentRuleListStore(url: outputDirectoryURL) else {
            throw ToolError("Failed to create WKContentRuleListStore at \(outputDirectoryURL.path).")
        }

        let jsonFileURLs = try fileManager.contentsOfDirectory(
            at: inputDirectoryURL,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for jsonFileURL in jsonFileURLs {
            let source = try String(contentsOf: jsonFileURL, encoding: .utf8)
            guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            let identifier = jsonFileURL.lastPathComponent
            let outputFileURL = outputDirectoryURL.appendingPathComponent("ContentRuleList-\(identifier)")
            if fileManager.fileExists(atPath: outputFileURL.path) {
                try fileManager.removeItem(at: outputFileURL)
            }

            let bundle = try contentRuleListBundle(from: source)
            guard try await store.compileBlockerKitContentRuleList(
                identifier: identifier,
                from: bundle
            ) != nil else {
                throw ToolError("WKContentRuleListStore returned no rule list for \(identifier).")
            }

            guard fileManager.fileExists(atPath: outputFileURL.path) else {
                throw ToolError("Compiled output was not created: \(outputFileURL.path)")
            }

            print("Compiled \(identifier)")
        }
    }

    private static func writeContentRuleListJSONChunks(
        _ chunks: [String],
        sourceFileURL: URL,
        outputDirectoryURL: URL,
        outputPrefix: String
    ) throws -> [String] {
        let sourceName = sourceFileURL.deletingPathExtension().lastPathComponent

        return try chunks.enumerated().map { index, chunk in
            let outputFileName = contentRuleListJSONFileName(
                outputPrefix: outputPrefix,
                sourceName: sourceName,
                chunkIndex: index,
                chunkCount: chunks.count
            )
            let outputFileURL = outputDirectoryURL.appendingPathComponent(outputFileName)
            try chunk.write(to: outputFileURL, atomically: true, encoding: .utf8)
            return outputFileName
        }
    }

    @MainActor
    private static func validatedContentRuleListJSONChunks(
        _ chunks: [String],
        sourceFileURL: URL,
        outputPrefix: String
    ) async throws -> ChunkValidationResult {
        guard !chunks.isEmpty else {
            return ChunkValidationResult(chunks: [], skippedRuleCount: 0)
        }

        let fileManager = FileManager.default
        let validationStoreURL = fileManager.temporaryDirectory.appendingPathComponent(
            "FilterAssetsReproducerValidation-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: validationStoreURL, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: validationStoreURL)
        }

        guard let store = WKContentRuleListStore(url: validationStoreURL) else {
            throw ToolError("Failed to create validation WKContentRuleListStore at \(validationStoreURL.path).")
        }

        let sourceName = sourceFileURL.deletingPathExtension().lastPathComponent
        let identifierBase = "\(outputPrefix)_\(sourceName)"
        var result = ChunkValidationResult(chunks: [], skippedRuleCount: 0)

        for (index, chunk) in chunks.enumerated() {
            let partial = try await validContentRuleListJSONChunks(
                from: chunk,
                identifier: "\(identifierBase)-validation-\(index)",
                store: store
            )
            result.chunks.append(contentsOf: partial.chunks)
            result.skippedRuleCount += partial.skippedRuleCount
            result.skippedRules.append(contentsOf: partial.skippedRules)
        }

        return result
    }

    @MainActor
    private static func validContentRuleListJSONChunks(
        from source: String,
        identifier: String,
        store: WKContentRuleListStore
    ) async throws -> ChunkValidationResult {
        let rules = try contentRules(in: source)
        guard !rules.isEmpty else {
            return ChunkValidationResult(chunks: [], skippedRuleCount: 0)
        }

        do {
            let bundle = try contentRuleListBundle(from: source)
            _ = try await store.compileBlockerKitContentRuleList(identifier: identifier, from: bundle)
            return ChunkValidationResult(chunks: [source], skippedRuleCount: 0)
        } catch {
            guard rules.count > 1 else {
                writeError("Skipped WebKit-invalid rule in \(identifier): \(error.localizedDescription)")
                let ruleJSON = try contentRuleListJSON(from: rules)
                return ChunkValidationResult(
                    chunks: [],
                    skippedRuleCount: 1,
                    skippedRules: [
                        WebKitValidationSkippedRule(
                            validationIdentifier: identifier,
                            errorDescription: error.localizedDescription,
                            contentRuleJSON: ruleJSON
                        )
                    ]
                )
            }

            let middleIndex = rules.count / 2
            let leftJSON = try contentRuleListJSON(from: Array(rules[..<middleIndex]))
            let rightJSON = try contentRuleListJSON(from: Array(rules[middleIndex...]))
            let left = try await validContentRuleListJSONChunks(
                from: leftJSON,
                identifier: "\(identifier)-0",
                store: store
            )
            let right = try await validContentRuleListJSONChunks(
                from: rightJSON,
                identifier: "\(identifier)-1",
                store: store
            )
            return ChunkValidationResult(
                chunks: left.chunks + right.chunks,
                skippedRuleCount: left.skippedRuleCount + right.skippedRuleCount,
                skippedRules: left.skippedRules + right.skippedRules
            )
        }
    }

    private static func contentRuleListJSONFileName(
        outputPrefix: String,
        sourceName: String,
        chunkIndex: Int,
        chunkCount: Int
    ) -> String {
        if chunkCount == 1 {
            return "\(outputPrefix)_\(sourceName).json"
        }

        let chunkNumber = String(format: "%03d", chunkIndex + 1)
        return "\(outputPrefix)_\(sourceName)_chunk_\(chunkNumber).json"
    }

    private static func writeReport(
        _ report: FilterCompilationReport,
        sourceFileURL: URL,
        outputFileNames: [String],
        webKitValidationSkippedRuleCount: Int,
        webKitValidationSkippedRules: [WebKitValidationSkippedRule],
        outputDirectoryURL: URL,
        outputPrefix: String
    ) throws {
        let sourceName = sourceFileURL.deletingPathExtension().lastPathComponent
        let reportFileURL = outputDirectoryURL.appendingPathComponent("\(outputPrefix)_\(sourceName).json")
        let reportEnvelope = ReportEnvelope(
            sourceFileName: sourceFileURL.lastPathComponent,
            outputFileNames: outputFileNames,
            webKitValidationSkippedRuleCount: webKitValidationSkippedRuleCount,
            webKitValidationSkippedRules: webKitValidationSkippedRules,
            report: report
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(reportEnvelope)
        try data.write(to: reportFileURL, options: .atomic)
    }

    private static func contentRuleListBundle(from source: String) throws -> WKWebViewFilterBundle {
        let ruleCount = try contentRuleCount(in: source)
        return WKWebViewFilterBundle(
            contentRuleListJSON: source,
            contentRuleListJSONChunks: [source],
            userScripts: [],
            runtimeConfig: RuntimeConfig(),
            diagnostics: [],
            statistics: FilterCompilationStatistics(
                totalLines: 0,
                skippedLines: 0,
                parsedRules: ruleCount,
                nativeRuleCount: ruleCount,
                userScriptRuleCount: 0,
                approximateRuleCount: 0,
                unsupportedRuleCount: 0,
                generatedContentRuleCount: ruleCount,
                generatedContentRuleListChunkCount: 1,
                generatedUserScriptCount: 0
            )
        )
    }

    private static func contentRuleCount(in source: String) throws -> Int {
        try contentRules(in: source).count
    }

    private static func contentRules(in source: String) throws -> [Any] {
        let data = Data(source.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let rules = object as? [Any] else {
            throw ToolError("Content Rule List JSON must be an array.")
        }
        return rules
    }

    private static func contentRuleListJSON(from rules: [Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: rules)
        return String(decoding: data, as: UTF8.self)
    }

    private static func printHelp() {
        print(
            """
            Usage:
              filter-assets-reproducer source-plan --source-manifest FILE
              filter-assets-reproducer convert-adblock --input-dir DIR --output-dir DIR --output-prefix PREFIX [--report-dir DIR] [--max-rules-per-chunk COUNT] [--pretty]
              filter-assets-reproducer compile-content-rules --input-dir DIR --output-dir DIR
              filter-assets-reproducer generate-public-metadata --source-manifest FILE --resources-dir DIR --report-dir DIR --output-dir DIR --package-name NAME [--package-resolved FILE]
            """
        )
    }

    private static func writeError(_ message: String) {
        let data = Data(("Error: \(message)\n").utf8)
        FileHandle.standardError.write(data)
    }
}

struct Options {
    private var values: [String: String] = [:]
    private var flags: Set<String> = []

    init(_ arguments: ArraySlice<String>) throws {
        var iterator = Array(arguments).makeIterator()
        while let argument = iterator.next() {
            guard argument.hasPrefix("--") else {
                throw ToolError("Unexpected argument: \(argument)")
            }

            if argument == "--pretty" {
                flags.insert(argument)
                continue
            }

            guard let value = iterator.next() else {
                throw ToolError("Missing value for \(argument).")
            }
            values[argument] = value
        }
    }

    func contains(_ flag: String) -> Bool {
        flags.contains(flag)
    }

    func value(for key: String) throws -> String {
        guard let value = values[key], !value.isEmpty else {
            throw ToolError("Missing required option: \(key)")
        }
        return value
    }

    func optionalValue(for key: String) -> String? {
        values[key]
    }

    func directoryURL(for key: String) throws -> URL {
        URL(fileURLWithPath: try value(for: key), isDirectory: true)
    }

    func optionalDirectoryURL(for key: String) -> URL? {
        values[key].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    func optionalFileURL(for key: String) throws -> URL? {
        guard let value = values[key], !value.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: value)
    }

    func optionalInt(for key: String) throws -> Int? {
        guard let value = values[key] else {
            return nil
        }
        guard let intValue = Int(value) else {
            throw ToolError("\(key) must be an integer: \(value)")
        }
        return intValue
    }
}

private struct ReportEnvelope: Encodable {
    var sourceFileName: String
    var outputFileNames: [String]
    var webKitValidationSkippedRuleCount: Int
    var webKitValidationSkippedRules: [WebKitValidationSkippedRule]
    var report: FilterCompilationReport
}

private struct ChunkValidationResult {
    var chunks: [String]
    var skippedRuleCount: Int
    var skippedRules: [WebKitValidationSkippedRule] = []
}

private struct WebKitValidationSkippedRule: Encodable {
    var validationIdentifier: String
    var errorDescription: String
    var contentRuleJSON: String
}

struct ToolError: LocalizedError {
    private let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
