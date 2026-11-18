import Foundation

/// Awaits a completion-handler API that may never call back (for example
/// `ASCredentialIdentityStore` when the system credential service is unreachable).
/// Returns the handler's value, or `fallback` once `timeout` elapses; a late callback
/// is ignored so the continuation resumes exactly once.
func boundedCompletion<T: Sendable>(
  timeout: TimeInterval, fallback: T, _ start: (@escaping @Sendable (T) -> Void) -> Void
) async -> T {
  let gate = OneShot()
  return await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
    let finish: @Sendable (T) -> Void = { value in
      if gate.claim() { continuation.resume(returning: value) }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(fallback) }
    start(finish)
  }
}

/// A thread-safe flag that lets exactly one caller through.
final class OneShot: @unchecked Sendable {
  private let lock = NSLock()
  private var used = false
  func claim() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if used { return false }
    used = true
    return true
  }
}
