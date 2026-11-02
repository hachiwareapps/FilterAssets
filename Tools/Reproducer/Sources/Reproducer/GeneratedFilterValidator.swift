import Foundation

enum GeneratedFilterValidator {
    static func validate(directoryURL: URL) throws {
        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !fileURLs.isEmpty else {
            throw ToolError("No generated Content Rule List JSON files found in \(directoryURL.path).")
        }

        var violations: [Violation] = []
        var ruleCount = 0

        for fileURL in fileURLs {
            let rules = try rules(in: fileURL)
            ruleCount += rules.count
            violations.append(contentsOf: unconstrainedFragmentBlockViolations(
                in: rules,
                sourceName: fileURL.lastPathComponent
            ))
        }

        guard violations.isEmpty else {
            let details = violations.prefix(10).map {
                "\($0.sourceName): rule \($0.ruleIndex + 1)"
            }.joined(separator: ", ")
            throw ToolError(
                "Found \(violations.count) unconstrained block rule(s) with url-filter \".*#\": \(details)"
            )
        }

        print(
            "Validated \(ruleCount) generated content rule(s) in \(fileURLs.count) file(s): "
                + "no unconstrained block rule uses url-filter \".*#\""
        )
    }

    static func unconstrainedFragmentBlockViolations(
        in rules: [[String: Any]],
        sourceName: String
    ) -> [Violation] {
        rules.enumerated().compactMap { ruleIndex, rule in
            guard let action = rule["action"] as? [String: Any],
                  action["type"] as? String == "block",
                  let trigger = rule["trigger"] as? [String: Any],
                  trigger["url-filter"] as? String == ".*#",
                  !hasPositiveDomainConstraint(trigger) else {
                return nil
            }

            return Violation(sourceName: sourceName, ruleIndex: ruleIndex)
        }
    }

    private static func rules(in fileURL: URL) throws -> [[String: Any]] {
        let data = try Data(contentsOf: fileURL)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let rules = object as? [[String: Any]] else {
            throw ToolError("Generated Content Rule List must be a JSON object array: \(fileURL.path)")
        }
        return rules
    }

    private static func hasPositiveDomainConstraint(_ trigger: [String: Any]) -> Bool {
        guard let domains = trigger["if-domain"] as? [String] else {
            return false
        }
        return !domains.isEmpty && domains.allSatisfy { domain in
            let trimmedDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedDomain.contains { $0.isLetter || $0.isNumber }
        }
    }

    struct Violation: Equatable {
        var sourceName: String
        var ruleIndex: Int
    }
}
