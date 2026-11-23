import SwiftUI

/// One verification-code row: the live code and a countdown ring. Tapping the row
/// copies the current code; the trailing button opens the entry's details.
struct MobileCodeRow: View {
  @EnvironmentObject private var store: MobileVaultStore
  let item: VaultItem
  @State private var code = ""
  @State private var remaining = 0.0

  private var period: Double { max(item.number("period", fallback: 30), 1) }

  var body: some View {
    HStack(spacing: 12) {
      Button {
        guard !code.isEmpty else { return }
        store.copy(code)
      } label: {
        HStack(spacing: 12) {
          VStack(alignment: .leading, spacing: 4) {
            Text(item.title.isEmpty ? store.t("未命名", "Untitled") : item.title)
              .font(.subheadline.weight(.medium)).lineLimit(1)
            Text(Self.grouped(code))
              .font(.system(size: 26, weight: .medium, design: .monospaced))
              .foregroundStyle(remaining <= 5 ? Color.orange : Color.primary)
          }
          Spacer(minLength: 8)
          ZStack {
            Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 3)
            Circle().trim(from: 0, to: remaining / period)
              .stroke(remaining <= 5 ? Color.orange : Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
              .rotationEffect(.degrees(-90))
            Text("\(Int(remaining.rounded(.up)))").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
          }
          .frame(width: 28, height: 28)
          .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(item.title.isEmpty ? store.t("未命名", "Untitled") : item.title)
      .accessibilityValue(code)
      .accessibilityHint(store.t("点按复制验证码", "Tap to copy the code"))
      .accessibilityAddTraits(.isButton)
      .accessibilityIdentifier("code.row")
      NavigationLink {
        MobileEntryDetail(id: item.id)
      } label: {
        EmptyView()
      }
      .frame(width: 12)
      .accessibilityLabel(store.t("查看详情", "Details"))
    }
    .padding(.vertical, 6)
    .task(id: item) {
      while !Task.isCancelled {
        let now = Date().timeIntervalSince1970
        remaining = period - now.truncatingRemainder(dividingBy: period)
        code =
          (try? await store.perform(CoreRequest.totp(secret: item.string("secret"), time: now.rounded(.down), period: period)).object["code"]?.string) ?? ""
        do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { break }
      }
    }
  }

  /// The time step after the current one: the request time for the next code and the whole
  /// seconds until it applies.
  static func nextWindow(now: Double, period: Double) -> (time: Double, remaining: Int) {
    let step = max(period.rounded(.down), 1)
    let start = (now / step).rounded(.down) * step
    return (start + step, Int((start + step - now).rounded(.up)))
  }

  /// "123456" → "123 456" for readability; other lengths are left as they are.
  static func grouped(_ code: String) -> String {
    guard !code.isEmpty else { return "——— ———" }
    guard code.count % 2 == 0, code.count >= 6 else { return code }
    let middle = code.index(code.startIndex, offsetBy: code.count / 2)
    return String(code[..<middle]) + " " + String(code[middle...])
  }
}
