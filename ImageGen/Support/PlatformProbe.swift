import SwiftData
import SwiftUI
import Synchronization

// Touches the iOS 26 APIs the app depends on, so a missing or renamed one fails the build early
// (risk P8). Nothing uses it. Delete in M9.

private struct PlatformProbeView: View {
  var body: some View {
    GlassEffectContainer {
      Button("Probe") {}
        .buttonStyle(.glassProminent)
        .glassEffect()
    }
    .safeAreaBar(edge: .bottom) { Text("Bar") }
  }
}

private final class PlatformProbeCounter: Sendable {
  private let value = Mutex(0)

  func increment() -> Int {
    value.withLock { v in
      v += 1
      return v
    }
  }
}

@concurrent
private func platformProbeWork(_ n: Int) async -> Int { n * 2 }

@Model
private final class PlatformProbeRecord {
  var name: String
  init(name: String) { self.name = name }
}

@ModelActor
private actor PlatformProbeStore {
  func count() throws -> Int {
    try modelContext.fetchCount(FetchDescriptor<PlatformProbeRecord>())
  }
}
