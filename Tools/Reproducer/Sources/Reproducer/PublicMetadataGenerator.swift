import CryptoKit
import Foundation

struct PublicMetadataGenerator {
    static func run(options: Options) throws {
        let sourceManifestURL = URL(fileURLWithPath: try options.value(for: "--source-manifest"))
        let resourcesDirectoryURL = try options.directoryURL(for: "--resources-dir")
        let reportDirectoryURL = try options.directoryURL(for: "--report-dir")
        let runtimeReportDirectoryURL = try options.directoryURL(for: "--runtime-report-dir")
        let outputDirectoryURL = try options.directoryURL(for: "--output-dir")
        let packageName = try options.value(for: "--package-name")
        let packageVersion = try semanticVersion(try options.value(for: "--package-version"))
        let packageResolvedURL = try options.optionalFileURL(for: "--package-resolved")
        let reproducerRevision = options.optionalValue(for: "--reproducer-revision")
        let compilerBinaryArtifactChecksum = options.optionalValue(for: "--compiler-binary-artifact-checksum")
        let executionCommand = options.optionalValue(for: "--execution-command")

        let generatedAt = iso8601Now()
        let sourceManifest = try readJSONObject(at: sourceManifestURL)
        try RuntimeArtifactValidator.validate(resourcesDirectoryURL: resourcesDirectoryURL)
        let runtimeArtifactManifest = try JSONDecoder().decode(
            RuntimeArtifactManifest.self,
            from: Data(
                contentsOf: resourcesDirectoryURL.appendingPathComponent(
                    RuntimeArtifactGenerator.manifestFileName
                )
            )
        )
        let runtimeProfiles = try runtimeProfileRecords(
            manifest: runtimeArtifactManifest,
            reportDirectoryURL: runtimeReportDirectoryURL
        )
        let resourceFiles = try distributableResourceFiles(in: resourcesDirectoryURL)
        guard resourceFiles.contains(where: { $0.lastPathComponent.hasPrefix("ContentRuleList-") }) else {
            throw ToolError("No ContentRuleList resources found in \(resourcesDirectoryURL.path).")
        }

        let resourceRecords = try resourceFiles.map {
            try resourceRecord(for: $0, relativeTo: outputDirectoryURL)
        }
        let reportSummaries = try reportSummaryRecords(from: reportDirectoryURL)
        guard !reportSummaries.records.isEmpty else {
            throw ToolError("No conversion reports found in \(reportDirectoryURL.path).")
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: outputDirectoryURL, withIntermediateDirectories: true)
        let reportsOutputDirectoryURL = outputDirectoryURL.appendingPathComponent("reports", isDirectory: true)
        if fileManager.fileExists(atPath: reportsOutputDirectoryURL.path) {
            try fileManager.removeItem(at: reportsOutputDirectoryURL)
        }
        try fileManager.createDirectory(at: reportsOutputDirectoryURL, withIntermediateDirectories: true)

        let compilerSDKResolvedPin: [String: Any]?
        if let packageResolvedURL {
            compilerSDKResolvedPin = try compilerSDKPin(from: packageResolvedURL)
        } else {
            compilerSDKResolvedPin = nil
        }
        let manifest = packageManifest(
            packageName: packageName,
            packageVersion: packageVersion,
            sourceManifest: sourceManifest,
            generatedAt: generatedAt,
            compilerSDKPin: compilerSDKResolvedPin,
            reproducerRevision: reproducerRevision,
            compilerBinaryArtifactChecksum: compilerBinaryArtifactChecksum,
            executionCommand: executionCommand,
            runtimeProfiles: runtimeProfiles
        )
        let buildInfo = buildInfo(
            packageName: packageName,
            sourceManifest: sourceManifest,
            generatedAt: generatedAt,
            compilerSDKPin: compilerSDKResolvedPin,
            reproducerRevision: reproducerRevision,
            compilerBinaryArtifactChecksum: compilerBinaryArtifactChecksum,
            executionCommand: executionCommand,
            resourceRecords: resourceRecords,
            reportSummaries: reportSummaries,
            runtimeProfiles: runtimeProfiles
        )
        let conversionReport = conversionReport(
            generatedAt: generatedAt,
            resourceCount: resourceRecords.count,
            reportSummaries: reportSummaries,
            runtimeProfiles: runtimeProfiles
        )
        let unsupportedRulesLog = unsupportedRulesLog(
            generatedAt: generatedAt,
            reportSummaries: reportSummaries
        )
        let droppedRulesLog = droppedRulesLog(
            generatedAt: generatedAt,
            reportSummaries: reportSummaries
        )

        try writeJSON(manifest, to: outputDirectoryURL.appendingPathComponent("manifest.json"))
        try copyFile(sourceManifestURL, to: outputDirectoryURL.appendingPathComponent("filter-sources.json"))
        try writeJSON(buildInfo, to: outputDirectoryURL.appendingPathComponent("build-info.json"))
        let checksumsURL = outputDirectoryURL.appendingPathComponent("checksums.sha256")
        try writeChecksums(resourceRecords, to: checksumsURL)
        try writeJSON(conversionReport, to: reportsOutputDirectoryURL.appendingPathComponent("conversion-report.json"))
        try writeJSON(unsupportedRulesLog, to: reportsOutputDirectoryURL.appendingPathComponent("unsupported-rules.json"))
        try writeJSON(droppedRulesLog, to: reportsOutputDirectoryURL.appendingPathComponent("dropped-rules.json"))
        try copyDetailedReports(
            from: reportDirectoryURL,
            to: reportsOutputDirectoryURL.appendingPathComponent("blockerkit", isDirectory: true)
        )
        try copyDetailedReports(
            from: runtimeReportDirectoryURL,
            to: reportsOutputDirectoryURL.appendingPathComponent("runtime", isDirectory: true)
        )
        try RuntimeArtifactValidator.validate(
            resourcesDirectoryURL: resourcesDirectoryURL,
            checksumsFileURL: checksumsURL,
            metadataDirectoryURL: outputDirectoryURL
        )

        print("Public metadata generated in \(outputDirectoryURL.path)")
    }

    private static func packageManifest(
        packageName: String,
        packageVersion: String,
        sourceManifest: [String: Any],
        generatedAt: String,
        compilerSDKPin: [String: Any]?,
        reproducerRevision: String?,
        compilerBinaryArtifactChecksum: String?,
        executionCommand: String?,
        runtimeProfiles: [[String: Any]]
    ) -> [String: Any] {
        [
            "schemaVersion": 1,
            "generatedAt": generatedAt,
            "package": [
                "name": packageName,
                "version": packageVersion,
                "license": "GPL-3.0-only",
                "contents": "WebKit Content Rule List JSON and BlockerKit user script resources generated from AdGuard Filters and EasyList."
            ],
            "sourceManifest": "filter-sources.json",
            "sources": sourceManifest["sources"] ?? [],
            "conversion": [
                "inputFormat": "AdGuard/EasyList filter text",
                "outputFormat": "WebKit Content Rule List JSON and BlockerKit user script JavaScript",
                "contentRuleListTarget": FilterAssetsReproducer.contentRuleListTarget.rawValue,
                "filenameConvention": "ContentRuleList-<output-prefix>_<source-file>[_chunk_NNN].json",
                "userScriptArtifacts": [
                    "manifest": "Sources/\(packageName)/Resources/AdBlock/\(RuntimeArtifactGenerator.manifestFileName)",
                    "filenameConvention": "BlockerKitUserScript-<profile-id>.js",
                    "profiles": runtimeProfiles
                ],
                "report": "reports/conversion-report.json",
                "unsupportedRulesLog": "reports/unsupported-rules.json",
                "droppedRulesLog": "reports/dropped-rules.json",
                "detailedReportsDirectory": "reports/blockerkit"
            ],
            "correspondingSource": [
                "sourceManifest": "filter-sources.json",
                "publicReproducer": [
                    "path": "Tools/Reproducer",
                    "scripts": ["reproduce": "Scripts/reproduce.sh", "verify": "Scripts/verify.sh"],
                    "revision": (reproducerRevision as Any?) ?? NSNull(),
                    "executionCommand": (executionCommand as Any?) ?? NSNull(),
                    "compilerBinaryArtifactChecksum": (compilerBinaryArtifactChecksum as Any?) ?? NSNull(),
                    "sdk": (compilerSDKPin as Any?) ?? NSNull()
                ]
            ],
            "exclusions": [
                [
                    "package": "FilterPrivateAssets",
                    "reason": "First-party private filters are distributed separately and are not part of the GPL third-party filter package."
                ],
                [
                    "source": "AdGuard MobileFilter",
                    "reason": "MobileFilter/adguard_mobile resources are not included in this package."
                ]
            ]
        ]
    }

    private static func semanticVersion(_ value: String) throws -> String {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              components.allSatisfy({ component in
                  guard let number = Int(component), number >= 0 else { return false }
                  return String(number) == component
              }) else {
            throw ToolError("Package version must be a stable semantic version such as 0.1.0: \(value)")
        }
        return value
    }

    private static func buildInfo(
        packageName: String,
        sourceManifest: [String: Any],
        generatedAt: String,
        compilerSDKPin: [String: Any]?,
        reproducerRevision: String?,
        compilerBinaryArtifactChecksum: String?,
        executionCommand: String?,
        resourceRecords: [[String: Any]],
        reportSummaries: ReportSummaries,
        runtimeProfiles: [[String: Any]]
    ) -> [String: Any] {
        [
            "schemaVersion": 1,
            "generatedAt": generatedAt,
            "package": [
                "name": packageName,
                "resourceCount": resourceRecords.count
            ],
            "generator": [
                "name": "FilterAssetsReproducer",
                "reproducerRevision": (reproducerRevision as Any?) ?? NSNull(),
                "executionCommand": (executionCommand as Any?) ?? NSNull(),
                "compilerBinaryArtifactChecksum": (compilerBinaryArtifactChecksum as Any?) ?? NSNull(),
                "compilerSDK": (compilerSDKPin as Any?) ?? NSNull(),
                "contentRuleListTarget": FilterAssetsReproducer.contentRuleListTarget.rawValue,
                "publicCompiler": [
                    "name": "BlockerKitSDK",
                    "repository": "https://github.com/hachiwareapps/BlockerKitSDK",
                    "revision": compilerSDKPin?["revision"] ?? NSNull(),
                    "version": compilerSDKPin?["version"] ?? NSNull()
                ]
            ],
            "sourceCommits": sourceCommitRecords(from: sourceManifest),
            "output": [
                "resourcesDirectory": "Sources/\(packageName)/Resources/AdBlock",
                "files": resourceRecords
            ],
            "reports": [
                "conversionReport": "reports/conversion-report.json",
                "unsupportedRulesLog": "reports/unsupported-rules.json",
                "droppedRulesLog": "reports/dropped-rules.json",
                "detailedReportsDirectory": "reports/blockerkit",
                "runtimeReportsDirectory": "reports/runtime",
                "runtimeProfiles": runtimeProfiles,
                "inputReportCount": reportSummaries.records.count
            ]
        ]
    }

    private static func conversionReport(
        generatedAt: String,
        resourceCount: Int,
        reportSummaries: ReportSummaries,
        runtimeProfiles: [[String: Any]]
    ) -> [String: Any] {
        [
            "schemaVersion": 1,
            "generatedAt": generatedAt,
            "summary": [
                "inputReportCount": reportSummaries.records.count,
                "outputResourceCount": resourceCount,
                "unsupportedRuleCount": reportSummaries.unsupportedRuleCount,
                "webKitValidationSkippedRuleCount": reportSummaries.webKitValidationSkippedRuleCount,
                "skippedLineCount": reportSummaries.skippedLineCount
            ],
            "reports": reportSummaries.records,
            "runtimeProfiles": runtimeProfiles,
            "detailedReportsDirectory": "reports/blockerkit"
        ]
    }

    private static func unsupportedRulesLog(
        generatedAt: String,
        reportSummaries: ReportSummaries
    ) -> [String: Any] {
        [
            "schemaVersion": 1,
            "generatedAt": generatedAt,
            "summary": [
                "unsupportedRuleCount": reportSummaries.unsupportedRuleCount
            ],
            "entries": reportSummaries.unsupportedDiagnostics,
            "detailedReportsDirectory": "reports/blockerkit"
        ]
    }

    private static func droppedRulesLog(
        generatedAt: String,
        reportSummaries: ReportSummaries
    ) -> [String: Any] {
        [
            "schemaVersion": 1,
            "generatedAt": generatedAt,
            "summary": [
                "webKitValidationSkippedRuleCount": reportSummaries.webKitValidationSkippedRuleCount,
                "skippedLineCount": reportSummaries.skippedLineCount
            ],
            "entries": reportSummaries.webKitValidationSkippedRules,
            "skippedLineReports": reportSummaries.records.filter {
                (($0["skippedLineCount"] as? Int) ?? 0) > 0
            },
            "detailedReportsDirectory": "reports/blockerkit"
        ]
    }

    private static func sourceCommitRecords(from sourceManifest: [String: Any]) -> [[String: Any]] {
        guard let sources = sourceManifest["sources"] as? [[String: Any]] else {
            return []
        }

        return sources.map { source in
            [
                "id": source["id"] ?? NSNull(),
                "name": source["name"] ?? NSNull(),
                "upstreamURL": source["upstreamURL"] ?? NSNull(),
                "ref": source["ref"] ?? NSNull(),
                "commit": source["commit"] ?? NSNull(),
                "retrievedAt": source["retrievedAt"] ?? NSNull()
            ]
        }
    }

    private static func reportSummaryRecords(from reportDirectoryURL: URL) throws -> ReportSummaries {
        let fileManager = FileManager.default
        let reportFileURLs = try fileManager.contentsOfDirectory(
            at: reportDirectoryURL,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var records: [[String: Any]] = []
        var unsupportedDiagnostics: [[String: Any]] = []
        var webKitValidationSkippedRules: [[String: Any]] = []
        var unsupportedRuleCount = 0
        var webKitValidationSkippedRuleCount = 0
        var skippedLineCount = 0

        for reportFileURL in reportFileURLs {
            let report = try readJSONObject(at: reportFileURL)
            let reportFilePath = "reports/blockerkit/\(reportFileURL.lastPathComponent)"
            let sourceFileName = report["sourceFileName"] as? String ?? reportFileURL.deletingPathExtension().lastPathComponent
            let unsupportedCount = numericValue(
                in: report,
                matching: { $0 == "unsupportedRuleCount" }
            ) ?? 0
            let webKitSkippedCount = intValue(report["webKitValidationSkippedRuleCount"]) ?? 0
            let skippedLines = numericValue(
                in: report,
                matching: { $0 == "skippedLines" || $0 == "skippedLineCount" }
            ) ?? 0
            let outputFileNames = report["outputFileNames"] as? [String] ?? []

            unsupportedRuleCount += unsupportedCount
            webKitValidationSkippedRuleCount += webKitSkippedCount
            skippedLineCount += skippedLines

            records.append([
                "sourceFileName": sourceFileName,
                "reportFile": reportFilePath,
                "outputFileNames": outputFileNames,
                "outputFileCount": outputFileNames.count,
                "unsupportedRuleCount": unsupportedCount,
                "webKitValidationSkippedRuleCount": webKitSkippedCount,
                "skippedLineCount": skippedLines
            ])

            unsupportedDiagnostics.append(contentsOf: unsupportedDiagnosticsRecords(
                in: report,
                sourceFileName: sourceFileName,
                reportFilePath: reportFilePath
            ))
            webKitValidationSkippedRules.append(contentsOf: webKitValidationSkippedRuleRecords(
                in: report,
                sourceFileName: sourceFileName,
                reportFilePath: reportFilePath
            ))
        }

        return ReportSummaries(
            records: records,
            unsupportedDiagnostics: unsupportedDiagnostics,
            webKitValidationSkippedRules: webKitValidationSkippedRules,
            unsupportedRuleCount: unsupportedRuleCount,
            webKitValidationSkippedRuleCount: webKitValidationSkippedRuleCount,
            skippedLineCount: skippedLineCount
        )
    }

    private static func unsupportedDiagnosticsRecords(
        in report: [String: Any],
        sourceFileName: String,
        reportFilePath: String
    ) -> [[String: Any]] {
        guard let reportBody = report["report"] as? [String: Any],
              let diagnostics = reportBody["diagnostics"] as? [[String: Any]] else {
            return []
        }

        return diagnostics.compactMap { diagnostic in
            guard (diagnostic["severity"] as? String) == "unsupported" else {
                return nil
            }

            return [
                "sourceFileName": sourceFileName,
                "reportFile": reportFilePath,
                "lineNumber": diagnostic["lineNumber"] ?? NSNull(),
                "code": diagnostic["code"] ?? NSNull(),
                "message": diagnostic["message"] ?? NSNull(),
                "source": diagnostic["source"] ?? NSNull()
            ]
        }
    }

    private static func webKitValidationSkippedRuleRecords(
        in report: [String: Any],
        sourceFileName: String,
        reportFilePath: String
    ) -> [[String: Any]] {
        guard let skippedRules = report["webKitValidationSkippedRules"] as? [[String: Any]] else {
            return []
        }

        return skippedRules.map { skippedRule in
            [
                "sourceFileName": sourceFileName,
                "reportFile": reportFilePath,
                "validationIdentifier": skippedRule["validationIdentifier"] ?? NSNull(),
                "errorDescription": skippedRule["errorDescription"] ?? NSNull(),
                "contentRuleJSON": skippedRule["contentRuleJSON"] ?? NSNull()
            ]
        }
    }

    private static func runtimeProfileRecords(
        manifest: RuntimeArtifactManifest,
        reportDirectoryURL: URL
    ) throws -> [[String: Any]] {
        try manifest.profiles.map { profile in
            let reportURL = reportDirectoryURL.appendingPathComponent("\(profile.id).json")
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

            return [
                "profileID": profile.id,
                "artifact": "Sources/FilterAssets/Resources/AdBlock/\(profile.fileName)",
                "artifactManifest": "Sources/FilterAssets/Resources/AdBlock/\(RuntimeArtifactGenerator.manifestFileName)",
                "report": profile.report,
                "inputConfigFiles": report.inputConfigFiles,
                "ruleCounts": [
                    "cosmetic": report.ruleCounts.cosmetic,
                    "cssInjection": report.ruleCounts.cssInjection,
                    "scriptlet": report.ruleCounts.scriptlet,
                    "network": report.ruleCounts.network,
                    "total": report.ruleCounts.total
                ],
                "byteCount": profile.byteCount,
                "sha256": profile.sha256
            ]
        }
    }

    private static func distributableResourceFiles(in directoryURL: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
            .filter {
                ($0.lastPathComponent.hasPrefix("ContentRuleList-") && $0.pathExtension == "json")
                    || ($0.lastPathComponent.hasPrefix("BlockerKitUserScript-") && $0.pathExtension == "js")
                    || $0.lastPathComponent == RuntimeArtifactGenerator.manifestFileName
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func resourceRecord(for fileURL: URL, relativeTo outputDirectoryURL: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: fileURL)
        let sha256 = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()

        return [
            "path": relativePath(from: outputDirectoryURL, to: fileURL),
            "sha256": sha256,
            "byteCount": data.count
        ]
    }

    private static func compilerSDKPin(from packageResolvedURL: URL) throws -> [String: Any]? {
        let root = try readJSONObject(at: packageResolvedURL)
        guard let pins = root["pins"] as? [[String: Any]] else {
            return nil
        }

        guard let pin = pins.first(where: {
            let identity = ($0["identity"] as? String)?.lowercased()
            return identity == "blockerkitsdk" || identity == "blockerkit"
        }) else {
            return nil
        }

        let state = pin["state"] as? [String: Any] ?? [:]
        return [
            "identity": pin["identity"] ?? "blockerkitsdk",
            "location": pin["location"] ?? NSNull(),
            "branch": state["branch"] ?? NSNull(),
            "revision": state["revision"] ?? NSNull(),
            "version": state["version"] ?? NSNull()
        ]
    }

    private static func copyDetailedReports(from sourceDirectoryURL: URL, to destinationDirectoryURL: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destinationDirectoryURL, withIntermediateDirectories: true)

        let reportFileURLs = try fileManager.contentsOfDirectory(at: sourceDirectoryURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for reportFileURL in reportFileURLs {
            try copyFile(reportFileURL, to: destinationDirectoryURL.appendingPathComponent(reportFileURL.lastPathComponent))
        }
    }

    private static func writeChecksums(_ resourceRecords: [[String: Any]], to outputURL: URL) throws {
        let lines = resourceRecords.compactMap { record -> String? in
            guard let sha256 = record["sha256"] as? String,
                  let path = record["path"] as? String else {
                return nil
            }
            return "\(sha256)  \(path)"
        }
        try (lines.joined(separator: "\n") + "\n").write(to: outputURL, atomically: true, encoding: .utf8)
    }

    private static func copyFile(_ sourceURL: URL, to destinationURL: URL) throws {
        if sourceURL.standardizedFileURL == destinationURL.standardizedFileURL {
            return
        }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    private static func writeJSON(_ object: [String: Any], to outputURL: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: outputURL, options: .atomic)
    }

    private static func readJSONObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolError("Expected a JSON object at \(url.path).")
        }
        return object
    }

    private static func numericValue(in object: Any, matching keyMatches: (String) -> Bool) -> Int? {
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary where keyMatches(key) {
                if let intValue = intValue(value) {
                    return intValue
                }
            }
            for value in dictionary.values {
                if let intValue = numericValue(in: value, matching: keyMatches) {
                    return intValue
                }
            }
        }

        if let array = object as? [Any] {
            for value in array {
                if let intValue = numericValue(in: value, matching: keyMatches) {
                    return intValue
                }
            }
        }

        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let intValue = value as? Int {
            return intValue
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    private static func relativePath(from baseURL: URL, to fileURL: URL) -> String {
        let basePath = baseURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        let prefix = basePath + "/"

        guard filePath.hasPrefix(prefix) else {
            return fileURL.lastPathComponent
        }

        return String(filePath.dropFirst(prefix.count))
    }

    private static func iso8601Now() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

}

private struct ReportSummaries {
    var records: [[String: Any]]
    var unsupportedDiagnostics: [[String: Any]]
    var webKitValidationSkippedRules: [[String: Any]]
    var unsupportedRuleCount: Int
    var webKitValidationSkippedRuleCount: Int
    var skippedLineCount: Int
}
