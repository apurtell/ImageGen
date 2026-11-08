import Testing

#if os(iOS)
import UIKit
#endif

@testable import ImageGen

@Suite(.tags(.pure))
struct NavigationLayoutTests {
  @Test func iPadSplitsOnlyAtRegularWidth() {
    #expect(NavigationLayout.choose(isPad: true, isRegularWidth: true) == .split)
    #expect(NavigationLayout.choose(isPad: true, isRegularWidth: false) == .stack)
  }

  @Test func iPhoneNeverSplitsEvenAtRegularWidth() {
    #expect(NavigationLayout.choose(isPad: false, isRegularWidth: true) == .stack)
    #expect(NavigationLayout.choose(isPad: false, isRegularWidth: false) == .stack)
  }

  #if os(iOS)
  @MainActor
  @Test func deviceAnswersFollowTheDevice() {
    let isPad = UIDevice.current.userInterfaceIdiom == .pad
    #expect(Platform.isPad == isPad)
    #expect(Platform.deviceNoun == (isPad ? "iPad" : "iPhone"))
    #expect(Platform.keepsUnsentChats == isPad)
    #expect(Platform.sharpensLargeReplyImages == isPad)
    #expect(Platform.interruptedRequestMessage.hasPrefix(isPad ? "iPadOS stopped" : "iOS stopped"))
  }
  #endif
}
