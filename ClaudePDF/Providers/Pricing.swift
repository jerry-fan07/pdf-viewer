import Foundation

/// What one question costs, in USD per million tokens, split the four ways the
/// `usage` event reports (PLAN.md §7).
///
/// The point of showing this per answer isn't accounting — it's that "cached like
/// a project" only pays off if the cache is actually being hit, and a dollar
/// figure next to "97% cached" makes the difference legible. It also doubles as
/// the regression alarm the cache indicator already is: a question that suddenly
/// costs 10× is a question that lost its cached prefix.
struct TokenPricing: Sendable, Equatable {
    /// Fresh input — the cache-miss rate.
    let input: Double
    /// Input served from the cached prefix.
    let cacheRead: Double
    /// Input written into the cache. Zero on APIs that cache automatically and
    /// don't bill a premium for it (DeepSeek).
    let cacheWrite: Double
    let output: Double

    func cost(input inputTokens: Int, cacheRead reads: Int, cacheWrite writes: Int, output outputTokens: Int) -> Double {
        (Double(inputTokens) * input
            + Double(reads) * cacheRead
            + Double(writes) * cacheWrite
            + Double(outputTokens) * output) / 1_000_000
    }

    /// Anthropic's cache multipliers are fixed against the base input rate:
    /// reads are 0.1×, and a write at the 1-hour TTL this app requests is 2×
    /// (the 5-minute TTL would be 1.25×, but the document is cached for an hour).
    static func anthropic(input: Double, output: Double) -> TokenPricing {
        TokenPricing(input: input, cacheRead: input * 0.1, cacheWrite: input * 2, output: output)
    }

    /// Two significant decimals minimum, six maximum: a cached question on
    /// Haiku can genuinely cost a hundredth of a cent, and rounding that to
    /// "$0.00" throws away the only number that shows caching working.
    static func format(_ usd: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = usd < 0.01 ? 6 : (usd < 1 ? 4 : 2)
        let number = formatter.string(from: NSNumber(value: usd)) ?? String(usd)
        return "$\(number)"
    }
}
