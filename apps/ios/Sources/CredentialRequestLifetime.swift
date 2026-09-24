import Foundation

/// Shared by the provider and race tests. A cancellation is itself a new generation.
@MainActor
final class CredentialRequestLifetime {
  private var generation: UInt64 = 0
  @discardableResult func advance() -> UInt64 {
    generation &+= 1
    return generation
  }
  func isCurrent(_ token: UInt64) -> Bool { token == generation }
}
