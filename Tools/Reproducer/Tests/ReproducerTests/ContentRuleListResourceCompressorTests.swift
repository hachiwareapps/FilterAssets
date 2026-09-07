import CryptoKit
import Foundation
import Testing
@testable import Reproducer

struct ContentRuleListResourceCompressorTests {
    @Test func compress_圧縮後も元のバイト列とchecksumを復元できる() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let contents = Data(repeating: 0x41, count: 32_768)
        try fixture.write(contents, named: "ContentRuleList-example.json")

        try ContentRuleListResourceCompressor.compress(
            inputDirectoryURL: fixture.inputURL,
            outputDirectoryURL: fixture.outputURL
        )
        try ContentRuleListResourceCompressor.validate(
            resourcesDirectoryURL: fixture.outputURL,
            checksumsFileURL: nil
        )

        let manifest = try fixture.manifest()
        let entry = try #require(manifest.entries.first)
        #expect(entry.fileName == "ContentRuleList-example.json")
        #expect(entry.byteCount == contents.count)
        #expect(entry.sha256 == fixture.sha256(contents))
        #expect(
            try fixture.fileSize(named: entry.compressedFileName) < contents.count
        )
    }

    @Test func validate_圧縮データの破損を拒否する() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(
            Data(repeating: 0x42, count: 4_096),
            named: "ContentRuleList-example.json"
        )
        try ContentRuleListResourceCompressor.compress(
            inputDirectoryURL: fixture.inputURL,
            outputDirectoryURL: fixture.outputURL
        )
        let entry = try #require(try fixture.manifest().entries.first)
        try Data([0x00, 0x01, 0x02]).write(
            to: fixture.outputURL.appendingPathComponent(entry.compressedFileName)
        )

        #expect(throws: (any Error).self) {
            try ContentRuleListResourceCompressor.validate(
                resourcesDirectoryURL: fixture.outputURL,
                checksumsFileURL: nil
            )
        }
    }

    @Test func validate_checksumsファイルとの不一致を拒否する() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let fileName = "ContentRuleList-example.json"
        try fixture.write(Data("source".utf8), named: fileName)
        try ContentRuleListResourceCompressor.compress(
            inputDirectoryURL: fixture.inputURL,
            outputDirectoryURL: fixture.outputURL
        )
        let checksumsURL = fixture.rootURL.appendingPathComponent("checksums.sha256")
        try """
        \(String(repeating: "0", count: 64))  \(fixture.checksumPath(for: fileName))

        """.write(
            to: checksumsURL,
            atomically: true,
            encoding: .utf8
        )

        #expect(throws: (any Error).self) {
            try ContentRuleListResourceCompressor.validate(
                resourcesDirectoryURL: fixture.outputURL,
                checksumsFileURL: checksumsURL
            )
        }
    }

    @Test func validate_checksumsファイルのFilterAssets正規パスを受理する() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let contents = Data("source".utf8)
        let fileName = "ContentRuleList-example.json"
        try fixture.write(contents, named: fileName)
        try ContentRuleListResourceCompressor.compress(
            inputDirectoryURL: fixture.inputURL,
            outputDirectoryURL: fixture.outputURL
        )
        let checksumsURL = fixture.rootURL.appendingPathComponent("checksums.sha256")
        try """
        \(fixture.sha256(contents))  \(fixture.checksumPath(for: fileName))

        """.write(
            to: checksumsURL,
            atomically: true,
            encoding: .utf8
        )

        try ContentRuleListResourceCompressor.validate(
            resourcesDirectoryURL: fixture.outputURL,
            checksumsFileURL: checksumsURL
        )
    }

    @Test func validate_manifest未記載の圧縮ファイルを拒否する() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(
            Data(repeating: 0x43, count: 4_096),
            named: "ContentRuleList-example.json"
        )
        try ContentRuleListResourceCompressor.compress(
            inputDirectoryURL: fixture.inputURL,
            outputDirectoryURL: fixture.outputURL
        )
        let entry = try #require(try fixture.manifest().entries.first)
        try FileManager.default.copyItem(
            at: fixture.outputURL.appendingPathComponent(entry.compressedFileName),
            to: fixture.outputURL.appendingPathComponent(
                "ContentRuleList-unlisted.json.lzfse"
            )
        )

        #expect(throws: (any Error).self) {
            try ContentRuleListResourceCompressor.validate(
                resourcesDirectoryURL: fixture.outputURL,
                checksumsFileURL: nil
            )
        }
    }

    @Test func validate_checksumsファイルの無関係なパスを拒否する() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(
            Data("source".utf8),
            named: "ContentRuleList-example.json"
        )
        try ContentRuleListResourceCompressor.compress(
            inputDirectoryURL: fixture.inputURL,
            outputDirectoryURL: fixture.outputURL
        )
        let checksumsURL = fixture.rootURL.appendingPathComponent("checksums.sha256")
        try "\(String(repeating: "0", count: 64))  unrelated.json\n".write(
            to: checksumsURL,
            atomically: true,
            encoding: .utf8
        )

        #expect(throws: (any Error).self) {
            try ContentRuleListResourceCompressor.validate(
                resourcesDirectoryURL: fixture.outputURL,
                checksumsFileURL: checksumsURL
            )
        }
    }

    @Test func validate_checksumsファイルの同一正規パス重複を拒否する() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let contents = Data("source".utf8)
        let fileName = "ContentRuleList-example.json"
        try fixture.write(contents, named: fileName)
        try ContentRuleListResourceCompressor.compress(
            inputDirectoryURL: fixture.inputURL,
            outputDirectoryURL: fixture.outputURL
        )
        let checksumsURL = fixture.rootURL.appendingPathComponent("checksums.sha256")
        let line = "\(fixture.sha256(contents))  \(fixture.checksumPath(for: fileName))"
        try "\(line)\n\(line)\n".write(
            to: checksumsURL,
            atomically: true,
            encoding: .utf8
        )

        #expect(throws: (any Error).self) {
            try ContentRuleListResourceCompressor.validate(
                resourcesDirectoryURL: fixture.outputURL,
                checksumsFileURL: checksumsURL
            )
        }
    }

    @Test func validate_checksumsファイルの同一basename重複を拒否する() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let contents = Data("source".utf8)
        let fileName = "ContentRuleList-example.json"
        try fixture.write(contents, named: fileName)
        try ContentRuleListResourceCompressor.compress(
            inputDirectoryURL: fixture.inputURL,
            outputDirectoryURL: fixture.outputURL
        )
        let checksumsURL = fixture.rootURL.appendingPathComponent("checksums.sha256")
        try """
        \(fixture.sha256(contents))  \(fixture.checksumPath(for: fileName))
        \(fixture.sha256(contents))  unrelated/\(fileName)

        """.write(
            to: checksumsURL,
            atomically: true,
            encoding: .utf8
        )

        #expect(throws: (any Error).self) {
            try ContentRuleListResourceCompressor.validate(
                resourcesDirectoryURL: fixture.outputURL,
                checksumsFileURL: checksumsURL
            )
        }
    }
}

private struct Fixture {
    private let checksumResourcePathPrefix =
        "Sources/FilterAssets/Resources/AdBlock/"
    let fileManager = FileManager()
    let rootURL: URL
    let inputURL: URL
    let outputURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        inputURL = rootURL.appendingPathComponent("Input", isDirectory: true)
        outputURL = rootURL.appendingPathComponent("Output", isDirectory: true)
        try fileManager.createDirectory(at: inputURL, withIntermediateDirectories: true)
    }

    func write(_ data: Data, named fileName: String) throws {
        try data.write(to: inputURL.appendingPathComponent(fileName))
    }

    func manifest() throws -> ContentRuleListCompressionManifest {
        try JSONDecoder().decode(
            ContentRuleListCompressionManifest.self,
            from: Data(
                contentsOf: outputURL.appendingPathComponent(
                    ContentRuleListResourceCompressor.manifestFileName
                )
            )
        )
    }

    func fileSize(named fileName: String) throws -> Int {
        let attributes = try fileManager.attributesOfItem(
            atPath: outputURL.appendingPathComponent(fileName).path
        )
        return try #require((attributes[.size] as? NSNumber)?.intValue)
    }

    func checksumPath(for fileName: String) -> String {
        checksumResourcePathPrefix + fileName
    }

    func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func remove() {
        try? fileManager.removeItem(at: rootURL)
    }
}
