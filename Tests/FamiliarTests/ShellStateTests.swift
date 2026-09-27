import Combine
import Foundation
import Testing
@testable import Familiar

@Suite @MainActor
struct ShellStateTests {
    @Test
    func quietExpansionIsPublishedAndFocusIntentIsConsumedOnlyOnce() {
        let shell = ShellState()
        var expansions: [Bool] = []
        let observation = shell.$expanded.sink { expansions.append($0) }
        defer { observation.cancel() }

        shell.expandQuietly()
        #expect(expansions == [false, true])
        #expect(shell.consumeQuietExpand())
        #expect(!shell.consumeQuietExpand())

        shell.expanded = false
        shell.expanded = true
        #expect(!shell.consumeQuietExpand())
        #expect(expansions == [false, true, false, true])
    }

    @Test
    func separateShellsDoNotShareGeometryOrPendingFocus() {
        let app = ShellState()
        let preview = ShellState()
        var previewSizes: [NSSize] = []
        let observation = preview.$cardSize.sink { previewSizes.append($0) }
        defer { observation.cancel() }

        app.cardSize = NSSize(width: 560, height: 760)
        app.expandQuietly()

        #expect(preview.cardSize == NSSize(width: 400, height: 540))
        #expect(!preview.expanded)
        #expect(!preview.consumeQuietExpand())
        #expect(app.consumeQuietExpand())

        preview.cardSize = NSSize(width: 430, height: 600)
        #expect(previewSizes == [NSSize(width: 400, height: 540), NSSize(width: 430, height: 600)])
        #expect(app.cardSize == NSSize(width: 560, height: 760))
    }
}
