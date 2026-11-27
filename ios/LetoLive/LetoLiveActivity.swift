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

/// Même groupe que l'app (Signing & Capabilities › App Groups)
let letoDefaults = UserDefaults(suiteName: "group.ci.leto.leto")!
/// Orange de la charte VITE (#E86A17)
let viteOrange = Color(red: 0.910, green: 0.416, blue: 0.090)

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

/// Temps restant avant l'arrivée : le compte à rebours tourne seul, même sans mise à jour de l'app
struct LetoEta: View {
  let eta: Date?
  var body: some View {
    if let eta {
      Text(timerInterval: Date()...eta, countsDown: true)
        .monospacedDigit()
        .multilineTextAlignment(.trailing)
    } else {
      Image(systemName: "scooter")
    }
  }
}

/// Avancement : arrêts livrés sur le total (tournée), sinon rien
struct LetoProgress: View {
  let v: LetoLiveValues
  var body: some View {
    if v.total > 0 {
      VStack(alignment: .leading, spacing: 4) {
        ProgressView(value: Double(min(v.done, v.total)), total: Double(max(v.total, 1)))
          .tint(viteOrange)
        if v.total > 1 {
          Text("\(v.done)/\(v.total) arrêts livrés").font(.caption2).foregroundStyle(.white.opacity(0.6))
        }
      }
    }
  }
}

struct LetoLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: LiveActivitiesAppAttributes.self) { context in
      // Écran verrouillé : titre en couleur, adresse, temps restant en grand, avancement
      let v = LetoLiveValues(context.attributes)
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 2) {
            Text(v.title).font(.headline).foregroundStyle(viteOrange).lineLimit(1)
            if !v.subtitle.isEmpty {
              Text(v.subtitle).font(.subheadline).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
            }
          }
          Spacer()
          LetoEta(eta: v.eta)
            .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(.white)
        }
        LetoProgress(v: v)
      }
      .padding(16)
      .activityBackgroundTint(Color.black.opacity(0.75))
      .activitySystemActionForegroundColor(.white)
    } dynamicIsland: { context in
      let v = LetoLiveValues(context.attributes)
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Label("VITE", systemImage: "scooter")
            .font(.caption.weight(.semibold))
            .foregroundStyle(viteOrange)
        }
        DynamicIslandExpandedRegion(.trailing) {
          LetoEta(eta: v.eta).font(.title3.monospacedDigit().weight(.semibold))
        }
        DynamicIslandExpandedRegion(.bottom) {
          VStack(alignment: .leading, spacing: 6) {
            Text(v.title).font(.subheadline.weight(.semibold)).lineLimit(1)
            if !v.subtitle.isEmpty {
              Text(v.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            LetoProgress(v: v)
          }
        }
      } compactLeading: {
        Image(systemName: "scooter").foregroundStyle(viteOrange)
      } compactTrailing: {
        LetoEta(eta: v.eta).frame(maxWidth: 64)
      } minimal: {
        Image(systemName: "scooter").foregroundStyle(viteOrange)
      }
    }
  }
}

@main
struct LetoLiveBundle: WidgetBundle {
  var body: some Widget { LetoLiveActivity() }
}
