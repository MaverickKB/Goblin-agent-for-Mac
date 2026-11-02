import AppKit
import SwiftUI

@MainActor
final class WindowDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}

struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragView {
        let view = WindowDragView()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel("Move Goblin window")
        view.setAccessibilityHelp("Drag this part of the header to move the window between displays.")
        view.setAccessibilityIdentifier("window-drag-region")
        return view
    }

    func updateNSView(_ view: WindowDragView, context: Context) {}
}

enum WindowPlacement {
    static func fitted(_ frame: NSRect, screens: [NSRect]) -> NSRect {
        guard var chosen = screens.first else { return frame }
        var greatestArea: CGFloat = -1
        var shortestDistance = CGFloat.greatestFiniteMagnitude
        for screen in screens {
            let intersection = frame.intersection(screen)
            let area = intersection.isNull ? 0 : intersection.width * intersection.height
            let nearestX = min(max(frame.midX, screen.minX), screen.maxX)
            let nearestY = min(max(frame.midY, screen.minY), screen.maxY)
            let deltaX = frame.midX - nearestX
            let deltaY = frame.midY - nearestY
            let distance = deltaX * deltaX + deltaY * deltaY
            if area > greatestArea || (area == greatestArea && distance < shortestDistance) {
                chosen = screen
                greatestArea = area
                shortestDistance = distance
            }
        }
        var result = frame
        result.origin.x = max(chosen.minX, min(frame.minX, chosen.maxX - frame.width))
        if frame.height > chosen.height {
            result.origin.y = chosen.maxY - frame.height
        } else {
            result.origin.y = max(chosen.minY, min(frame.minY, chosen.maxY - frame.height))
        }
        return result
    }
}
