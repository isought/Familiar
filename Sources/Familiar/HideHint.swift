import AppKit
import SwiftUI

/// Small callout shown under the menu bar icon after the bubble is hidden.
@MainActor
final class HideHint {
    private var panel: NSPanel?
    private var dismissWork: DispatchWorkItem?

    func show(under anchor: NSRect, onRestore: @escaping () -> Void) {
        dismiss(animated: false)
        let width: CGFloat = 250, height: CGFloat = 64
        let rect = NSRect(x: anchor.midX - width / 2, y: anchor.minY - height, width: width, height: height)
        let p = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.alphaValue = 0
        p.contentView = NSHostingView(rootView: HideHintView(arrowX: width / 2) { [weak self] in
            onRestore()
            self?.dismiss(animated: true)
        })
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.25; p.animator().alphaValue = 1 }
        panel = p

        let work = DispatchWorkItem { [weak self] in self?.dismiss(animated: true) }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5, execute: work)
    }

    func dismiss(animated: Bool) {
        dismissWork?.cancel()
        dismissWork = nil
        guard let p = panel else { return }
        panel = nil
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.3; p.animator().alphaValue = 0 }, completionHandler: { p.orderOut(nil) })
        } else {
            p.orderOut(nil)
        }
    }
}

private struct HideHintView: View {
    let arrowX: CGFloat
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Triangle().fill(Color(nsColor: .windowBackgroundColor)).frame(width: 16, height: 8)
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Familiar is up here now").font(.callout.weight(.semibold))
                    Text("Click the wand icon to bring it back").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
        }
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

private struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}
