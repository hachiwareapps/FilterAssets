import BlockerKit
import CryptoKit
import Foundation

struct RuntimeArtifactGenerator {
    static let manifestFileName = "BlockerKitUserScriptManifest.json"
    static let manifestSchemaVersion = 1

    static func run(options: Options) throws {
        let inputPrefixes: [String]
        if let value = options.optionalValue(for: "--input-prefixes") {
            inputPrefixes = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        } else {
            inputPrefixes = [try options.value(for: "--input-prefix")]
        }
        let result = try generate(
            profileID: try options.value(for: "--profile-id"),
            inputPrefixes: inputPrefixes,
            inputDirectoryURL: try options.directoryURL(for: "--input-dir"),
            outputDirectoryURL: try options.directoryURL(for: "--output-dir"),
            reportDirectoryURL: try options.directoryURL(for: "--report-dir")
        )
        print(
            "Generated \(result.artifactFileName) from \(result.inputConfigFileNames.count) "
                + "runtime config(s) (\(result.ruleCounts.total) rule(s), \(result.byteCount) bytes)"
        )
    }

    static func writeRuntimeConfig(
        _ config: RuntimeConfig,
        sourceFileURL: URL,
        outputPrefix: String,
        outputDirectoryURL: URL
    ) throws {
        let sourceName = sourceFileURL.deletingPathExtension().lastPathComponent
        let fileName = "\(outputPrefix)_\(sourceName).runtime-config.json"
        let outputURL = outputDirectoryURL.appendingPathComponent(fileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: outputURL, options: .atomic)
    }

    @discardableResult
    static func generate(
        profileID: String,
        inputPrefix: String,
        inputDirectoryURL: URL,
        outputDirectoryURL: URL,
        reportDirectoryURL: URL
    ) throws -> RuntimeArtifactGenerationResult {
        try generate(
            profileID: profileID,
            inputPrefixes: [inputPrefix],
            inputDirectoryURL: inputDirectoryURL,
            outputDirectoryURL: outputDirectoryURL,
            reportDirectoryURL: reportDirectoryURL
        )
    }

    @discardableResult
    static func generate(
        profileID: String,
        inputPrefixes: [String],
        inputDirectoryURL: URL,
        outputDirectoryURL: URL,
        reportDirectoryURL: URL
    ) throws -> RuntimeArtifactGenerationResult {
        guard isValidProfileID(profileID) else {
            throw ToolError("Invalid profile ID: \(profileID)")
        }
        guard !inputPrefixes.isEmpty, inputPrefixes.allSatisfy({ !$0.isEmpty }) else {
            throw ToolError("Runtime config input prefixes must not be empty.")
        }
        guard Set(inputPrefixes).count == inputPrefixes.count else {
            throw ToolError("Runtime config input prefixes must not contain duplicates.")
        }

        let fileManager = FileManager.default
        let inputConfigURLs = try fileManager.contentsOfDirectory(
            at: inputDirectoryURL,
            includingPropertiesForKeys: nil
        )
        .filter {
            inputPrefixes.contains(where: $0.lastPathComponent.hasPrefix)
                && $0.lastPathComponent.hasSuffix(".runtime-config.json")
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !inputConfigURLs.isEmpty else {
            throw ToolError(
                "No runtime configs matched prefixes \(inputPrefixes.joined(separator: ", ")) "
                    + "in \(inputDirectoryURL.path)."
            )
        }

        let mergedConfig = try mergedRuntimeConfig(from: inputConfigURLs)
        guard mergedConfig.hasRules else {
            throw ToolError(
                "Runtime profile \(profileID) contains no user script rules; refusing to publish an empty artifact."
            )
        }

        let descriptor = WKUserScriptDescriptor.blockerKitRuntime(config: mergedConfig)
        guard descriptor.injectionTime == .atDocumentStart,
              descriptor.forMainFrameOnly == false,
              descriptor.contentWorld == .page else {
            throw ToolError(
                "BlockerKit runtime descriptor does not match the public profile contract "
                    + "(documentStart, all frames, page world)."
            )
        }

        try fileManager.createDirectory(at: outputDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: reportDirectoryURL, withIntermediateDirectories: true)

        let artifactFileName = "BlockerKitUserScript-\(profileID).js"
        let artifactURL = outputDirectoryURL.appendingPathComponent(artifactFileName)
        let artifactData = Data(descriptor.source.utf8)
        try artifactData.write(to: artifactURL, options: .atomic)

        let sha256 = sha256Hex(artifactData)
        let ruleCounts = RuntimeRuleCounts(config: mergedConfig)
        let inputConfigFileNames = inputConfigURLs.map(\.lastPathComponent)
        let reportRelativePath = "reports/runtime/\(profileID).json"
        let report = RuntimeArtifactReport(
            schemaVersion: manifestSchemaVersion,
            profileID: profileID,
            inputConfigFiles: inputConfigFileNames,
            ruleCounts: ruleCounts,
            artifact: .init(
                fileName: artifactFileName,
                byteCount: artifactData.count,
                sha256: sha256,
                injectionTime: "documentStart",
                forMainFrameOnly: false,
                contentWorld: "page"
            )
        )
        try writeJSON(report, to: reportDirectoryURL.appendingPathComponent("\(profileID).json"))

        let manifest = RuntimeArtifactManifest(
            schemaVersion: manifestSchemaVersion,
            profiles: [
                .init(
                    id: profileID,
                    fileName: artifactFileName,
                    injectionTime: "documentStart",
                    forMainFrameOnly: false,
                    contentWorld: "page",
                    sha256: sha256,
                    byteCount: artifactData.count,
                    report: reportRelativePath
                )
            ]
        )
        try writeJSON(manifest, to: outputDirectoryURL.appendingPathComponent(manifestFileName))

        return RuntimeArtifactGenerationResult(
            artifactFileName: artifactFileName,
            inputConfigFileNames: inputConfigFileNames,
            ruleCounts: ruleCounts,
            byteCount: artifactData.count,
            sha256: sha256
        )
    }

    static func mergedRuntimeConfig(from inputConfigURLs: [URL]) throws -> RuntimeConfig {
        let decoder = JSONDecoder()
        let configs = try inputConfigURLs
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try decoder.decode(RuntimeConfig.self, from: Data(contentsOf: $0)) }

        return RuntimeConfig(
            cosmeticRules: configs.flatMap(\.cosmeticRules),
            cssInjectionRules: configs.flatMap(\.cssInjectionRules),
            scriptletRules: configs.flatMap(\.scriptletRules),
            networkRules: configs.flatMap(\.networkRules)
        )
    }

    static func isValidProfileID(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        return !value.isEmpty
            && value.unicodeScalars.allSatisfy(allowed.contains)
            && !value.hasPrefix("-")
            && !value.hasSuffix("-")
    }

    private static func writeJSON<T: Encodable>(_ value: T, to outputURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: outputURL, options: .atomic)
    }
}

struct RuntimeArtifactValidator {
    static func run(options: Options) throws {
        try validate(
            resourcesDirectoryURL: try options.directoryURL(for: "--resources-dir"),
            checksumsFileURL: try options.optionalFileURL(for: "--checksums-file"),
            metadataDirectoryURL: options.optionalDirectoryURL(for: "--metadata-dir")
        )
        print("BlockerKit user script artifacts verified.")
    }

    static func validate(
        resourcesDirectoryURL: URL,
        checksumsFileURL: URL? = nil,
        metadataDirectoryURL: URL? = nil
    ) throws {
        let manifestURL = resourcesDirectoryURL.appendingPathComponent(
            RuntimeArtifactGenerator.manifestFileName
        )
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ToolError("User script artifact manifest is missing: \(manifestURL.path)")
        }

        let manifest: RuntimeArtifactManifest
        do {
            manifest = try JSONDecoder().decode(
                RuntimeArtifactManifest.self,
                from: Data(contentsOf: manifestURL)
            )
        } catch {
            throw ToolError("Invalid user script artifact manifest: \(error.localizedDescription)")
        }

        guard manifest.schemaVersion == RuntimeArtifactGenerator.manifestSchemaVersion else {
            throw ToolError(
                "Unsupported user script artifact manifest schema version: \(manifest.schemaVersion)"
            )
        }
        guard !manifest.profiles.isEmpty else {
            throw ToolError("User script artifact manifest contains no profiles.")
        }

        var profileIDs = Set<String>()
        var fileNames = Set<String>()
        for profile in manifest.profiles {
            guard RuntimeArtifactGenerator.isValidProfileID(profile.id) else {
                throw ToolError("Invalid user script profile ID: \(profile.id)")
            }
            guard profileIDs.insert(profile.id).inserted else {
                throw ToolError("Duplicate user script profile ID: \(profile.id)")
            }
            guard fileNames.insert(profile.fileName).inserted else {
                throw ToolError("Duplicate user script artifact file: \(profile.fileName)")
            }
            guard profile.injectionTime == "documentStart",
                  profile.forMainFrameOnly == false,
                  profile.contentWorld == "page" else {
                throw ToolError("Unsupported injection contract for user script profile \(profile.id).")
            }
            guard profile.fileName == "BlockerKitUserScript-\(profile.id).js" else {
                throw ToolError("User script filename does not match profile ID \(profile.id).")
            }
            guard profile.report == "reports/runtime/\(profile.id).json" else {
                throw ToolError("Runtime report path does not match profile ID \(profile.id).")
            }

            let artifactURL = resourcesDirectoryURL.appendingPathComponent(profile.fileName)
            guard FileManager.default.fileExists(atPath: artifactURL.path) else {
                throw ToolError("User script artifact is missing: \(artifactURL.path)")
            }
            let artifactData = try Data(contentsOf: artifactURL)
            guard artifactData.count == profile.byteCount else {
                throw ToolError("User script artifact byte count mismatch: \(profile.fileName)")
            }
            guard sha256Hex(artifactData) == profile.sha256 else {
                throw ToolError("User script artifact checksum mismatch: \(profile.fileName)")
            }
        }

        let discoveredArtifactFileNames = try Set(
            FileManager.default.contentsOfDirectory(
                at: resourcesDirectoryURL,
                includingPropertiesForKeys: nil
            )
            .filter {
                $0.lastPathComponent.hasPrefix("BlockerKitUserScript-")
                    && $0.pathExtension == "js"
            }
            .map(\.lastPathComponent)
        )
        guard discoveredArtifactFileNames == fileNames else {
            throw ToolError("User script artifact files do not match the manifest profiles.")
        }

        if let checksumsFileURL {
            let checksumRecords = try checksumRecords(at: checksumsFileURL)
            try validateChecksumRecord(
                for: manifestURL,
                named: RuntimeArtifactGenerator.manifestFileName,
                records: checksumRecords
            )
            for profile in manifest.profiles {
                try validateChecksumRecord(
                    for: resourcesDirectoryURL.appendingPathComponent(profile.fileName),
                    named: profile.fileName,
                    records: checksumRecords
                )
            }
        }

        if let metadataDirectoryURL {
            try validateRuntimeConfigCompleteness(
                manifest: manifest,
                metadataDirectoryURL: metadataDirectoryURL
            )
        }
    }

    private static func validateRuntimeConfigCompleteness(
        manifest: RuntimeArtifactManifest,
        metadataDirectoryURL: URL
    ) throws {
        var includedConfigFileNames = Set<String>()
        for profile in manifest.profiles {
            let reportURL = metadataDirectoryURL.appendingPathComponent(profile.report)
            guard FileManager.default.fileExists(atPath: reportURL.path) else {
                throw ToolError("Runtime profile report is missing: \(reportURL.path)")
            }
            let report = try JSONDecoder().decode(
                RuntimeArtifactReport.self,
                from: Data(contentsOf: reportURL)
            )
            guard report.schemaVersion == RuntimeArtifactGenerator.manifestSchemaVersion,
                  report.profileID == profile.id,
                  report.artifact.fileName == profile.fileName,
                  report.artifact.sha256 == profile.sha256,
                  report.artifact.byteCount == profile.byteCount,
                  report.artifact.injectionTime == profile.injectionTime,
                  report.artifact.forMainFrameOnly == profile.forMainFrameOnly,
                  report.artifact.contentWorld == profile.contentWorld else {
                throw ToolError("Runtime profile report does not match manifest: \(profile.id)")
            }
            includedConfigFileNames.formUnion(report.inputConfigFiles)
        }

        let detailedReportDirectoryURL = metadataDirectoryURL.appendingPathComponent(
            "reports/blockerkit",
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: detailedReportDirectoryURL.path) else {
            throw ToolError(
                "BlockerKit detailed reports are missing: \(detailedReportDirectoryURL.path)"
            )
        }
        let detailedReportURLs = try FileManager.default.contentsOfDirectory(
            at: detailedReportDirectoryURL,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !detailedReportURLs.isEmpty else {
            throw ToolError(
                "BlockerKit detailed reports are empty: \(detailedReportDirectoryURL.path)"
            )
        }

        var missingConfigFileNames: [String] = []
        for reportURL in detailedReportURLs {
            let reportObject = try JSONSerialization.jsonObject(with: Data(contentsOf: reportURL))
            let userScriptRuleCount = numericValue(
                in: reportObject,
                matching: "userScriptRuleCount"
            ) ?? 0
            guard userScriptRuleCount > 0 else {
                continue
            }
            let expectedConfigFileName =
                reportURL.deletingPathExtension().lastPathComponent + ".runtime-config.json"
            if !includedConfigFileNames.contains(expectedConfigFileName) {
                missingConfigFileNames.append(expectedConfigFileName)
            }
        }

        guard missingConfigFileNames.isEmpty else {
            throw ToolError(
                "Runtime configs with user script rules are missing from public profiles: "
                    + missingConfigFileNames.joined(separator: ", ")
            )
        }
    }

    private static func numericValue(in object: Any, matching key: String) -> Int? {
        if let dictionary = object as? [String: Any] {
            if let value = dictionary[key] {
                if let number = value as? NSNumber {
                    return number.intValue
                }
                if let string = value as? String {
                    return Int(string)
                }
            }
            for value in dictionary.values {
                if let match = numericValue(in: value, matching: key) {
                    return match
                }
            }
        }
        if let array = object as? [Any] {
            for value in array {
                if let match = numericValue(in: value, matching: key) {
                    return match
                }
            }
        }
        return nil
    }

    private static func checksumRecords(at url: URL) throws -> [String: String] {
        let contents = try String(contentsOf: url, encoding: .utf8)
        var records: [String: String] = [:]
        for line in contents.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2 else {
                throw ToolError("Invalid checksum record in \(url.path): \(line)")
            }
            let path = String(parts[1])
            guard records[path] == nil else {
                throw ToolError("Duplicate checksum record in \(url.path): \(path)")
            }
            records[path] = String(parts[0])
        }
        return records
    }

    private static func validateChecksumRecord(
        for fileURL: URL,
        named fileName: String,
        records: [String: String]
    ) throws {
        let matches = records.filter { URL(fileURLWithPath: $0.key).lastPathComponent == fileName }
        guard matches.count == 1, let expected = matches.first?.value else {
            throw ToolError("Expected exactly one checksum record for \(fileName).")
        }
        let actual = sha256Hex(try Data(contentsOf: fileURL))
        guard actual == expected else {
            throw ToolError("Published checksum mismatch: \(fileName)")
        }
    }
}

struct RuntimeArtifactManifest: Codable, Equatable {
    var schemaVersion: Int
    var profiles: [Profile]

    struct Profile: Codable, Equatable {
        var id: String
        var fileName: String
        var injectionTime: String
        var forMainFrameOnly: Bool
        var contentWorld: String
        var sha256: String
        var byteCount: Int
        var report: String
    }
}

struct RuntimeArtifactReport: Codable, Equatable {
    var schemaVersion: Int
    var profileID: String
    var inputConfigFiles: [String]
    var ruleCounts: RuntimeRuleCounts
    var artifact: Artifact

    struct Artifact: Codable, Equatable {
        var fileName: String
        var byteCount: Int
        var sha256: String
        var injectionTime: String
        var forMainFrameOnly: Bool
        var contentWorld: String
    }
}

struct RuntimeRuleCounts: Codable, Equatable {
    var cosmetic: Int
    var cssInjection: Int
    var scriptlet: Int
    var network: Int
    var total: Int

    init(config: RuntimeConfig) {
        cosmetic = config.cosmeticRules.count
        cssInjection = config.cssInjectionRules.count
        scriptlet = config.scriptletRules.count
        network = config.networkRules.count
        total = cosmetic + cssInjection + scriptlet + network
    }
}

struct RuntimeArtifactGenerationResult: Equatable {
    var artifactFileName: String
    var inputConfigFileNames: [String]
    var ruleCounts: RuntimeRuleCounts
    var byteCount: Int
    var sha256: String
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data)
        .map { String(format: "%02x", $0) }
        .joined()
}
