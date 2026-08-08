import XCTest
@testable import ClaudePDF

/// Phase 6: the per-answer cost line. It is a cache-regression alarm as much as
/// an invoice — a question that suddenly costs 10× is a question whose cached
/// prefix moved — so the arithmetic and the rounding both matter.
final class PricingTests: XCTestCase {

    func testAnthropicCacheMultipliers() {
        let opus = AnthropicModel.opus5.pricing
        XCTAssertEqual(opus.input, 5, accuracy: 1e-9)
        XCTAssertEqual(opus.output, 25, accuracy: 1e-9)
        XCTAssertEqual(opus.cacheRead, 0.5, accuracy: 1e-9, "cache reads are 0.1× input")
        XCTAssertEqual(opus.cacheWrite, 10, accuracy: 1e-9, "a 1-hour cache write is 2× input")
    }

    func testPublishedRatesPerModel() {
        XCTAssertEqual(AnthropicModel.sonnet5.pricing.input, 3, accuracy: 1e-9)
        XCTAssertEqual(AnthropicModel.sonnet5.pricing.output, 15, accuracy: 1e-9)
        XCTAssertEqual(AnthropicModel.haiku45.pricing.input, 1, accuracy: 1e-9)
        XCTAssertEqual(AnthropicModel.haiku45.pricing.output, 5, accuracy: 1e-9)
    }

    func testCostSumsTheFourBuckets() {
        let cost = AnthropicModel.opus5.pricing.cost(
            input: 1_000_000, cacheRead: 1_000_000, cacheWrite: 1_000_000, output: 1_000_000
        )
        XCTAssertEqual(cost, 5 + 0.5 + 10 + 25, accuracy: 1e-9)
    }

    /// The whole point of the caching design: question 2 on an already-attached
    /// document should be dramatically cheaper than question 1.
    func testCachedQuestionCostsFarLessThanTheFirst() {
        let pricing = AnthropicModel.opus5.pricing
        let first = pricing.cost(input: 200, cacheRead: 0, cacheWrite: 100_000, output: 500)
        let second = pricing.cost(input: 200, cacheRead: 100_000, cacheWrite: 0, output: 500)
        XCTAssertGreaterThan(first / second, 15)
    }

    /// DeepSeek's API caches automatically and bills no write premium — the
    /// provider never reports cache-write tokens, and the rate is zero so a
    /// stray one could not distort the figure either.
    func testDeepSeekHasNoCacheWritePremium() {
        let flash = DeepSeekModel.v4Flash.tokenPricing
        XCTAssertEqual(flash.cacheWrite, 0)
        XCTAssertEqual(flash.input, 0.14, accuracy: 1e-9)
        XCTAssertEqual(flash.cacheRead, 0.0028, accuracy: 1e-9)
        XCTAssertEqual(flash.output, 0.28, accuracy: 1e-9)
    }

    // MARK: Formatting

    /// A cached question on Haiku genuinely costs a hundredth of a cent.
    /// Rounding that to "$0.00" throws away the only number that shows the
    /// caching working.
    func testSubCentCostsKeepTheirDigits() {
        XCTAssertEqual(TokenPricing.format(0.000_123), "$0.000123")
        XCTAssertNotEqual(TokenPricing.format(0.0004), "$0.00")
    }

    func testLargerCostsRoundToCents() {
        XCTAssertEqual(TokenPricing.format(12.3456), "$12.35")
        XCTAssertEqual(TokenPricing.format(1), "$1.00")
    }

    func testMidRangeCostsKeepFourDecimals() {
        XCTAssertEqual(TokenPricing.format(0.0212), "$0.0212")
    }
}
