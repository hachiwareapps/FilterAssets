import CryptoKit
import Foundation

enum ContentRuleListResourceCompressor {
    static let manifestFileName = "ContentRuleListCompressionManifest.json"
    static let compressedFileExtension = "lzfse"
    private static let checksumResourcePathPrefix =
        "Sources/FilterAssets/Resources/AdBlock/"

    static func compress(inputDirectoryURL: URL, outputDirectoryURL: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: outputDirectoryURL,
            withIntermediateDirectories: true
        )

        let inputFileURLs = try fileManager.contentsOfDirectory(
            at: inputDirectoryURL,
            includingPropertiesForKeys: nil
        )
        .filter { $0.lastPathComponent.hasPrefix("ContentRuleList-") }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !inputFileURLs.isEmpty else {
            throw ToolError(
                "No ContentRuleList resources found in \(inputDirectoryURL.path)."
            )
        }

        var entries: [ContentRuleListCompressionManifest.Entry] = []
        for inputFileURL in inputFileURLs {
            let data = try Data(contentsOf: inputFileURL)
            let compressedData = try (data as NSData).compressed(using: .lzfse) as Data
            let compressedFileName =
                "\(inputFileURL.lastPathComponent).\(compressedFileExtension)"
            let outputFileURL = outputDirectoryURL.appendingPathComponent(compressedFileName)
            try compressedData.write(to: outputFileURL, options: .atomic)
            entries.append(
                ContentRuleListCompressionManifest.Entry(
                    fileName: inputFileURL.lastPathComponent,
                    compressedFileName: compressedFileName,
                    byteCount: data.count,
                    sha256: sha256(data)
                )
            )
        }

        let manifest = ContentRuleListCompressionManifest(
            schemaVersion: 1,
            algorithm: compressedFileExtension,
            entries: entries
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(
            to: outputDirectoryURL.appendingPathComponent(manifestFileName),
            options: .atomic
        )
    }

    static func validate(resourcesDirectoryURL: URL, checksumsFileURL: URL?) throws {
        let manifestURL = resourcesDirectoryURL.appendingPathComponent(manifestFileName)
        let manifest = try JSONDecoder().decode(
            ContentRuleListCompressionManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        guard manifest.schemaVersion == 1 else {
            throw ToolError(
                "Unsupported Content Rule List compression schema: \(manifest.schemaVersion)."
            )
        }
        guard manifest.algorithm == compressedFileExtension else {
            throw ToolError(
                "Unsupported Content Rule List compression algorithm: \(manifest.algorithm)."
            )
        }
        guard !manifest.entries.isEmpty else {
            throw ToolError("Content Rule List compression manifest has no entries.")
        }

        let expectedChecksums = try checksumsFileURL.map(parseChecksums) ?? [:]
        var fileNames: Set<String> = []
        var compressedFileNames: Set<String> = []
        for entry in manifest.entries {
            try validate(entry: entry)
            guard fileNames.insert(entry.fileName).inserted else {
                throw ToolError("Duplicate Content Rule List file name: \(entry.fileName).")
            }
            guard compressedFileNames.insert(entry.compressedFileName).inserted else {
                throw ToolError(
                    "Duplicate compressed Content Rule List file name: "
                        + "\(entry.compressedFileName)."
                )
            }
        }

        let actualCompressedFileNames = Set(
            try FileManager.default.contentsOfDirectory(
                at: resourcesDirectoryURL,
                includingPropertiesForKeys: nil
            )
            .filter { $0.pathExtension == compressedFileExtension }
            .map(\.lastPathComponent)
        )
        guard actualCompressedFileNames == compressedFileNames else {
            let missingFileNames = compressedFileNames
                .subtracting(actualCompressedFileNames)
                .sorted()
            let unexpectedFileNames = actualCompressedFileNames
                .subtracting(compressedFileNames)
                .sorted()
            throw ToolError(
                "Compressed Content Rule List files do not match the manifest"
                    + " (missing: \(missingFileNames), unexpected: \(unexpectedFileNames))."
            )
        }

        for entry in manifest.entries {
            let compressedData = try Data(
                contentsOf: resourcesDirectoryURL.appendingPathComponent(
                    entry.compressedFileName
                )
            )
            let data = try (compressedData as NSData).decompressed(using: .lzfse) as Data
            guard data.count == entry.byteCount else {
                throw ToolError(
                    "\(entry.fileName) byte count mismatch: "
                        + "expected \(entry.byteCount), got \(data.count)."
                )
            }
            let actualSHA256 = sha256(data)
            guard actualSHA256 == entry.sha256 else {
                throw ToolError(
                    "\(entry.fileName) checksum mismatch: "
                        + "expected \(entry.sha256), got \(actualSHA256)."
                )
            }
            if checksumsFileURL != nil {
                let checksumPath = checksumResourcePathPrefix + entry.fileName
                guard let expectedSHA256 = expectedChecksums[checksumPath] else {
                    throw ToolError(
                        "\(checksumPath) is missing from checksums.sha256."
                    )
                }
                guard expectedSHA256 == actualSHA256 else {
                    throw ToolError(
                        "\(entry.fileName) does not match checksums.sha256: "
                            + "expected \(expectedSHA256), got \(actualSHA256)."
                    )
                }
            }
        }
    }

    private static func validate(entry: ContentRuleListCompressionManifest.Entry) throws {
        guard entry.fileName == (entry.fileName as NSString).lastPathComponent,
              entry.fileName.hasPrefix("ContentRuleList-") else {
            throw ToolError("Invalid Content Rule List file name: \(entry.fileName).")
        }
        let expectedCompressedFileName =
            "\(entry.fileName).\(compressedFileExtension)"
        guard entry.compressedFileName == expectedCompressedFileName else {
            throw ToolError(
                "Invalid compressed file name for \(entry.fileName): "
                    + "\(entry.compressedFileName)."
            )
        }
        guard entry.byteCount >= 0 else {
            throw ToolError("Invalid byte count for \(entry.fileName): \(entry.byteCount).")
        }
        guard entry.sha256.count == 64,
              entry.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw ToolError("Invalid SHA-256 for \(entry.fileName): \(entry.sha256).")
        }
    }

    private static func parseChecksums(_ fileURL: URL) throws -> [String: String] {
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        var checksumsByPath: [String: String] = [:]
        var fileNames: Set<String> = []
        for line in contents.split(whereSeparator: \.isNewline) {
            let components = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard components.count == 2 else {
                throw ToolError("Invalid checksum line: \(line).")
            }
            let checksum = String(components[0])
            guard checksum.count == 64,
                  checksum.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
                throw ToolError("Invalid checksum: \(checksum).")
            }
            let path = String(components[1]).trimmingCharacters(
                in: CharacterSet(charactersIn: "* ")
            )
            let canonicalPath = (path as NSString).standardizingPath
            let fileName = (canonicalPath as NSString).lastPathComponent
            guard checksumsByPath[canonicalPath] == nil else {
                throw ToolError("Duplicate checksum path: \(canonicalPath).")
            }
            guard !fileNames.contains(fileName) else {
                throw ToolError("Duplicate checksum file name: \(fileName).")
            }
            guard path == canonicalPath,
                  canonicalPath.hasPrefix(checksumResourcePathPrefix) else {
                throw ToolError("Invalid FilterAssets checksum path: \(path).")
            }
            guard !fileName.isEmpty,
                  canonicalPath == checksumResourcePathPrefix + fileName else {
                throw ToolError("Invalid FilterAssets checksum path: \(path).")
            }
            fileNames.insert(fileName)
            checksumsByPath[canonicalPath] = checksum
        }
        return checksumsByPath
    }
}

struct ContentRuleListCompressionManifest: Codable, Equatable {
    struct Entry: Codable, Equatable {
        let fileName: String
        let compressedFileName: String
        let byteCount: Int
        let sha256: String
    }

    let schemaVersion: Int
    let algorithm: String
    let entries: [Entry]
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
