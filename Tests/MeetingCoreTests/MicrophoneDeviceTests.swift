import CoreAudio
import Foundation
import Testing
@testable import MeetingCore

@Test func disconnectedMicrophoneDoesNotFallBackToTheDefaultInput() throws {
    let missingUID = "meeting-intelligence.test.\(UUID())"
    #expect(try MicrophoneDevice.resolve(missingUID) == kAudioObjectUnknown)
    #expect(throws: MeetingError.self) { try MicrophoneInput(deviceUID: missingUID) }
}
