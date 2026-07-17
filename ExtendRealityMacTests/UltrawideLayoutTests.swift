import CoreGraphics
import Testing
@testable import ExtendRealityMac

struct UltrawideLayoutTests {
    @Test
    func preservesTwoFullHDDisplaysWithinCanvasLimit() {
        let size = UltrawideLayout.canvasSize(for: [
            CGSize(width: 1_920, height: 1_080),
            CGSize(width: 1_920, height: 1_080),
        ])

        #expect(size == CGSize(width: 3_840, height: 1_080))
    }

    @Test
    func scalesLargeCanvasToMaximumWidth() {
        let size = UltrawideLayout.canvasSize(for: [
            CGSize(width: 3_840, height: 2_160),
            CGSize(width: 3_840, height: 2_160),
        ])

        #expect(size == CGSize(width: 5_120, height: 1_440))
    }

    @Test
    func emptySelectionProducesEmptyCanvas() {
        #expect(UltrawideLayout.canvasSize(for: []) == .zero)
    }
}
