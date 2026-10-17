import Testing

@testable import ImageGen

/// Verifies state transitions and result ownership during background task assertion expiry within the preparation phase.
@Suite(.tags(.pure))
struct PreparationPhaseTests {
  typealias Preparation = GenerationService.Preparation

  @Test func expiryBeforeSendingOwnsTheResult() {
    let p = Preparation()
    #expect(p.claimExpiry())
    #expect(p.expired)
    #expect(!p.claimSending())  // Prevents task dispatch following assertion expiration.
    #expect(!p.claimFinish())   // Suppresses duplicate result emissions from expired preparation contexts.
  }

  @Test func expiryAfterTheTaskStartedIsIgnored() {
    let p = Preparation()
    #expect(p.claimSending())
    #expect(!p.claimExpiry())
    #expect(!p.expired)
    #expect(p.claimFinish())
  }

  @Test func expiryAfterTheWorkFinishedIsIgnored() {
    let p = Preparation()
    #expect(p.claimFinish())
    #expect(!p.claimExpiry())
    #expect(!p.expired)
  }

  @Test func sendingTwiceIsAllowed() {
    let p = Preparation()
    #expect(p.claimSending())
    #expect(p.claimSending())
  }
}
