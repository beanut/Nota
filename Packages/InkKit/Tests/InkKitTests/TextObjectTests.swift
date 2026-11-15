import CoreGraphics
import Foundation
@testable import InkKit
import PDFKit
import Testing
import UIKit

private let red = PenColor(rgb: 0xD93025)

/// A heading, then a checklist with one item ticked, then a nested numbered list.
private func outline() -> RichText {
    let body = TextStyle.standard
    var heading = body
    heading.size = 24
    heading.bold = true
    return RichText(paragraphs: [
        TextParagraph("Groceries", style: heading),
        TextParagraph("Milk", style: body, list: .checkbox),
        TextParagraph("Eggs", style: body, list: .checkbox, checked: true),
        TextParagraph(runs: [TextRun(text: "Bread ", style: body), TextRun(text: "(wholemeal)", style: {
            var s = body
            s.italic = true
            s.color = red
            return s
        }())], list: .numbered, indent: 1)
    ])
}

@MainActor
@Suite("Text objects")
struct TextObjectTests {
    // MARK: Rich text

    @Test func plainTextIsTheParagraphsJoinedByNewlines() {
        #expect(outline().plainText == "Groceries\nMilk\nEggs\nBread (wholemeal)")
        #expect(RichText("").isBlank)
        #expect(RichText(" \n ").isBlank)
        #expect(RichText(paragraphs: []).paragraphs.count == 1) // empty text is one empty paragraph
    }

    @Test func trimmingDropsTrailingBlankParagraphsOnly() {
        let text = RichText("\nOne\n\nTwo\n\n  ")
        #expect(text.trimmed().plainText == "\nOne\n\nTwo")
        #expect(RichText("\n\n").trimmed().paragraphs.count == 1)
    }

    @Test func attributedStringsRoundTripExactly() {
        let text = outline()
        let attributed = text.attributedString()
        #expect(attributed.string == text.plainText)
        #expect(RichText(attributed) == text)
    }

    @Test func emptyParagraphsKeepTheirStyleAndList() {
        var big = TextStyle.standard
        big.size = 40
        let text = RichText(paragraphs: [TextParagraph("A", style: .standard), TextParagraph(style: big, list: .bullet),
                                         TextParagraph("B", style: .standard)])
        #expect(RichText(text.attributedString()) == text)
    }

    @Test func boldAndItalicComeFromTheFontsTraits() {
        // The system's Bold and Italic commands change only the font; the style follows it.
        var attributes = TextStyle.standard.attributes(in: TextParagraphFormat())
        attributes[.font] = UIFont.systemFont(ofSize: 21, weight: .bold)
        let style = TextStyle(attributes: attributes)
        #expect(style.bold)
        #expect(!style.italic)
        #expect(style.size == 21)
        #expect(style.font == .sans)
    }

    @Test func everyFaceMakesAFont() {
        for face in TextFont.allCases {
            for (bold, italic) in [(false, false), (true, false), (false, true), (true, true)] {
                let style = TextStyle(font: face, size: 18, bold: bold, italic: italic)
                let traits = style.uiFont.fontDescriptor.symbolicTraits
                #expect(style.uiFont.pointSize == 18)
                #expect(traits.contains(.traitBold) == bold)
                // A rounded italic doesn't exist; the rest must keep their italic.
                if face != .rounded {
                    #expect(traits.contains(.traitItalic) == italic)
                }
                #expect(TextStyle(attributes: style.attributes(in: TextParagraphFormat())) == style
                    || face == .rounded && italic)
            }
        }
    }

    @Test func sizesAreKeptInRange() {
        #expect(TextStyle(size: 1).size == TextStyle.sizeRange.lowerBound)
        #expect(TextStyle(size: 1000).size == TextStyle.sizeRange.upperBound)
        #expect(TextStyle(size: .nan).size == 17)
    }

    // MARK: Markers

    @Test func numbersCountUpPerLevelAndRestart() {
        func p(_ list: TextList, _ indent: Int, checked: Bool = false) -> TextParagraphFormat {
            TextParagraphFormat(list: list, checked: checked, indent: indent)
        }
        let markers = TextMarker.markers(for: [
            p(.numbered, 0), p(.numbered, 0),
            p(.numbered, 1), p(.numbered, 1), // nested: 1, 2
            p(.numbered, 0), // back out: 3
            p(.numbered, 1), // a new nested list starts again
            p(.bullet, 0), p(.numbered, 0), // a bullet ends the numbering
            p(.none, 0), p(.checkbox, 2, checked: true)
        ])
        #expect(markers == [.number(1), .number(2), .number(1), .number(2), .number(3), .number(1),
                            .bullet(level: 0), .number(1), nil, .checkbox(checked: true)])
    }

    @Test func listParagraphsAreIndentedForTheirMarker() throws {
        let layout = TextLayout(outline(), width: 300)
        let slots = TextLayout.markerSlots(manager: layout.manager, storage: layout.storage, trailing: nil)
        #expect(slots.map(\.marker) == [.checkbox(checked: false), .checkbox(checked: true), .number(1)])
        // Each marker sits in the margin before its paragraph's text, on its first line, in order down the box.
        for slot in slots {
            #expect(slot.box.maxX <= slot.textStart)
        }
        #expect(slots[0].box.minY < slots[1].box.minY)
        #expect(slots[1].box.minY < slots[2].box.minY)
        #expect(try #require(slots.last).textStart > slots[0].textStart) // the nested one is further in
    }

    // MARK: Geometry

    @Test func heightFollowsTheText() {
        let one = TextObject(origin: .zero, width: 300, text: RichText("One line"))
        let three = TextObject(origin: .zero, width: 300, text: RichText("One\nTwo\nThree"))
        let wrapped = TextObject(origin: .zero, width: 60, text: RichText("A rather long line that has to wrap"))
        #expect(one.frame.height > 15)
        #expect(three.frame.height > 2.5 * one.frame.height)
        #expect(wrapped.frame.height > 2.5 * one.frame.height)
        // Empty text is still a line tall, so a new box can be tapped.
        #expect(TextObject(origin: .zero, width: 300, text: RichText("")).frame.height == one.frame.height)
    }

    @Test func movingAndRotatingKeepsTheTextAsItIs() {
        let box = TextObject(origin: CGPoint(x: 50, y: 60), width: 200, text: outline())
        let moved = box.applying(CGAffineTransform(translationX: 30, y: -10))
        #expect(moved.frame == box.frame)
        #expect(moved.bounds.origin == CGPoint(x: 80, y: 50))

        let c = CGPoint(x: 150, y: 100)
        let rotation = CGAffineTransform(translationX: -c.x, y: -c.y).concatenating(CGAffineTransform(rotationAngle: .pi / 6))
            .concatenating(CGAffineTransform(translationX: c.x, y: c.y))
        let rotated = box.applying(rotation)
        #expect(rotated.frame == box.frame)
        #expect(abs(rotated.scale - 1) < 1e-9)
        #expect(abs(atan2(rotated.transform.b, rotated.transform.a) - .pi / 6) < 1e-9)
        let corner = CGPoint(x: 50, y: 60).applying(rotation)
        #expect(rotated.corners[0].distance(to: corner) < 1e-6)
    }

    @Test func resizingRewrapsRatherThanStretching() {
        let box = TextObject(origin: .zero, width: 300, text: RichText("A line long enough to wrap when narrow"))
        // Drag the right edge in to half the width, and the bottom down.
        let narrower = box.applying(CGAffineTransform(scaleX: 0.5, y: 3))
        #expect(narrower.transform.isIdentity)
        #expect(narrower.frame.width == 150)
        #expect(narrower.frame.height > box.frame.height) // it wraps onto more lines
        #expect(narrower.text == box.text)
        // Never narrower than the minimum.
        #expect(box.applying(CGAffineTransform(scaleX: 0.01, y: 1)).frame.width == TextObject.minimumWidth)
    }

    @Test func checkboxesCanBeTicked() throws {
        let box = TextObject(origin: CGPoint(x: 10, y: 10), width: 300, text: outline())
        let targets = box.checkboxTargets()
        #expect(targets.count == 2)
        let milk = try #require(targets.first)
        #expect(milk.location == ("Groceries\n" as NSString).length)
        #expect(box.frame.contains(CGPoint(x: milk.rect.midX, y: milk.rect.midY)))
        let ticked = box.togglingCheckbox(at: milk.location)
        #expect(ticked.text.paragraphs[1].checked)
        #expect(ticked.togglingCheckbox(at: milk.location).text == box.text)
        #expect(box.togglingCheckbox(at: 0) == box) // the heading isn't a checklist item
    }

    @Test func recolouringColoursEveryRun() {
        let box = TextObject(origin: .zero, width: 300, text: outline()).recolored(red)
        #expect(box.text.paragraphs.allSatisfy { $0.runs.allSatisfy { $0.style.color == red } })
    }

    // MARK: Storage

    @Test func textBoxesRoundTripThroughTheObjectsFile() throws {
        let rotation = CGAffineTransform(rotationAngle: 0.3).concatenating(CGAffineTransform(translationX: 20, y: 30))
        let box = TextObject(origin: CGPoint(x: 40, y: 50), width: 280, text: outline(), transform: rotation)
        let file = PageObjectsFile(pageID: UUID(), objects: [box])
        let read = try PageObjectsFile(data: file.encoded())
        let loaded = try #require(read.objects.first as? TextObject)
        #expect(loaded == box)
        #expect(try read.encoded() == file.encoded())
        #expect(read.text == "Groceries\nMilk\nEggs\nBread (wholemeal)")
    }

    @Test func readingIsLenient() throws {
        let json = """
        { "formatVersion": 1, "pageID": "\(UUID().uuidString)", "objects": [
          { "kind": "text", "id": "\(UUID().uuidString)", "frame": { "x": 0, "y": 0, "width": 10, "height": 5 },
            "text": { "paragraphs": [
              { "runs": [ { "text": "Hi", "font": "comic", "size": 9999, "color": "nope", "bold": "yes" } ],
                "alignment": "diagonal", "list": "stars", "indent": 99 },
              { "runs": [] } ] } } ] }
        """
        let read = try PageObjectsFile(data: Data(json.utf8))
        let box = try #require(read.objects.first as? TextObject)
        #expect(box.frame.width == TextObject.minimumWidth)
        let first = box.text.paragraphs[0]
        #expect(first.text == "Hi")
        #expect(first.runs[0].style == TextStyle(size: TextStyle.sizeRange.upperBound))
        #expect(first.alignment == .left)
        #expect(first.list == .none)
        #expect(first.indent == TextParagraph.maxIndent)
        #expect(box.text.paragraphs[1].text.isEmpty)
    }

    @Test func pagesKnowTheirText() {
        let page = CanvasDocument(pageSize: .letter)
        page.addObject(TextObject(origin: .zero, width: 200, text: RichText("First")))
        page.addObject(TextObject(origin: CGPoint(x: 0, y: 100), width: 200, text: RichText("   ")))
        page.addObject(TextObject(origin: CGPoint(x: 0, y: 200), width: 200, text: RichText("Second")))
        #expect(page.text == "First\nSecond")
    }

    // MARK: Drawing and export

    @Test func textIsDrawnOnThePage() throws {
        let page = CanvasDocument(pageSize: .letter)
        page.addObject(TextObject(origin: CGPoint(x: 20, y: 20), width: 400, text: outline()))
        let image = try #require(PageRenderer.image(of: page.snapshot(), pixelWidth: 306))
        #expect(!page.snapshot().isBlank)
        #expect(darkPixels(in: image) > 50)
    }

    @Test func exportedPDFsKeepTextAsText() throws {
        let page = CanvasDocument(pageSize: .letter)
        page.addObject(TextObject(origin: CGPoint(x: 72, y: 72), width: 400, text: outline()))
        let data = try #require(PageRenderer.pdf(of: [page.snapshot()]) { .standard($0) })
        let pdf = try #require(PDFDocument(data: data))
        let text = try #require(pdf.page(at: 0)?.string)
        for word in ["Groceries", "Milk", "Eggs", "Bread", "wholemeal"] {
            #expect(text.contains(word))
        }
    }

    private func darkPixels(in image: CGImage) -> Int {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0 + 3] > 128 && pixels[$0] < 100 }.count
    }
}
