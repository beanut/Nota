import CoreGraphics
import Foundation
@_spi(Testing) @testable import InkKit
import Testing
import UIKit

/// The text tool and editing text boxes on a real `CanvasView`: taps and drags are handed to the canvas
/// as its touch handling would, and typing goes through the editor's text view as the keyboard's would.
@MainActor
@Suite("Canvas text boxes")
struct CanvasTextTests {
    let document = CanvasDocument(pageSize: .letter)
    let controller: CanvasController
    let canvas: CanvasView

    init() throws {
        let suite = "CanvasTextTests.\(UUID().uuidString)"
        controller = try CanvasController(settingsStore: #require(UserDefaults(suiteName: suite)),
                                          penTray: PenTrayStore(fileURL: nil))
        canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 1032, height: 1376), document: document)
        canvas.controller = controller
        controller.canvas = canvas
        canvas.layoutIfNeeded()
        controller.select(.text)
    }

    private var boxes: [TextObject] {
        document.objects.compactMap { $0 as? TextObject }
    }

    private var editor: TextBoxEditor? {
        canvas.textEditor
    }

    /// Types `text` into the box being edited, a character at a time, asking the text view's delegate first
    /// and telling it afterwards as the keyboard does (a text view off screen skips its delegate).
    private func type(_ text: String) {
        guard let editor else { return }
        let view = editor.textView
        for character in text {
            let string = String(character)
            guard editor.textView(view, shouldChangeTextIn: view.selectedRange, replacementText: string) else { continue }
            view.insertText(string)
            editor.textViewDidChange(view)
        }
    }

    private func newBox(at point: CGPoint = CGPoint(x: 100, y: 100)) throws -> TextBoxEditor {
        canvas.handleTextTap(at: point, endedEditing: false)
        return try #require(editor)
    }

    @Test func aTapMakesABoxAndTypingFillsIt() throws {
        let box = try newBox()
        #expect(box.original == nil)
        #expect(controller.textFormat != nil) // the format bar is up
        type("Groceries")
        #expect(document.objectCount == 0) // nothing goes on the page until editing ends
        canvas.endEditingText()
        #expect(controller.textFormat == nil)
        let made = try #require(boxes.first)
        #expect(made.plainText == "Groceries")
        #expect(made.text.leadingStyle == controller.newTextStyle)
        // One undoable edit.
        canvas.undo()
        #expect(document.objectCount == 0)
        canvas.redo()
        #expect(boxes.first?.plainText == "Groceries")
    }

    @Test func aTypedOutlineWithCheckboxes() throws {
        _ = try newBox()
        type("Groceries\n")
        controller.formatText(.list(.checkbox))
        type("Milk\nEggs\n")
        controller.formatText(.indent(1))
        type("Free range\n\n") // Return on an empty item steps out a level
        type("Bread\n\n") // and on an empty top-level item ends the list
        type("Done")
        canvas.endEditingText()
        let paragraphs = try #require(boxes.first).text.paragraphs
        #expect(paragraphs.map(\.text) == ["Groceries", "Milk", "Eggs", "Free range", "Bread", "Done"])
        #expect(paragraphs.map(\.list) == [.none, .checkbox, .checkbox, .checkbox, .checkbox, .none])
        #expect(paragraphs.map(\.indent) == [0, 0, 0, 1, 0, 0])
        #expect(paragraphs.allSatisfy { !$0.checked })
        #expect(document.text == "Groceries\nMilk\nEggs\nFree range\nBread\nDone")
    }

    @Test func formattingTheSelection() throws {
        let plain = controller.newTextStyle
        let box = try newBox()
        type("Hello world")
        box.textView.selectedRange = NSRange(location: 0, length: 5)
        controller.formatText(.bold(true))
        controller.formatText(.size(28))
        controller.formatText(.font(.serif))
        controller.setColor(PenColor(rgb: 0xD93025), for: .text) // the Pen Case's colours recolour it too
        #expect(controller.textFormat?.style.bold == true)
        box.textView.selectedRange = NSRange(location: 11, length: 0)
        controller.formatText(.alignment(.center))
        canvas.endEditingText()
        let paragraph = try #require(boxes.first?.text.paragraphs.first)
        #expect(paragraph.runs.map(\.text) == ["Hello", " world"])
        let hello = paragraph.runs[0].style
        #expect(hello.bold && hello.size == 28 && hello.font == .serif && hello.color == PenColor(rgb: 0xD93025))
        #expect(paragraph.runs[1].style == plain)
        #expect(paragraph.alignment == .center)
    }

    @Test func editingABoxChangesItInPlace() throws {
        let original = TextObject(origin: CGPoint(x: 100, y: 100), width: 300, text: RichText("Draft"))
        document.addObject(original)
        canvas.handleTextTap(at: CGPoint(x: 110, y: 105), endedEditing: false)
        let box = try #require(editor)
        #expect(box.original == original)
        #expect(canvas.objectLayer.objects.isEmpty) // the text view shows it while it's edited
        box.textView.selectedRange = NSRange(location: 5, length: 0)
        type(" two")
        canvas.endEditingText()
        #expect(boxes.map(\.plainText) == ["Draft two"])
        #expect(boxes.first?.id == original.id)
        #expect(boxes.first?.frame.origin == original.frame.origin)
        canvas.undo()
        #expect(boxes.first == original)
    }

    @Test func emptyingABoxRemovesIt() throws {
        document.addObject(TextObject(origin: CGPoint(x: 100, y: 100), width: 300, text: RichText("Gone")))
        canvas.handleTextTap(at: CGPoint(x: 110, y: 105), endedEditing: false)
        let box = try #require(editor)
        box.textView.selectedRange = NSRange(location: 0, length: 4)
        box.textView.deleteBackward()
        canvas.endEditingText()
        #expect(document.objectCount == 0)
        canvas.undo()
        #expect(boxes.map(\.plainText) == ["Gone"])

        // A new box left empty never goes on the page.
        _ = try newBox(at: CGPoint(x: 300, y: 400))
        canvas.endEditingText()
        #expect(document.objectCount == 1)
    }

    @Test func aTapOnACheckboxTicksIt() throws {
        let list = RichText(paragraphs: [TextParagraph("Milk", style: .standard, list: .checkbox)])
        document.addObject(TextObject(origin: CGPoint(x: 100, y: 100), width: 300, text: list))
        let target = try #require(boxes.first?.checkboxTargets().first)
        canvas.handleTextTap(at: CGPoint(x: target.rect.midX, y: target.rect.midY), endedEditing: false)
        #expect(editor == nil) // ticked without opening the box
        #expect(boxes.first?.text.paragraphs[0].checked == true)
        canvas.undo()
        #expect(boxes.first?.text.paragraphs[0].checked == false)
    }

    @Test func aTapAwayOnlyFinishesEditing() throws {
        _ = try newBox()
        type("One")
        // The tap that finishes a box doesn't start another.
        let wasEditing = editor != nil
        canvas.endEditingText()
        canvas.handleTextTap(at: CGPoint(x: 300, y: 600), endedEditing: wasEditing)
        #expect(editor == nil)
        #expect(document.objectCount == 1)
    }

    @Test func draggingSetsTheWidth() throws {
        canvas.beginTextGesture(at: CGPoint(x: 100, y: 200))
        canvas.updateTextGesture(to: CGPoint(x: 400, y: 230))
        canvas.finishTextGesture(commit: true)
        let box = try #require(editor)
        #expect(box.object.frame.origin == CGPoint(x: 100, y: 200))
        #expect(box.object.frame.width == 300)
    }

    @Test func switchingToolsFinishesEditing() throws {
        _ = try newBox()
        type("Kept")
        controller.select(.pen)
        #expect(editor == nil)
        #expect(boxes.map(\.plainText) == ["Kept"])
    }

    @Test func theBoxGrowsAsLinesAreAdded() throws {
        let box = try newBox()
        let oneLine = box.object.frame.height
        type("One\nTwo\nThree")
        #expect(box.object.frame.height > 2.5 * oneLine)
        #expect(box.textView.bounds.height == box.object.frame.height)
    }

    @Test func movedWithTheLassoTheTextKeepsItsSize() throws {
        let original = TextObject(origin: CGPoint(x: 100, y: 100), width: 300, text: RichText("Some text to move"))
        document.addObject(original)
        document.transformForTesting(objectIDs: [original.id], by: CGAffineTransform(scaleX: 0.5, y: 2))
        let resized = try #require(boxes.first)
        #expect(resized.frame.width == 150)
        #expect(resized.scale == 1)
        #expect(resized.text == original.text)
    }
}
