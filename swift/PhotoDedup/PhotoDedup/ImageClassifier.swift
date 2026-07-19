import Foundation
import Vision
import CoreGraphics

/// On-device scene/topic classifier built on Vision's `VNClassifyImageRequest`.
/// Turns an image into a short 2–3 word label (e.g. "Beach, Sky") for the
/// cluster sidebar. Fully local — no network, no Apple Intelligence dependency.
enum ImageClassifier {
    /// Highest label count we ever show, to keep sidebar rows to a couple words.
    private static let maxLabels = 3

    /// Broad parent categories in Vision's taxonomy that describe almost any
    /// photo ("outdoor", "sky", …). They're demoted so specific labels
    /// ("fireworks", "eyeglasses") lead; a generic term is only used to backfill
    /// when there aren't enough specific ones, or as a last resort.
    private static let genericTerms: Set<String> = [
        "outdoor", "indoor", "sky", "land", "structure", "people", "person",
        "material", "plant", "nature", "water", "wall", "light", "art",
        "no_person", "day", "night",
    ]

    /// Classifies a single image and returns a comma-joined, human-readable
    /// label, or nil if Vision produced nothing usable. Synchronous and
    /// CPU-bound — call it off the main actor.
    static func label(for cgImage: CGImage) -> String? {
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observations = request.results, !observations.isEmpty else {
            return nil
        }

        // Vision's own precision/recall gate keeps only labels the model is
        // actually confident about; fall back to the best guesses if the gate
        // rejects everything (rare, but avoids an empty caption).
        var gated = observations
            .filter { $0.hasMinimumRecall(0.01, forPrecision: 0.9) }
            .sorted { $0.confidence > $1.confidence }
        if gated.isEmpty {
            gated = observations.sorted { $0.confidence > $1.confidence }
        }

        // Prefer specific labels; backfill with generic parent terms only if we
        // don't have at least two specific ones. If everything is generic, keep
        // the single strongest so the row still says something.
        let identifiers = gated.map(\.identifier).filter { !$0.isEmpty }
        let specific = identifiers.filter { !genericTerms.contains($0.lowercased()) }
        let generic  = identifiers.filter {  genericTerms.contains($0.lowercased()) }

        var picks = specific
        if picks.count < 2 { picks += generic }
        if picks.isEmpty { picks = Array(generic.prefix(1)) }
        picks = Array(picks.prefix(maxLabels))

        let words = picks.map(humanize)
        guard !words.isEmpty else { return nil }
        return words.joined(separator: ", ")
    }

    /// "flower_arranging" → "Flower Arranging", "beach" → "Beach".
    private static func humanize(_ identifier: String) -> String {
        identifier
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
