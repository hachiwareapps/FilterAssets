import BlockerKit
import CryptoKit
import Foundation
import XCTest
#if canImport(Reproducer)
@testable import Reproducer
#elseif canImport(FilterAssetsUpdater)
@testable import FilterAssetsUpdater
#endif

final class RuntimeArtifactGeneratorTests: XCTestCase {
    private var temporaryDirectoryURL: URL!

    override func setUpWithError() throws {
        temporaryDirectoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RuntimeArtifactGeneratorTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectoryURL)
    }

    func testMergesRuntimeConfigsByFileNameAndGeneratesOneProfileArtifact() throws {
        let inputDirectoryURL = temporaryDirectoryURL.appendingPathComponent("input", isDirectory: true)
        let outputDirectoryURL = temporaryDirectoryURL.appendingPathComponent("output", isDirectory: true)
        let reportDirectoryURL = temporaryDirectoryURL.appendingPathComponent("reports", isDirectory: true)
        try FileManager.default.createDirectory(at: inputDirectoryURL, withIntermediateDirectories: true)

        let lastURL = inputDirectoryURL.appendingPathComponent(
            "adguard_japanese_z-last.runtime-config.json"
        )
        let firstURL = inputDirectoryURL.appendingPathComponent(
            "adguard_japanese_a-first.runtime-config.json"
        )
        try writeRuntimeConfig(runtimeConfig(marker: "z"), to: lastURL)
        try writeRuntimeConfig(runtimeConfig(marker: "a", domain: "soraraw.net"), to: firstURL)

        let mergedFromReverseOrder = try RuntimeArtifactGenerator.mergedRuntimeConfig(
            from: [lastURL, firstURL]
        )
        let mergedFromForwardOrder = try RuntimeArtifactGenerator.mergedRuntimeConfig(
            from: [firstURL, lastURL]
        )
        XCTAssertEqual(mergedFromReverseOrder, mergedFromForwardOrder)
        XCTAssertEqual(mergedFromReverseOrder.cosmeticRules.map(\.selector), [".a", ".z"])
        XCTAssertEqual(mergedFromReverseOrder.cssInjectionRules.map(\.selector), [".a-css", ".z-css"])
        XCTAssertEqual(mergedFromReverseOrder.scriptletRules.map(\.name), ["a-scriptlet", "z-scriptlet"])
        XCTAssertEqual(mergedFromReverseOrder.networkRules.map(\.urlPattern), ["a-network", "z-network"])

        let result = try RuntimeArtifactGenerator.generate(
            profileID: "adguard-japanese",
            inputPrefix: "adguard_japanese_",
            inputDirectoryURL: inputDirectoryURL,
            outputDirectoryURL: outputDirectoryURL,
            reportDirectoryURL: reportDirectoryURL
        )

        XCTAssertEqual(result.inputConfigFileNames, [
            "adguard_japanese_a-first.runtime-config.json",
            "adguard_japanese_z-last.runtime-config.json"
        ])
        XCTAssertEqual(result.ruleCounts.cosmetic, 2)
        XCTAssertEqual(result.ruleCounts.cssInjection, 2)
        XCTAssertEqual(result.ruleCounts.scriptlet, 2)
        XCTAssertEqual(result.ruleCounts.network, 2)
        XCTAssertEqual(result.ruleCounts.total, 8)

        let scriptURLs = try FileManager.default.contentsOfDirectory(
            at: outputDirectoryURL,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "js" }
        XCTAssertEqual(scriptURLs.map(\.lastPathComponent), ["BlockerKitUserScript-adguard-japanese.js"])
        let source = try String(contentsOf: try XCTUnwrap(scriptURLs.first), encoding: .utf8)
        XCTAssertTrue(source.contains("soraraw.net"))

        let manifest = try decodeManifest(in: outputDirectoryURL)
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.profiles.count, 1)
        XCTAssertEqual(manifest.profiles.first?.id, "adguard-japanese")
        XCTAssertEqual(manifest.profiles.first?.injectionTime, "documentStart")
        XCTAssertEqual(manifest.profiles.first?.forMainFrameOnly, false)
        XCTAssertEqual(manifest.profiles.first?.contentWorld, "page")

        let reorderedInputDirectoryURL = temporaryDirectoryURL.appendingPathComponent(
            "reordered-input",
            isDirectory: true
        )
        let reorderedOutputDirectoryURL = temporaryDirectoryURL.appendingPathComponent(
            "reordered-output",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: reorderedInputDirectoryURL,
            withIntermediateDirectories: true
        )
        try writeRuntimeConfig(
            runtimeConfig(marker: "a", domain: "soraraw.net"),
            to: reorderedInputDirectoryURL.appendingPathComponent(firstURL.lastPathComponent)
        )
        try writeRuntimeConfig(
            runtimeConfig(marker: "z"),
            to: reorderedInputDirectoryURL.appendingPathComponent(lastURL.lastPathComponent)
        )
        let reorderedResult = try RuntimeArtifactGenerator.generate(
            profileID: "adguard-japanese",
            inputPrefix: "adguard_japanese_",
            inputDirectoryURL: reorderedInputDirectoryURL,
            outputDirectoryURL: reorderedOutputDirectoryURL,
            reportDirectoryURL: temporaryDirectoryURL.appendingPathComponent("reordered-reports")
        )
        XCTAssertEqual(reorderedResult.sha256, result.sha256)
        XCTAssertEqual(
            try Data(contentsOf: reorderedOutputDirectoryURL.appendingPathComponent(result.artifactFileName)),
            try Data(contentsOf: outputDirectoryURL.appendingPathComponent(result.artifactFileName))
        )
    }

    func testRefusesToPublishEmptyRuntimeProfile() throws {
        let inputDirectoryURL = temporaryDirectoryURL.appendingPathComponent("input", isDirectory: true)
        try FileManager.default.createDirectory(at: inputDirectoryURL, withIntermediateDirectories: true)
        try writeRuntimeConfig(
            RuntimeConfig(),
            to: inputDirectoryURL.appendingPathComponent(
                "adguard_japanese_empty.runtime-config.json"
            )
        )

        XCTAssertThrowsError(
            try RuntimeArtifactGenerator.generate(
                profileID: "adguard-japanese",
                inputPrefix: "adguard_japanese_",
                inputDirectoryURL: inputDirectoryURL,
                outputDirectoryURL: temporaryDirectoryURL.appendingPathComponent("output"),
                reportDirectoryURL: temporaryDirectoryURL.appendingPathComponent("reports")
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("refusing to publish an empty artifact"))
        }
    }

    func testValidatorRejectsUnknownSchemaVersion() throws {
        let fixture = try makeValidArtifactFixture()
        var manifest = try decodeManifest(in: fixture.resourcesDirectoryURL)
        manifest.schemaVersion = 99
        try writeJSON(
            manifest,
            to: fixture.resourcesDirectoryURL.appendingPathComponent(
                RuntimeArtifactGenerator.manifestFileName
            )
        )

        XCTAssertThrowsError(
            try RuntimeArtifactValidator.validate(
                resourcesDirectoryURL: fixture.resourcesDirectoryURL
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("Unsupported user script artifact manifest schema version"))
        }
    }

    func testValidatorRejectsMissingArtifact() throws {
        let fixture = try makeValidArtifactFixture()
        let profile = try XCTUnwrap(decodeManifest(in: fixture.resourcesDirectoryURL).profiles.first)
        try FileManager.default.removeItem(
            at: fixture.resourcesDirectoryURL.appendingPathComponent(profile.fileName)
        )

        XCTAssertThrowsError(
            try RuntimeArtifactValidator.validate(
                resourcesDirectoryURL: fixture.resourcesDirectoryURL
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("User script artifact is missing"))
        }
    }

    func testValidatorRejectsArtifactNotDeclaredByManifest() throws {
        let fixture = try makeValidArtifactFixture()
        try "unexpected"
            .write(
                to: fixture.resourcesDirectoryURL.appendingPathComponent(
                    "BlockerKitUserScript-unexpected.js"
                ),
                atomically: true,
                encoding: .utf8
            )

        XCTAssertThrowsError(
            try RuntimeArtifactValidator.validate(
                resourcesDirectoryURL: fixture.resourcesDirectoryURL
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("do not match the manifest profiles"))
        }
    }

    func testValidatorRejectsPublishedChecksumMismatch() throws {
        let fixture = try makeValidArtifactFixture()
        let manifestURL = fixture.resourcesDirectoryURL.appendingPathComponent(
            RuntimeArtifactGenerator.manifestFileName
        )
        let manifestChecksum = sha256Hex(try Data(contentsOf: manifestURL))
        let checksumContents = """
        \(manifestChecksum)  Sources/FilterAssets/Resources/AdBlock/BlockerKitUserScriptManifest.json
        00  Sources/FilterAssets/Resources/AdBlock/BlockerKitUserScript-adguard-japanese.js

        """
        try checksumContents
            .write(to: fixture.checksumsFileURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try RuntimeArtifactValidator.validate(
                resourcesDirectoryURL: fixture.resourcesDirectoryURL,
                checksumsFileURL: fixture.checksumsFileURL
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("Published checksum mismatch"))
        }
    }

    private func makeValidArtifactFixture() throws -> (
        resourcesDirectoryURL: URL,
        checksumsFileURL: URL
    ) {
        let inputDirectoryURL = temporaryDirectoryURL.appendingPathComponent("fixture-input", isDirectory: true)
        let resourcesDirectoryURL = temporaryDirectoryURL.appendingPathComponent("fixture-resources", isDirectory: true)
        let reportDirectoryURL = temporaryDirectoryURL.appendingPathComponent("fixture-reports", isDirectory: true)
        try FileManager.default.createDirectory(at: inputDirectoryURL, withIntermediateDirectories: true)
        try writeRuntimeConfig(
            runtimeConfig(marker: "fixture", domain: "soraraw.net"),
            to: inputDirectoryURL.appendingPathComponent(
                "adguard_japanese_antiadblock.runtime-config.json"
            )
        )
        _ = try RuntimeArtifactGenerator.generate(
            profileID: "adguard-japanese",
            inputPrefix: "adguard_japanese_",
            inputDirectoryURL: inputDirectoryURL,
            outputDirectoryURL: resourcesDirectoryURL,
            reportDirectoryURL: reportDirectoryURL
        )

        let checksumsFileURL = temporaryDirectoryURL.appendingPathComponent("checksums.sha256")
        let resourceURLs = try FileManager.default.contentsOfDirectory(
            at: resourcesDirectoryURL,
            includingPropertiesForKeys: nil
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        let lines = try resourceURLs.map { url in
            "\(sha256Hex(try Data(contentsOf: url)))  Sources/FilterAssets/Resources/AdBlock/\(url.lastPathComponent)"
        }
        try (lines.joined(separator: "\n") + "\n")
            .write(to: checksumsFileURL, atomically: true, encoding: .utf8)
        try RuntimeArtifactValidator.validate(
            resourcesDirectoryURL: resourcesDirectoryURL,
            checksumsFileURL: checksumsFileURL
        )
        return (resourcesDirectoryURL, checksumsFileURL)
    }

    private func runtimeConfig(marker: String, domain: String = "example.com") -> RuntimeConfig {
        let domains = RuntimeDomainCondition(includeDomains: [domain])
        return RuntimeConfig(
            cosmeticRules: [
                RuntimeCosmeticRule(selector: ".\(marker)", kind: .extended, domains: domains)
            ],
            cssInjectionRules: [
                RuntimeCSSInjectionRule(
                    selector: ".\(marker)-css",
                    declaration: "display: none !important",
                    domains: domains
                )
            ],
            scriptletRules: [
                RuntimeScriptletRule(name: "\(marker)-scriptlet", arguments: [], domains: domains)
            ],
            networkRules: [
                RuntimeNetworkRule(urlPattern: "\(marker)-network", action: .block, domains: domains)
            ]
        )
    }

    private func writeRuntimeConfig(_ config: RuntimeConfig, to url: URL) throws {
        try writeJSON(config, to: url)
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private func decodeManifest(in directoryURL: URL) throws -> RuntimeArtifactManifest {
        try JSONDecoder().decode(
            RuntimeArtifactManifest.self,
            from: Data(
                contentsOf: directoryURL.appendingPathComponent(
                    RuntimeArtifactGenerator.manifestFileName
                )
            )
        )
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
