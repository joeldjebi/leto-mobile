import ActivityKit
import SwiftUI
import WidgetKit

// Données envoyées par l'app Flutter (plugin live_activities) — le nom doit rester EXACTEMENT celui-ci
struct LiveActivitiesAppAttributes: ActivityAttributes, Identifiable {
  public typealias LiveDeliveryData = ContentState
  public struct ContentState: Codable, Hashable {}
  var id = UUID()
}

extension LiveActivitiesAppAttributes {
  func prefixedKey(_ key: String) -> String { "\(id)_\(key)" }
}

/// Même groupe que l'app (Xcode › Signing & Capabilities › App Groups)
let letoDefaults = UserDefaults(suiteName: "group.ci.leto.leto")!
let letoViolet = Color(red: 0.910, green: 0.416, blue: 0.090) // orange vif de la charte (#E86A17)

/// Valeurs lues pour une Live Activity
struct LetoLiveValues {
  let title: String
  let subtitle: String
  let done: Int
  let total: Int
  let eta: Date?

  init(_ a: LiveActivitiesAppAttributes) {
    title = letoDefaults.string(forKey: a.prefixedKey("title")) ?? "Course VITE"
    subtitle = letoDefaults.string(forKey: a.prefixedKey("subtitle")) ?? ""
    done = letoDefaults.integer(forKey: a.prefixedKey("done"))
    total = letoDefaults.integer(forKey: a.prefixedKey("total"))
    let epoch = letoDefaults.double(forKey: a.prefixedKey("etaEpoch"))
    eta = epoch > Date().timeIntervalSince1970 ? Date(timeIntervalSince1970: epoch) : nil
  }
}

/// Heure d'arrivée : compte à rebours qui continue même sans mise à jour de l'app
struct LetoEta: View {
  let eta: Date?
  var body: some View {
    if let eta {
      Text(timerInterval: Date()...eta, countsDown: true)
        .monospacedDigit()
        .multilineTextAlignment(.trailing)
    } else {
      Text("—")
    }
  }
}

struct LetoLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: LiveActivitiesAppAttributes.self) { context in
      // Écran verrouillé
      let v = LetoLiveValues(context.attributes)
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("VITE").font(.caption.weight(.heavy)).foregroundColor(letoViolet)
          Spacer()
          if v.eta != nil {
            Label { LetoEta(eta: v.eta).font(.headline) } icon: { Image(systemName: "clock.fill") }
              .foregroundColor(.white)
          }
        }
        Text(v.title).font(.headline).foregroundColor(.white)
        if !v.subtitle.isEmpty {
          Text(v.subtitle).font(.subheadline).foregroundColor(.white.opacity(0.75)).lineLimit(1)
        }
        if v.total > 0 {
          ProgressView(value: Double(v.done), total: Double(max(v.total, 1)))
            .tint(letoViolet)
          Text("\(v.done)/\(v.total) arrêt(s)").font(.caption).foregroundColor(.white.opacity(0.7))
        }
      }
      .padding(16)
      .activityBackgroundTint(Color(red: 0.07, green: 0.07, blue: 0.08))
      .activitySystemActionForegroundColor(.white)
    } dynamicIsland: { context in
      let v = LetoLiveValues(context.attributes)
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Image(systemName: "shippingbox.fill").foregroundColor(letoViolet).font(.title2)
        }
        DynamicIslandExpandedRegion(.trailing) {
          LetoEta(eta: v.eta).font(.headline)
        }
        DynamicIslandExpandedRegion(.bottom) {
          VStack(alignment: .leading, spacing: 4) {
            Text(v.title).font(.headline)
            if !v.subtitle.isEmpty { Text(v.subtitle).font(.caption).foregroundColor(.secondary).lineLimit(1) }
            if v.total > 0 {
              ProgressView(value: Double(v.done), total: Double(max(v.total, 1))).tint(letoViolet)
            }
          }
        }
      } compactLeading: {
        Image(systemName: "shippingbox.fill").foregroundColor(letoViolet)
      } compactTrailing: {
        LetoEta(eta: v.eta).frame(maxWidth: 52)
      } minimal: {
        Image(systemName: "shippingbox.fill").foregroundColor(letoViolet)
      }
    }
  }
}

@main
struct LetoLiveBundle: WidgetBundle {
  var body: some Widget { LetoLiveActivity() }
}
