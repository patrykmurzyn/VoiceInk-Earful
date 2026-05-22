//
//  VoiceInkTests.swift
//  VoiceInkTests
//
//  Created by Prakash Joshi on 15/10/2024.
//

import Testing
import Foundation
@testable import VoiceInk

struct VoiceInkTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }

    @Test func mixedLiveDisplayPartialDropsCommittedPrefix() async throws {
        let partial = "Raz, dwa, trzy, cztery, pięć. Okej, to w mi dobrze."
        let committed = "Raz, dwa, trzy, cztery, pięć."

        #expect(MixedLiveStreamer.displayablePartial(partial, after: committed) == "Okej, to w mi dobrze.")
    }

    @Test func mixedLiveDisplayPartialSuppressesFullyCommittedText() async throws {
        let partial = "Jest to wbrew interesie firmy."
        let committed = "Jest to wbrew interesie firmy."

        #expect(MixedLiveStreamer.displayablePartial(partial, after: committed) == nil)
    }

    @Test func mixedLiveDisplayPartialKeepsUnmatchedHypothesis() async throws {
        let partial = "Okej, to w mi dobrze."
        let committed = "Raz, dwa, trzy, cztery, pięć."

        #expect(MixedLiveStreamer.displayablePartial(partial, after: committed) == "Okej, to w mi dobrze.")
    }

    @Test func mixedLiveBubbleLengthLimitDetectsLongText() async throws {
        let text = "jeden dwa trzy cztery pięć sześć siedem osiem dziewięć dziesięć jedenaście dwanaście"

        #expect(MixedLiveStreamer.isOversizedBubble(text, maxWords: 10, maxCharacters: 500))
        #expect(!MixedLiveStreamer.isOversizedBubble("krótki tekst", maxWords: 10, maxCharacters: 500))
    }

    @Test func mixedLiveRMSDetectsSilenceAndSignal() async throws {
        let silence = Data(repeating: 0, count: 160 * MemoryLayout<Int16>.size)
        var signal = Data()
        for _ in 0..<160 {
            var sample = Int16(3_000)
            withUnsafeBytes(of: &sample) { signal.append(contentsOf: $0) }
        }

        #expect(MixedLiveStreamer.rmsLevel(forPCM16Data: silence) == 0)
        #expect(MixedLiveStreamer.rmsLevel(forPCM16Data: signal) > 0.006)
    }

    @Test func mixedLiveSegmentBoundaryTriggersOnSilence() async throws {
        let now = Date()

        #expect(MixedLiveStreamer.shouldFinalizeSegment(
            text: "Okej, testuję aplikację.",
            segmentStartedAt: now.addingTimeInterval(-1),
            lastPartialUpdate: now,
            lastVoiceActivity: now.addingTimeInterval(-1.2),
            now: now,
            silenceTimeout: 1.1,
            partialTimeout: 2.0,
            maxSegmentDuration: 12.0,
            maxWords: 42,
            maxCharacters: 240
        ))
    }

    @Test func mixedLiveSegmentBoundaryKeepsFreshHypothesisActive() async throws {
        let now = Date()

        #expect(!MixedLiveStreamer.shouldFinalizeSegment(
            text: "Okej, testuję aplikację.",
            segmentStartedAt: now.addingTimeInterval(-0.5),
            lastPartialUpdate: now.addingTimeInterval(-0.1),
            lastVoiceActivity: now.addingTimeInterval(-0.1),
            now: now,
            silenceTimeout: 1.1,
            partialTimeout: 2.0,
            maxSegmentDuration: 12.0,
            maxWords: 42,
            maxCharacters: 240
        ))
    }

    @Test func mixedLiveSegmentBoundaryTriggersOnOversizedBubble() async throws {
        let now = Date()
        let text = Array(repeating: "test", count: 43).joined(separator: " ")

        #expect(MixedLiveStreamer.shouldFinalizeSegment(
            text: text,
            segmentStartedAt: now,
            lastPartialUpdate: now,
            lastVoiceActivity: now,
            now: now,
            silenceTimeout: 1.1,
            partialTimeout: 2.0,
            maxSegmentDuration: 12.0,
            maxWords: 42,
            maxCharacters: 240
        ))
    }

}
