import Foundation

/// What to do with a cropped region given the provider that would have to read it.
enum CropStagingDecision: Equatable {
    /// Attach it to the next question, with an optional one-line composer notice.
    case stage(PendingCrop, notice: String?)
    /// The provider can't see images and there is no text under the region —
    /// recognise the pixels first, then decide again with what came back.
    case recognize
    /// Nothing this provider can do with it.
    case refuse(notice: String)
}

/// The capability-based degradation of PLAN.md §4, as a pure decision.
///
/// It lives apart from the crop flow because it is asked twice: once when the
/// region is dragged, and again whenever the document's provider changes under a
/// crop that is already staged. A crop staged for Claude is a picture; the same
/// crop under DeepSeek is the text beneath it, or nothing at all.
enum CropStaging {

    static func decide(for crop: PendingCrop,
                       capabilities: ProviderCapabilities,
                       providerName: String,
                       ocrEnabled: Bool) -> CropStagingDecision
    {
        if capabilities.supportsVision { return .stage(crop, notice: nil) }

        if let text = crop.fallbackText,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .stage(crop, notice: textOnlyNotice(providerName: providerName))
        }

        // Blank pixels under a text-only provider: OCR is the only way through,
        // and it is exactly what a figure's axis labels or a scanned table need.
        guard ocrEnabled else { return .refuse(notice: noVisionNotice(providerName: providerName)) }
        return .recognize
    }

    static func textOnlyNotice(providerName: String) -> String {
        "\(providerName) can't see images — it will read the text inside this region."
    }

    static func noVisionNotice(providerName: String) -> String {
        "\(providerName) can't see images — switch to Claude for visual questions."
    }

    static func unrecognisedNotice(providerName: String) -> String {
        "\(providerName) can't see images, and no text could be recognised here — "
            + "switch to Claude for visual questions."
    }

    static let recognizingNotice = "Reading the text in this region…"
}
