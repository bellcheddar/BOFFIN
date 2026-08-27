//  NeuralEngineStatus.swift
//  BoffinUI
//
//  What the app can honestly say about the Neural Engine while it runs.
//
//  iOS exposes NO API for Neural Engine utilisation. There is no percentage to
//  read, no counter, nothing an app can query about how busy the ANE is. Any
//  dial showing one would be invented, and this project does not invent
//  numbers.
//
//  What IS knowable, and what this models:
//
//  * Whether BOFFIN is running a Core ML pass right now. The app knows,
//    because it is the thing making the call.
//  * How many passes it has run this session, and how long the last one took.
//  * How many of the model's operations Core ML SCHEDULED on the Neural
//    Engine, which is measured with MLComputePlan at conversion time.
//
//  That last one is a plan, not an execution trace, and the distinction is not
//  pedantic: a configuration measured at the identical 98.8% was found on
//  2026-08-26 to run three times slower than another, because residency
//  answers whether operations CAN run on the ANE and not how fast they will.
//  The wording below says "scheduled" for that reason.

import Foundation

public struct NeuralEngineStatus: Equatable, Sendable {

    public enum Activity: Equatable, Sendable {
        case idle
        /// One forward pass, the whole sequence at once.
        case embedding
        /// The heads reading the hidden states the backbone already produced.
        case heads
        /// One pass per position, so this one reports progress.
        case scanning(fraction: Double)

        public var isActive: Bool { self != .idle }

        /// What to call it on screen, in the user's terms rather than ours.
        public var label: String {
            switch self {
            case .idle: "Neural Engine idle"
            case .embedding: "Reading the sequence"
            case .heads: "Predicting structure and disorder"
            case .scanning: "Scoring every substitution"
            }
        }
    }

    /// Operations Core ML planned for the Neural Engine, of the total.
    ///
    /// Measured for `esm2_t12_35M_UR50D` with MLComputePlan, 2026-08-24. The
    /// nine that are not are casts and comparisons around the attention mask.
    public static let scheduledOnANE = 746
    public static let totalOperations = 755

    public static var scheduledFraction: Double {
        Double(scheduledOnANE) / Double(totalOperations)
    }

    public var activity: Activity = .idle
    /// Forward passes this launch. Counted, not estimated.
    public var passes: Int = 0
    /// How long the last completed pass took, when one has completed.
    public var lastPassSeconds: Double?

    public init(
        activity: Activity = .idle, passes: Int = 0, lastPassSeconds: Double? = nil
    ) {
        self.activity = activity
        self.passes = passes
        self.lastPassSeconds = lastPassSeconds
    }

    /// The detail line, or nil when there is nothing measured to say.
    ///
    /// Returns nil rather than a placeholder before the first pass: an app
    /// that shows "0 ms" before it has run anything is stating a measurement
    /// it has not made.
    public var detail: String? {
        guard passes > 0 else { return nil }
        let plural = passes == 1 ? "pass" : "passes"
        guard let lastPassSeconds else { return "\(passes) \(plural)" }
        let milliseconds = lastPassSeconds * 1000
        let time =
            milliseconds < 1000
            ? String(format: "%.0f ms", milliseconds)
            : String(format: "%.1f s", lastPassSeconds)
        return "\(passes) \(plural) · last \(time)"
    }
}
