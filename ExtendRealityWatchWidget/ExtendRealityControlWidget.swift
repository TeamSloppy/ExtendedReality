import SwiftUI
import WidgetKit

private struct ControlEntry: TimelineEntry {
    let date: Date
}

private struct ControlProvider: TimelineProvider {
    func placeholder(in context: Context) -> ControlEntry {
        ControlEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (ControlEntry) -> Void) {
        completion(ControlEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ControlEntry>) -> Void) {
        completion(Timeline(entries: [ControlEntry(date: .now)], policy: .never))
    }
}

private struct ControlComplicationView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .containerBackground(for: .widget) {
                Color.black
            }
            .widgetURL(URL(string: "extendreality://control"))
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryInline:
            Label("ExtendReality", systemImage: "viewfinder")

        case .accessoryRectangular:
            HStack(spacing: 8) {
                Image(systemName: "viewfinder")
                    .font(.title2)
                    .widgetAccentable()

                VStack(alignment: .leading, spacing: 1) {
                    Text("ExtendReality")
                        .font(.headline)
                    Text("Open controls")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

        case .accessoryCorner:
            Image(systemName: "viewfinder")
                .font(.title3)
                .widgetAccentable()
                .widgetLabel {
                    Text("Control")
                }

        default:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "viewfinder")
                    .font(.title2.weight(.semibold))
                    .widgetAccentable()
            }
        }
    }
}

private struct ExtendRealityControlWidget: Widget {
    let kind = "ExtendRealityControl"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ControlProvider()) { _ in
            ControlComplicationView()
        }
        .configurationDisplayName("ExtendReality Control")
        .description("Open ExtendReality controls from your watch face.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryCorner,
            .accessoryRectangular,
            .accessoryInline,
        ])
    }
}

@main
struct ExtendRealityWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        ExtendRealityControlWidget()
    }
}
