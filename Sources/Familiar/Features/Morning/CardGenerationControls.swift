import SwiftUI

struct CardGenerationControls: View {
    @ObservedObject var service: CardGenerationService
    let showCards: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if service.isRunning {
                    ProgressView().controlSize(.small)
                    Text("Updating your cards…").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Button("Stop") { service.stop() }.buttonStyle(.plain)
                } else {
                    Button("Make cards from saved results") { service.generate() }
                        .buttonStyle(.plain).foregroundStyle(Pad.penInk)
                    Spacer()
                }
                Button("View cards", action: showCards).buttonStyle(.plain).foregroundStyle(Pad.penInk)
            }.font(.system(size: 12))
            if let error = service.error {
                Text(error).foregroundStyle(Pad.redInk).textSelection(.enabled).font(.system(size: 11))
            } else if !service.status.isEmpty {
                Text(service.status).foregroundStyle(Pad.inkSoft).font(.system(size: 11)).lineLimit(3)
            }
        }.padding(.horizontal, 18).padding(.vertical, 10).background(Pad.paperTop.opacity(0.45))
    }
}

/// The main screen shows card work in one line, only while cards are being prepared or when preparing them failed.
/// The full controls are on the run screens.
struct CardGenerationStatusLine: View {
    @ObservedObject var service: CardGenerationService
    let openDetails: () -> Void

    var body: some View {
        if service.isRunning || service.error != nil {
            HStack(spacing: 8) {
                if service.isRunning {
                    ProgressView().controlSize(.small)
                    Text("Updating your cards…").font(.system(size: 12, weight: .medium)).layoutPriority(1)
                    if !service.status.isEmpty { Text(service.status).foregroundStyle(Pad.inkSoft).lineLimit(1) }
                    Spacer(minLength: 8)
                    Button("Stop") { service.stop() }.buttonStyle(.plain)
                } else if let error = service.error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Pad.redInk).lineLimit(1).help(error)
                    Spacer(minLength: 8)
                    Button("Details", action: openDetails).buttonStyle(.plain).foregroundStyle(Pad.penInk)
                        .help("Open the latest run to read the whole message and try again")
                }
            }.font(.system(size: 12)).padding(.horizontal, 18).padding(.vertical, 10).background(Pad.paperTop.opacity(0.45))
        }
    }
}
