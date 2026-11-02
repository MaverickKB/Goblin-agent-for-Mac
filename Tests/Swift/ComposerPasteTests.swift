import AppKit
import XCTest

@testable import Goblin

final class ComposerPasteTests: XCTestCase {
    private let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="

    private func makeBoard() -> NSPasteboard {
        let name = NSPasteboard.Name("goblin-paste-test-" + UUID().uuidString)
        let board = NSPasteboard(name: name)
        board.clearContents()
        return board
    }

    private func makeDirectory() -> URL {
        return FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    func testPastedPNGBecomesAnAttachmentFile() throws {
        let board = makeBoard()
        let png = try XCTUnwrap(Data(base64Encoded: pngBase64))
        board.setData(png, forType: .png)
        let directory = makeDirectory()
        let urls = ComposerPaste.attachmentURLs(from: board, directory: directory)
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(urls[0].pathExtension, "png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls[0].path))
        XCTAssertEqual(try Data(contentsOf: urls[0]), png)
        XCTAssertTrue(urls[0].lastPathComponent.hasPrefix("Pasted Image "))
    }

    func testPastedTIFFIsConvertedToPNG() throws {
        let board = makeBoard()
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        let image = try XCTUnwrap(bitmap)
        let tiff = try XCTUnwrap(image.representation(using: .tiff, properties: [:]))
        board.setData(tiff, forType: .tiff)
        let urls = ComposerPaste.attachmentURLs(from: board, directory: makeDirectory())
        XCTAssertEqual(urls.count, 1)
        let data = try Data(contentsOf: urls[0])
        let signature: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
        XCTAssertEqual(Array(data.prefix(8)), signature)
    }

    func testPastedFileURLIsAttachedWithoutCopying() throws {
        let board = makeBoard()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try "notes".write(to: file, atomically: true, encoding: .utf8)
        board.writeObjects([file as NSURL])
        let urls = ComposerPaste.attachmentURLs(from: board, directory: makeDirectory())
        XCTAssertEqual(urls, [file])
    }

    func testPastedPlainTextIsNotAnAttachment() {
        let board = makeBoard()
        board.setString("hello", forType: .string)
        let urls = ComposerPaste.attachmentURLs(from: board, directory: makeDirectory())
        XCTAssertEqual(urls, [])
    }

    func testTwoPastesWriteDifferentFiles() throws {
        let directory = makeDirectory()
        let png = try XCTUnwrap(Data(base64Encoded: pngBase64))
        let first = try XCTUnwrap(ComposerPaste.writeImage(png, to: directory))
        let second = try XCTUnwrap(ComposerPaste.writeImage(png, to: directory))
        XCTAssertNotEqual(first, second)
    }

    func testACopyNumberKeepsTheExtension() {
        let name = ComposerPaste.numberedName(base: "Pasted Image 2026-11-02 at 10.12.13.123.png", copyNumber: 2)
        XCTAssertEqual(name, "Pasted Image 2026-11-02 at 10.12.13.123 (2).png")
    }
}
