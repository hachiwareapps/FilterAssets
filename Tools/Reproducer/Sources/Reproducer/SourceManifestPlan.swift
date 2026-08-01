import Foundation

enum SourceManifestPlan {
    static func printPlan(options: Options) throws {
        let manifestURL = URL(fileURLWithPath: try options.value(for: "--source-manifest"))
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(SourceManifest.self, from: data)
        var sourceIDs = Set<String>()
        var outputPrefixes = Set<String>()

        for source in manifest.sources {
            try validateIdentifier(source.id, name: "source id")
            guard sourceIDs.insert(source.id).inserted else {
                throw ToolError("Duplicate source id in source manifest: \(source.id)")
            }
            let archiveURL = try archiveURL(repositoryURL: source.upstreamURL, commit: source.commit)
            for directory in source.includedDirectories {
                try validateRelativePath(directory.path)
                try validateIdentifier(directory.outputPrefix, name: "output prefix")
                guard outputPrefixes.insert(directory.outputPrefix).inserted else {
                    throw ToolError("Duplicate output prefix in source manifest: \(directory.outputPrefix)")
                }
                print([source.id, archiveURL, directory.path, directory.outputPrefix].joined(separator: "\t"))
            }
        }
    }

    private static func validateIdentifier(_ value: String, name: String) throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
        guard !value.isEmpty,
              value != ".",
              value != "..",
              value.unicodeScalars.allSatisfy(allowed.contains) else {
            throw ToolError("Invalid \(name) in source manifest.")
        }
    }

    private static func archiveURL(repositoryURL value: String, commit: String) throws -> String {
        let lowercaseCommit = commit.lowercased()
        let hexadecimal = CharacterSet(charactersIn: "0123456789abcdef")
        guard let url = URL(string: value),
              url.scheme == "https",
              url.host != nil,
              lowercaseCommit.count == 40,
              lowercaseCommit.unicodeScalars.allSatisfy(hexadecimal.contains) else {
            throw ToolError("Invalid repository URL or commit in source manifest.")
        }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            + "/archive/\(lowercaseCommit).zip"
    }

    private static func validateRelativePath(_ value: String) throws {
        let path = NSString(string: value)
        guard !value.isEmpty,
              !path.isAbsolutePath,
              !path.pathComponents.contains(".."),
              !value.contains("\t"),
              !value.contains("\n") else {
            throw ToolError("Invalid included directory in source manifest.")
        }
    }
}

private struct SourceManifest: Decodable {
    var sources: [Source]
}

private struct Source: Decodable {
    var id: String
    var upstreamURL: String
    var commit: String
    var includedDirectories: [IncludedDirectory]
}

private struct IncludedDirectory: Decodable {
    var path: String
    var outputPrefix: String
}
