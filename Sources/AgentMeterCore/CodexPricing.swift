import Foundation

public enum CodexPricing {
    public static let sourceURL = URL(string: "https://developers.openai.com/api/docs/pricing")!
    public static let verifiedOn = "2026-10-27"

    /// USD API reference cost for one response, rather than a subscription charge.
    /// Input includes cache reads and writes; output already includes reasoning tokens.
    /// Pass request input, never session-cumulative input, to select context pricing.
    /// The default is an explicit Standard reference baseline, not an inferred served tier.
    public static func estimate(model: String, inputTokens: Int64, cachedInputTokens: Int64,
                                cacheWriteInputTokens: Int64, outputTokens: Int64,
                                serviceTier: String = "standard", cacheRetention: String? = nil) -> Double? {
        guard inputTokens >= 0, cachedInputTokens >= 0, cacheWriteInputTokens >= 0,
              outputTokens >= 0, cachedInputTokens <= inputTokens,
              cacheWriteInputTokens <= inputTokens - cachedInputTokens,
              let modelPrice = models[model] else { return nil }

        let isLongContext = inputTokens > 272_000 && modelPrice.long != nil
        let rates = isLongContext ? modelPrice.long! : modelPrice.short
        let multiplier: Double
        switch serviceTier.lowercased() {
        case "standard", "default": multiplier = 1
        case "fast", "priority":
            guard let fast = isLongContext ? modelPrice.fastLong : modelPrice.fastShort else { return nil }
            multiplier = fast
        case "flex", "batch":
            guard modelPrice.discounted else { return nil }
            multiplier = 0.5
        default: return nil
        }

        var writeRate = 0.0
        if cacheWriteInputTokens > 0 {
            switch cacheRetention?.lowercased() {
            case "30m":
                guard let price = rates.write30m else { return nil }
                writeRate = price
            case "12h":
                guard let price = rates.write12h else { return nil }
                writeRate = price
            default: return nil
            }
        }

        // Cache writes use their own full rate; adding ordinary input again double charges them.
        // https://developers.openai.com/api/docs/guides/prompt-caching
        let ordinaryInput = inputTokens - cachedInputTokens - cacheWriteInputTokens
        return (Double(ordinaryInput) * rates.input
                + Double(cachedInputTokens) * rates.read
                + Double(cacheWriteInputTokens) * writeRate
                + Double(outputTokens) * rates.output) * multiplier / 1_000_000
    }

    private struct Rates {
        let input: Double
        let output: Double
        let read: Double
        let write30m: Double?
        let write12h: Double?

        init(_ input: Double, _ output: Double, _ read: Double,
             write30m: Double? = nil, write12h: Double? = nil) {
            self.input = input
            self.output = output
            self.read = read
            self.write30m = write30m
            self.write12h = write12h
        }

        var longContext: Rates {
            Rates(input * 2, output * 1.5, read * 2,
                  write30m: write30m.map { $0 * 2 }, write12h: write12h.map { $0 * 2 })
        }
    }

    private struct ModelPrice {
        let short: Rates
        let long: Rates?
        let fastShort: Double?
        let fastLong: Double?
        let discounted: Bool

        init(_ short: Rates, longContext: Bool = false, fast: Double? = nil,
             fastLong: Double? = nil, discounted: Bool = false) {
            self.short = short
            self.long = longContext ? short.longContext : nil
            self.fastShort = fast
            self.fastLong = fastLong
            self.discounted = discounted
        }
    }

    // Published prices per million tokens, verified against sourceURL on verifiedOn.
    // Deliberately exact model names: unknown aliases/variants are not assigned guessed prices.
    private static let models: [String: ModelPrice] = [
        "gpt-6-astra": ModelPrice(Rates(10, 50, 1, write30m: 12.5, write12h: 25),
                                   longContext: true, fast: 2, fastLong: 2, discounted: true),
        "gpt-6.1-sol": ModelPrice(Rates(2, 10, 0.1, write30m: 2.5, write12h: 5),
                                  longContext: true, fast: 2, fastLong: 2, discounted: true),
        "gpt-6.1-terra": ModelPrice(Rates(1, 5, 0.05, write30m: 1.25, write12h: 2.5),
                                    longContext: true, fast: 2, fastLong: 2, discounted: true),
        "gpt-6-sol": ModelPrice(Rates(2, 10, 0.2, write30m: 2.5, write12h: 5),
                                longContext: true, fast: 2, fastLong: 2, discounted: true),
        "gpt-6-luna": ModelPrice(Rates(0.1, 0.5, 0.01, write30m: 0.125, write12h: 0.25),
                                 longContext: true, fast: 2, fastLong: 2, discounted: true),
        "gpt-5.6-sol": ModelPrice(Rates(4, 20, 0.4, write30m: 5, write12h: 10),
                                  longContext: true, fast: 2, fastLong: 2, discounted: true),
        "gpt-5.6-terra": ModelPrice(Rates(2, 12, 0.2, write30m: 2.5, write12h: 5),
                                    longContext: true, fast: 2, fastLong: 2, discounted: true),
        "gpt-5.6-luna": ModelPrice(Rates(0.2, 1.2, 0.02, write30m: 0.25, write12h: 0.5),
                                   longContext: true, fast: 2, fastLong: 2, discounted: true),
        "gpt-5.5": ModelPrice(Rates(5, 30, 0.5), longContext: true, fast: 2.5, discounted: true),
        "gpt-5.4": ModelPrice(Rates(2.5, 15, 0.25), longContext: true, fast: 2),
        "gpt-5.4-mini": ModelPrice(Rates(0.75, 4.5, 0.075), fast: 2, discounted: true),
        "gpt-5.4-nano": ModelPrice(Rates(0.2, 1.25, 0.02), discounted: true),
        "gpt-5.3-codex": ModelPrice(Rates(1.75, 14, 0.175), fast: 2),
        "gpt-5.2": ModelPrice(Rates(1.75, 14, 0.175), fast: 2, discounted: true),
        "gpt-5.1": ModelPrice(Rates(1.25, 10, 0.125), fast: 2, discounted: true),
        "gpt-5": ModelPrice(Rates(1.25, 10, 0.125), fast: 2, discounted: true),
        "gpt-5-mini": ModelPrice(Rates(0.25, 2, 0.025), fast: 1.8, discounted: true),
        "gpt-5-nano": ModelPrice(Rates(0.05, 0.4, 0.005), discounted: true)
    ]
}
