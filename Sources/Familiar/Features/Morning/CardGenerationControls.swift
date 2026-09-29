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
