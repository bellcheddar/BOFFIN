//  AnnotationCanvas.swift
//  BOFFIN
//
//  Pencil annotation over a presented scene.
//
//  The case for it is the room, not the app. Explaining a structure to people
//  means pointing at it, and pointing at a projected image from across a room
//  is done with a laser pointer that leaves no record. Drawing on the slide
//  with a Pencil circles the pocket, marks the mutation, and the mark is still
//  there when the deck is sent to whoever asked for it afterwards.
//
//  Two decisions worth stating.
//
//  **Strokes, not a bitmap.** PencilKit's own serialised form is kept rather
//  than a rendered image, so an annotation redraws at the display's resolution
//  (a phone in the hand, a projector across a hall) and can still be edited. A
//  flattened bitmap can do neither, and the flattening is not reversible.
//
//  **Anchored to the scene's identity, not its position.** See
//  `SceneDeckModel.annotations`: an index is renumbered by reordering or
//  deleting, so an annotation keyed by position slides onto a different slide
//  and looks perfectly deliberate on the wrong structure.

import PencilKit
import SwiftUI

struct AnnotationCanvas: UIViewRepresentable {
    /// The stored drawing, read on the way in and written on every change.
    @Binding var drawing: Data
    /// Whether the canvas takes input. When false it still DRAWS, so an
    /// annotation stays visible while the structure underneath is rotated.
    let isActive: Bool

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        // Finger as well as Pencil. Not every iPad in a meeting room has a
        // Pencil to hand, and a feature that silently does nothing without an
        // accessory reads as a broken feature.
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.pen, color: .systemYellow, width: 6)
        canvas.delegate = context.coordinator
        canvas.accessibilityIdentifier = "boffin.annotation.canvas"
        // The strokes are not readable content and the scroll view underneath
        // is not navigable content. Publishing neither keeps the tree small.
        canvas.isAccessibilityElement = false
        canvas.accessibilityElementsHidden = true
        apply(drawing, to: canvas)
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        // Only touch the canvas when the stored drawing genuinely differs from
        // what it already holds. Assigning unconditionally resets the in-flight
        // stroke on every SwiftUI update, which shows up as ink disappearing
        // mid-line and reads as a hardware fault rather than a bug.
        let existing = canvas.drawing.dataRepresentation()
        if existing != drawing { apply(drawing, to: canvas) }

        canvas.isUserInteractionEnabled = isActive
        context.coordinator.isRecording = isActive
    }

    private func apply(_ data: Data, to canvas: PKCanvasView) {
        if data.isEmpty {
            canvas.drawing = PKDrawing()
        } else if let restored = try? PKDrawing(data: data) {
            canvas.drawing = restored
        } else {
            // Unreadable stored data is dropped rather than crashing the
            // presentation. A lost annotation in front of a room is a
            // disappointment; a crash is the end of the talk.
            canvas.drawing = PKDrawing()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        private let parent: AnnotationCanvas
        var isRecording: Bool = false

        init(_ parent: AnnotationCanvas) {
            self.parent = parent
            self.isRecording = parent.isActive
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            // Write back even when the drawing became empty: rubbing an
            // annotation out is a change the deck has to hear about, or the old
            // strokes reappear the next time the scene is shown.
            parent.drawing =
                canvasView.drawing.strokes.isEmpty
                ? Data() : canvasView.drawing.dataRepresentation()
        }
    }
}

extension AnnotationCanvas {

    /// Render stored strokes for display when the canvas is not live.
    ///
    /// The strokes stay the stored form; this is a view of them, not a second
    /// copy. Rendering on demand is what lets the live `PKCanvasView` exist
    /// only while someone is actually drawing, which is the difference between
    /// an accessibility tree a test can walk and one it times out on.
    ///
    /// - Returns: `nil` for empty or unreadable data, so a missing annotation
    ///   and a corrupt one both draw nothing rather than drawing a blank box
    ///   over the structure.
    static func render(_ data: Data, scale: CGFloat = 2) -> UIImage? {
        guard !data.isEmpty, let drawing = try? PKDrawing(data: data) else { return nil }
        let bounds = drawing.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        return drawing.image(from: bounds, scale: scale)
    }
}
