import BlockerKit
import Foundation
import XCTest
#if canImport(Reproducer)
@testable import Reproducer
#elseif canImport(FilterAssetsUpdater)
@testable import FilterAssetsUpdater
#endif

final class GeneratedFilterValidatorTests: XCTestCase {
    func testContentRuleListTargetIsIOS17() {
        XCTAssertEqual(FilterAssetsReproducer.contentRuleListTarget.rawValue, "iOS17")
    }

    @MainActor
    func testGroupedFilterFragmentsShareCrossFilePreprocessing() async throws {
        let group = try await FilterAssetsReproducer.compileFilterFragments(
            [
                "##.generic-ad",
                "@@||example.com^$generichide"
            ],
            compiler: BlockerKitCompiler()
        )

        XCTAssertEqual(group.bundles.count, 2)
        XCTAssertNil(group.bundles[0].contentRuleListJSON)
        XCTAssertEqual(group.runtimeConfig.cosmeticRules.count, 2)
        XCTAssertTrue(group.bundles.allSatisfy(\.userScripts.isEmpty))
    }

    func testReassemblesValidatedSubchunksInOriginalRuleOrder() throws {
        let blockRule = """
        [{"trigger":{"url-filter":"blocked"},"action":{"type":"block"}}]
        """
        let exceptionRule = """
        [{"trigger":{"url-filter":"allowed"},"action":{"type":"ignore-previous-rules"}}]
        """

        let reassembled = try XCTUnwrap(
            FilterAssetsReproducer.reassembleContentRuleListJSONChunks([
                blockRule,
                exceptionRule
            ])
        )
        let object = try JSONSerialization.jsonObject(with: Data(reassembled.utf8))
        let rules = try XCTUnwrap(object as? [[String: Any]])
        let actionTypes = rules.compactMap { rule in
            (rule["action"] as? [String: Any])?["type"] as? String
        }

        XCTAssertEqual(actionTypes, ["block", "ignore-previous-rules"])
    }

    func testRejectsUnconstrainedFragmentBlockRule() {
        let rules: [[String: Any]] = [
            [
                "trigger": ["url-filter": ".*#"],
                "action": ["type": "block"]
            ]
        ]

        XCTAssertEqual(
            GeneratedFilterValidator.unconstrainedFragmentBlockViolations(
                in: rules,
                sourceName: "known-dangerous.json"
            ),
            [.init(sourceName: "known-dangerous.json", ruleIndex: 0)]
        )
    }

    func testAllowsDomainConstrainedFragmentBlockRule() {
        let rules: [[String: Any]] = [
            [
                "trigger": [
                    "url-filter": ".*#",
                    "if-domain": ["4pda.to"]
                ],
                "action": ["type": "block"]
            ]
        ]

        XCTAssertTrue(
            GeneratedFilterValidator.unconstrainedFragmentBlockViolations(
                in: rules,
                sourceName: "constrained.json"
            ).isEmpty
        )
    }

    func testRejectsFragmentBlockRuleWithOnlyNegativeDomainConstraint() {
        let rules: [[String: Any]] = [
            [
                "trigger": [
                    "url-filter": ".*#",
                    "unless-domain": ["4pda.to"]
                ],
                "action": ["type": "block"]
            ]
        ]

        XCTAssertEqual(
            GeneratedFilterValidator.unconstrainedFragmentBlockViolations(
                in: rules,
                sourceName: "broad-negative-constraint.json"
            ),
            [.init(sourceName: "broad-negative-constraint.json", ruleIndex: 0)]
        )
    }

    func testRejectsFragmentBlockRuleWithWhitespaceOnlyDomainConstraint() {
        let rules: [[String: Any]] = [
            [
                "trigger": [
                    "url-filter": ".*#",
                    "if-domain": [" \t\n"]
                ],
                "action": ["type": "block"]
            ]
        ]

        XCTAssertEqual(
            GeneratedFilterValidator.unconstrainedFragmentBlockViolations(
                in: rules,
                sourceName: "whitespace-domain.json"
            ),
            [.init(sourceName: "whitespace-domain.json", ruleIndex: 0)]
        )
    }

    func testRejectsFragmentBlockRuleWithWildcardOnlyDomainConstraint() {
        let rules: [[String: Any]] = [
            [
                "trigger": [
                    "url-filter": ".*#",
                    "if-domain": ["*"]
                ],
                "action": ["type": "block"]
            ]
        ]

        XCTAssertEqual(
            GeneratedFilterValidator.unconstrainedFragmentBlockViolations(
                in: rules,
                sourceName: "wildcard-domain.json"
            ),
            [.init(sourceName: "wildcard-domain.json", ruleIndex: 0)]
        )
    }

    func testRejectsFragmentBlockRuleWhenAnyPositiveDomainIsWildcardOnly() {
        let rules: [[String: Any]] = [
            [
                "trigger": [
                    "url-filter": ".*#",
                    "if-domain": ["4pda.to", "*"]
                ],
                "action": ["type": "block"]
            ]
        ]

        XCTAssertEqual(
            GeneratedFilterValidator.unconstrainedFragmentBlockViolations(
                in: rules,
                sourceName: "mixed-wildcard-domain.json"
            ),
            [.init(sourceName: "mixed-wildcard-domain.json", ruleIndex: 0)]
        )
    }

    func testAllowsLeadingWildcardDomainConstraint() {
        let rules: [[String: Any]] = [
            [
                "trigger": [
                    "url-filter": ".*#",
                    "if-domain": ["*4pda.to"]
                ],
                "action": ["type": "block"]
            ]
        ]

        XCTAssertTrue(
            GeneratedFilterValidator.unconstrainedFragmentBlockViolations(
                in: rules,
                sourceName: "wildcard-subdomain.json"
            ).isEmpty
        )
    }

    @MainActor
    func testKnownAdGuardExtendedCSSRuleDoesNotGenerateDangerousBlockRule() async throws {
        let filterText = #"4pda.to#$?#.article-gallery-image-container > a[data-lightbox^="post-"]:not(#style_important):has(> img) { display: block !important; }"#
        let compiler = BlockerKitCompiler(
            options: BlockerKitCompiler.Options(
                includeNativeCosmeticRules: true,
                includeUserScriptRuntime: false,
                includeURLSchemeHandlerRules: false,
                prettyPrintedJSON: false,
                contentRuleListMaxRuleCountPerChunk: 3000,
                contentRuleListTarget: FilterAssetsReproducer.contentRuleListTarget,
                resourceLimits: BlockerKitCompiler.ResourceLimits(
                    maxInputRuleCount: 100_000,
                    maxGeneratedContentRuleCount: 60_000
                )
            )
        )

        let bundle = try await compiler.compile(filterText, progress: nil)
        var generatedRules: [[String: Any]] = []
        for chunk in bundle.contentRuleListJSONChunks {
            let object = try JSONSerialization.jsonObject(with: Data(chunk.utf8))
            generatedRules.append(contentsOf: try XCTUnwrap(object as? [[String: Any]]))
        }

        XCTAssertTrue(
            GeneratedFilterValidator.unconstrainedFragmentBlockViolations(
                in: generatedRules,
                sourceName: "4pda-regression.json"
            ).isEmpty
        )
    }
}
