import Foundation
import Testing
@testable import Headroom

/// #55: how operations were identified is carried with every total, separately from cost coverage (R7), and the
/// usage card says when a total may be approximate. The note is checked through `IdentityText`, the copy the card
/// shows; the SwiftUI view itself isn't rendered here.
struct IdentityCoverageTests {
    private func summary(_ identity: IdentityCoverage, cost: CostEstimate = CostEstimate(known: 1, knownTokens: 10)) -> UsageSummary {
        var s = UsageSummary()
        s.month = Totals(tokens: 10, cost: cost, identity: identity)
        return s
    }

    @Test func noteOnlyWhenSomethingIsUncertain() throws {
        #expect(IdentityText.note(nil) == nil)
        #expect(IdentityText.note(summary(IdentityCoverage())) == nil) // no usage
        #expect(IdentityText.note(summary(IdentityCoverage(identified: 5))) == nil)
        for c in [IdentityCoverage(identified: 5, incomplete: 1), IdentityCoverage(fingerprinted: 1),
                  IdentityCoverage(identified: 2, ambiguous: 1)] {
            let note = try #require(IdentityText.note(summary(c)))
            #expect(note.text == "Usage may be approximate: some records lack identifiers.")
            #expect(note.detail.contains("Of \(c.operations) Claude operation"))
        }
        let all = try #require(IdentityText.note(summary(IdentityCoverage(identified: 6, incomplete: 3, fingerprinted: 2,
                                                                         ambiguous: 1))))
        #expect(all.detail.hasPrefix("Of 12 Claude operations in the last 30 days, 6 were told apart"))
        #expect(all.detail.contains("3 by one id") && all.detail.contains("2 by their content")
                && all.detail.contains("1 by an id that more than one operation shares"))
        #expect(all.detail.contains("estimates, not your bill"))
    }

    /// Identity and cost are different questions: a fully priced total can be approximate, and an unpriced one exact.
    /// Neither note stands in for the other.
    @Test func independentOfCostCoverage() {
        let priced = summary(IdentityCoverage(fingerprinted: 1))
        #expect(priced.month.cost.coverage == .complete && IdentityText.note(priced) != nil)
        #expect(PricingText.coverageNote(claude: priced, grok: nil) == nil)

        var unpriced = summary(IdentityCoverage(identified: 1), cost: CostEstimate(unknownTokens: 10))
        unpriced.models = [ModelRow(model: "claude-new", tokens: 10, cost: CostEstimate(unknownTokens: 10))]
        #expect(IdentityText.note(unpriced) == nil)
        #expect(PricingText.coverageNote(claude: unpriced, grok: nil) != nil)
    }

    /// Combining with Grok keeps Claude's counts; Grok adds none.
    @Test func combineKeepsClaudeIdentity() throws {
        let claude = summary(IdentityCoverage(identified: 2, incomplete: 1))
        let grok = summary(IdentityCoverage())
        let combined = try #require(UsageSummary.combine(claude, grok))
        #expect(combined.month.identity == IdentityCoverage(identified: 2, incomplete: 1))
        #expect(combined.month.tokens == 20)
    }

    @Test func coverageArithmetic() {
        var c = IdentityCoverage()
        c.add(.identified, 3); c.add(.incomplete); c.add(.fingerprinted, 2); c.add(.ambiguous)
        #expect(c.operations == 7 && c.uncertain == 4 && !c.isExact)
        c.add(.incomplete, -1); c.add(.fingerprinted, -2); c.add(.ambiguous, -1)
        #expect(c.isExact && c == IdentityCoverage(identified: 3))
        #expect(c + IdentityCoverage(ambiguous: 1) == IdentityCoverage(identified: 3, ambiguous: 1))
    }

    /// Missing, empty, blank and non-string ids are all absent; any other string is used as it is.
    @Test func usableIDs() {
        for v: Any? in [nil, "", "   ", "\t\n", 123, NSNull(), ["msg"], ["id": "x"], true] {
            #expect(Ledger.usableID(v) == nil, "\(String(describing: v))")
        }
        #expect(Ledger.usableID("msg_1") == "msg_1")
        #expect(Ledger.usableID(" msg_1 ") == " msg_1 ")
    }
}
