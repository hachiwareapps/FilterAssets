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
