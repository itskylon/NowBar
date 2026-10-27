import Foundation

@main
enum CodexPricingSmoke {
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "CodexPricingSmoke", code: 1,
                                                  userInfo: [NSLocalizedDescriptionKey: message]) }
            checks += 1
        }
        func matches(_ value: Double?, _ expected: Double) -> Bool {
            guard let value else { return false }
            return abs(value - expected) < 0.000000001
        }
        func estimate(_ model: String = "gpt-6.1-sol", input: Int64 = 1_000,
                      cached: Int64 = 200, written: Int64 = 0, output: Int64 = 80,
                      tier: String = "standard", retention: String? = nil) -> Double? {
            CodexPricing.estimate(model: model, inputTokens: input, cachedInputTokens: cached,
                                  cacheWriteInputTokens: written, outputTokens: output,
                                  serviceTier: tier, cacheRetention: retention)
        }

        // Check published rates with distinct uncached, read, write, and output amounts.
        let models: [(String, Double, Double, Double, Double)] = [
            ("gpt-6-astra", 10, 50, 1, 12.5),
            ("gpt-6.1-sol", 2, 10, 0.1, 2.5),
            ("gpt-6.1-terra", 1, 5, 0.05, 1.25),
            ("gpt-6-sol", 2, 10, 0.2, 2.5),
            ("gpt-6-luna", 0.1, 0.5, 0.01, 0.125),
            ("gpt-5.6-sol", 4, 20, 0.4, 5),
            ("gpt-5.6-terra", 2, 12, 0.2, 2.5),
            ("gpt-5.6-luna", 0.2, 1.2, 0.02, 0.25)
        ]
        for (model, input, output, read, write) in models {
            let expected = (700 * input + 200 * read + 100 * write + 80 * output) / 1_000_000
            try check(matches(estimate(model, written: 100, retention: "30m"), expected),
                      "\(model): cache reads and writes must each replace ordinary input pricing")
            try check(matches(estimate(model, written: 100, tier: "fast", retention: "30m"), expected * 2),
                      "\(model): explicit Fast pricing")
            try check(matches(estimate(model, written: 100, tier: "flex", retention: "30m"), expected / 2),
                      "\(model): explicit Flex pricing")
            try check(matches(estimate(model, written: 100, tier: "batch", retention: "30m"), expected / 2),
                      "\(model): explicit Batch pricing")
        }

        try check(matches(estimate(written: 100, retention: "12h"), 0.00272), "12h write rate")
        try check(matches(estimate(input: 272_000, cached: 0), 0.5448), "272K remains short context")
        try check(matches(estimate(input: 272_001, cached: 0), 1.089204), "long context uses full request pricing")
        try check(matches(estimate(input: 272_001, cached: 272_001), 0.0556002),
                  "long context threshold includes cached input")
        try check(matches(estimate(input: 272_001, cached: 0, tier: "priority"), 2.178408),
                  "Priority uses published Fast long context rates")
        try check(matches(estimate(input: 300_000, cached: 200_000, written: 50_000,
                                   output: 1_000, retention: "30m"), 0.505),
                  "long context applies the full input, read, write, and output rates")
        try check(matches(estimate(input: 300_000, cached: 200_000, written: 50_000,
                                   output: 1_000, tier: "fast", retention: "12h"), 1.51),
                  "long Fast context and 12h retention combine without double charging input")
        try check(matches(estimate(input: 300_000, cached: 200_000, written: 50_000,
                                   output: 1_000, tier: "batch", retention: "30m"), 0.2525),
                  "explicit Batch long context rate")
        try check(matches(estimate("gpt-5.5"), 0.0065), "GPT-5.5 standard pricing")
        try check(matches(estimate("gpt-5.5", tier: "fast"), 0.01625), "GPT-5.5 short Fast is 2.5x")
        try check(estimate("gpt-5.5", input: 272_001, tier: "fast") == nil,
                  "GPT-5.5 long Fast has no published price")
        try check(matches(estimate("gpt-5.5", input: 272_001, cached: 0), 2.72361),
                  "GPT-5.5 long context pricing")
        try check(matches(estimate("gpt-5.3-codex"), 0.002555), "existing Codex model pricing")
        try check(matches(estimate("gpt-5.3-codex", tier: "fast"), 0.00511), "existing Codex Fast pricing")
        try check(matches(estimate("gpt-5-mini", tier: "fast"), 0.000657),
                  "older model Fast multipliers are not assumed to be 2x")
        try check(estimate("gpt-5.4-nano", tier: "fast") == nil, "unpublished older model Fast pricing")
        try check(estimate("gpt-5.3-codex", tier: "flex") == nil, "no inferred Flex support")
        try check(matches(estimate(input: 0, cached: 0, output: 0), 0), "known zero use has zero cost")
        try check(matches(estimate(tier: "default"), 0.00242), "API default tier is standard")
        try check(estimate("gpt-6.1-sol-unknown") == nil, "unknown variant must not inherit base price")
        try check(estimate("unknown-model", input: 0, cached: 0, output: 0) == nil, "unknown model remains unpriced")
        try check(estimate(tier: "unknown") == nil, "unknown tier remains unpriced")
        try check(estimate(tier: "auto") == nil, "auto does not identify the served tier")
        try check(estimate(tier: "scale") == nil, "unpublished tier remains unpriced")
        try check(estimate(written: 100) == nil, "write pricing needs known retention")
        try check(estimate(written: 100, retention: "24h") == nil, "unpublished retention remains unpriced")
        try check(estimate("gpt-5.5", written: 100, retention: "30m") == nil,
                  "no invented cache write price for older models")
        try check(estimate(input: -1, cached: 0) == nil, "reject negative input")
        try check(estimate(cached: -1) == nil, "reject negative cached input")
        try check(estimate(written: -1) == nil, "reject negative cache writes")
        try check(estimate(output: -1) == nil, "reject negative output")
        try check(estimate(cached: 1_001) == nil, "cache reads cannot exceed input")
        try check(estimate(cached: 600, written: 500, retention: "30m") == nil,
                  "cache reads and writes cannot overlap beyond input")
        try check(estimate(input: Int64.max, cached: Int64.max, written: 1, retention: "30m") == nil,
                  "subset validation cannot overflow")
        try check(estimate(input: Int64.max, cached: 0, output: Int64.max)?.isFinite == true,
                  "large valid counters cannot overflow")

        print("Codex pricing: \(checks) checks passed")
    }
}
