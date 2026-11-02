import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Goblin

@Test
@MainActor
func avatarLibraryPersistsImportsInRelativeCatalog() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let libraryDirectory = root.appendingPathComponent("Avatar Library", isDirectory: true)
    let sourceURL = root.appendingPathComponent("source.png")
    let sourceImage = try makeTestImage(width: 80, height: 60, transparentRightHalf: false)
    try writeTestPNG(sourceImage, to: sourceURL)

    let firstLibrary = AvatarLibrary(directory: libraryDirectory)
    let imported = try firstLibrary.importImage(at: sourceURL, name: "Custom Goblin")

    #expect(UUID(uuidString: imported.id) != nil)
    #expect(imported.name == "Custom Goblin")
    #expect(imported.file == "images/" + imported.id + ".png")
    #expect(imported.standingFile == imported.file)

    let secondLibrary = AvatarLibrary(directory: libraryDirectory)
    let reloadedAvatars = try secondLibrary.avatars()
    #expect(reloadedAvatars.count == 1)
    let reloaded = try #require(reloadedAvatars.first)
    #expect(reloaded.id == imported.id)
    #expect(reloaded.name == "Custom Goblin")
    #expect(reloaded.file == imported.file)

    let firstImageURL = try firstLibrary.imageURL(for: imported)
    let secondImageURL = try secondLibrary.imageURL(for: reloaded)
    #expect(firstImageURL.standardizedFileURL == secondImageURL.standardizedFileURL)
    #expect(FileManager.default.fileExists(atPath: secondImageURL.path))

    let catalogURL = libraryDirectory.appendingPathComponent("catalog.json")
    let catalogData = try Data(contentsOf: catalogURL)
    let catalogText = String(decoding: catalogData, as: UTF8.self)
    #expect(catalogText.contains("images/" + imported.id + ".png"))
    #expect(!catalogText.contains(root.path))
}

@Test
@MainActor
func importPreservesAlphaTransparency() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let sourceURL = root.appendingPathComponent("transparent-source.png")
    let sourceImage = try makeTestImage(width: 80, height: 40, transparentRightHalf: true)
    try writeTestPNG(sourceImage, to: sourceURL)

    let library = AvatarLibrary(directory: root.appendingPathComponent("Library", isDirectory: true))
    let avatar = try library.importImage(at: sourceURL)
    let outputURL = try library.imageURL(for: avatar)
    let outputImage = try loadTestImage(at: outputURL)

    #expect(outputImage.width == 80)
    #expect(outputImage.height == 40)
    #expect(outputImage.alphaInfo == .last
            || outputImage.alphaInfo == .premultipliedLast
            || outputImage.alphaInfo == .first
            || outputImage.alphaInfo == .premultipliedFirst)

    let leftAlpha = try alphaComponent(of: outputImage, x: 5, y: 20)
    let rightAlpha = try alphaComponent(of: outputImage, x: 75, y: 20)
    #expect(leftAlpha == 255)
    #expect(rightAlpha == 0)
}

@Test
@MainActor
func importStripsSourceMetadata() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let sourceURL = root.appendingPathComponent("tagged-source.png")
    let sourceImage = try makeTestImage(width: 60, height: 60, transparentRightHalf: false)
    let sourceMetadata: [CFString: Any] = [
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "PRIVATE-AVATAR-MARKER"],
        kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: "PRIVATE-AVATAR-DESCRIPTION"]
    ]
    try writeTestPNG(sourceImage, to: sourceURL, metadata: sourceMetadata)

    let sourceData = try Data(contentsOf: sourceURL)
    let sourceText = String(decoding: sourceData, as: UTF8.self)
    #expect(sourceText.contains("PRIVATE-AVATAR-MARKER"))

    let library = AvatarLibrary(directory: root.appendingPathComponent("Library", isDirectory: true))
    let avatar = try library.importImage(at: sourceURL)
    let outputURL = try library.imageURL(for: avatar)

    let outputData = try Data(contentsOf: outputURL)
    let outputText = String(decoding: outputData, as: UTF8.self)
    #expect(!outputText.contains("PRIVATE-AVATAR-MARKER"))
    #expect(!outputText.contains("PRIVATE-AVATAR-DESCRIPTION"))

    guard let outputSource = CGImageSourceCreateWithURL(outputURL as CFURL, nil) else {
        Issue.record("Could not inspect the normalized avatar PNG.")
        return
    }
    let properties = CGImageSourceCopyPropertiesAtIndex(outputSource, 0, nil) as? [CFString: Any] ?? [:]
    let exifProperties = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
    #expect(exifProperties[kCGImagePropertyExifUserComment] == nil)
}

@Test
@MainActor
func importRejectsFilesThatAreNotImages() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let libraryDirectory = root.appendingPathComponent("Library", isDirectory: true)
    let textURL = root.appendingPathComponent("notes.txt")
    try Data("This is not an image.".utf8).write(to: textURL)

    let library = AvatarLibrary(directory: libraryDirectory)
    #expect(throws: GoblinError.self) {
        _ = try library.importImage(at: textURL)
    }
    #expect(throws: GoblinError.self) {
        _ = try library.importImage(at: root.appendingPathComponent("missing.png"))
    }

    let avatars = try library.avatars()
    #expect(avatars.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: libraryDirectory.appendingPathComponent("images").path))
}

@Test
@MainActor
func catalogRejectsPathTraversal() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let libraryDirectory = root.appendingPathComponent("Library", isDirectory: true)
    try FileManager.default.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)

    let outsideURL = root.appendingPathComponent("outside.png")
    let outsideImage = try makeTestImage(width: 10, height: 10, transparentRightHalf: false)
    try writeTestPNG(outsideImage, to: outsideURL)

    let identifier = UUID().uuidString.lowercased()
    let catalog = """
    {
      "version": 1,
      "avatars": [
        {
          "id": "\(identifier)",
          "name": "Escape",
          "file": "../outside.png",
          "standingFile": "../outside.png"
        }
      ]
    }
    """
    let catalogURL = libraryDirectory.appendingPathComponent("catalog.json")
    try Data(catalog.utf8).write(to: catalogURL)

    let library = AvatarLibrary(directory: libraryDirectory)
    #expect(throws: GoblinError.self) {
        _ = try library.avatars()
    }
}

@Test
@MainActor
func imageURLRejectsImageSymlinkedOutsideLibrary() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let libraryDirectory = root.appendingPathComponent("Library", isDirectory: true)
    let sourceURL = root.appendingPathComponent("source.png")
    let sourceImage = try makeTestImage(width: 40, height: 40, transparentRightHalf: false)
    try writeTestPNG(sourceImage, to: sourceURL)

    let library = AvatarLibrary(directory: libraryDirectory)
    let avatar = try library.importImage(at: sourceURL)
    let imageURL = try library.imageURL(for: avatar)

    let outsideURL = root.appendingPathComponent("outside.png")
    let outsideImage = try makeTestImage(width: 20, height: 20, transparentRightHalf: false)
    try writeTestPNG(outsideImage, to: outsideURL)

    try FileManager.default.removeItem(at: imageURL)
    try FileManager.default.createSymbolicLink(at: imageURL, withDestinationURL: outsideURL)

    #expect(throws: GoblinError.self) {
        _ = try library.imageURL(for: avatar)
    }
    #expect(throws: GoblinError.self) {
        _ = try library.avatars()
    }
}

@Test
@MainActor
func importRefusesSymlinkedImagesFolder() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let libraryDirectory = root.appendingPathComponent("Library", isDirectory: true)
    try FileManager.default.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
    let outsideDirectory = root.appendingPathComponent("Outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)

    let imagesLink = libraryDirectory.appendingPathComponent("images", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: imagesLink, withDestinationURL: outsideDirectory)

    let sourceURL = root.appendingPathComponent("source.png")
    let sourceImage = try makeTestImage(width: 30, height: 30, transparentRightHalf: false)
    try writeTestPNG(sourceImage, to: sourceURL)

    let library = AvatarLibrary(directory: libraryDirectory)
    #expect(throws: GoblinError.self) {
        _ = try library.importImage(at: sourceURL)
    }

    let outsideContents = try FileManager.default.contentsOfDirectory(atPath: outsideDirectory.path)
    #expect(outsideContents.isEmpty)
    let avatars = try library.avatars()
    #expect(avatars.isEmpty)
}

@Test
@MainActor
func importedAvatarDoesNotRetainSourceLocation() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let sourceDirectory = root.appendingPathComponent("Chosen Source Folder", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    let sourceURL = sourceDirectory.appendingPathComponent("portrait.png")
    let sourceImage = try makeTestImage(width: 50, height: 50, transparentRightHalf: false)
    try writeTestPNG(sourceImage, to: sourceURL)

    let libraryDirectory = root.appendingPathComponent("Library", isDirectory: true)
    let library = AvatarLibrary(directory: libraryDirectory)
    let imported = try library.importImage(at: sourceURL)

    try FileManager.default.removeItem(at: sourceDirectory)

    let reopened = AvatarLibrary(directory: libraryDirectory)
    let avatars = try reopened.avatars()
    let reloaded = try #require(avatars.first)
    #expect(reloaded.id == imported.id)

    let outputURL = try reopened.imageURL(for: reloaded)
    #expect(FileManager.default.fileExists(atPath: outputURL.path))

    let catalogURL = libraryDirectory.appendingPathComponent("catalog.json")
    let catalogData = try Data(contentsOf: catalogURL)
    let catalogText = String(decoding: catalogData, as: UTF8.self)
    #expect(!catalogText.contains(sourceURL.path))
    #expect(!catalogText.contains(sourceDirectory.path))
    #expect(catalogText.contains("images/" + imported.id + ".png"))
}

@Test
@MainActor
func corruptedCatalogThrowsAndIsNotReset() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let libraryDirectory = root.appendingPathComponent("Library", isDirectory: true)
    try FileManager.default.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
    let catalogURL = libraryDirectory.appendingPathComponent("catalog.json")
    let brokenCatalog = "{ this is not valid json"
    try Data(brokenCatalog.utf8).write(to: catalogURL)

    let sourceURL = root.appendingPathComponent("source.png")
    let sourceImage = try makeTestImage(width: 30, height: 30, transparentRightHalf: false)
    try writeTestPNG(sourceImage, to: sourceURL)

    let library = AvatarLibrary(directory: libraryDirectory)
    #expect(throws: GoblinError.self) {
        _ = try library.avatars()
    }
    #expect(throws: GoblinError.self) {
        _ = try library.importImage(at: sourceURL)
    }

    let afterData = try Data(contentsOf: catalogURL)
    let afterText = String(decoding: afterData, as: UTF8.self)
    #expect(afterText == brokenCatalog)
}

@Test
@MainActor
func importAppliesOrientationAndCapsLongestSide() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let orientedURL = root.appendingPathComponent("oriented.jpg")
    let orientedImage = try makeTestImage(width: 40, height: 20, transparentRightHalf: false)
    try writeTestJPEG(orientedImage, to: orientedURL, orientation: 6)

    let largeURL = root.appendingPathComponent("large.png")
    let largeImage = try makeTestImage(width: 2000, height: 1000, transparentRightHalf: false)
    try writeTestPNG(largeImage, to: largeURL)

    let library = AvatarLibrary(directory: root.appendingPathComponent("Library", isDirectory: true))

    let orientedAvatar = try library.importImage(at: orientedURL)
    let orientedSize = try imageDimensions(at: try library.imageURL(for: orientedAvatar))
    #expect(orientedSize.width == 20)
    #expect(orientedSize.height == 40)

    let largeAvatar = try library.importImage(at: largeURL)
    let largeSize = try imageDimensions(at: try library.imageURL(for: largeAvatar))
    #expect(largeSize.width == 1600)
    #expect(largeSize.height == 800)
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("GoblinAvatarLibraryTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func makeTestImage(width: Int, height: Int, transparentRightHalf: Bool) throws -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    guard let context = CGContext(data: nil,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: width * 4,
                                  space: colorSpace,
                                  bitmapInfo: bitmapInfo) else {
        throw GoblinError(message: "Test image context could not be created.")
    }

    context.clear(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 0.15, green: 0.65, blue: 0.35, alpha: 1))
    let opaqueWidth = transparentRightHalf ? width / 2 : width
    context.fill(CGRect(x: 0, y: 0, width: opaqueWidth, height: height))

    guard let image = context.makeImage() else {
        throw GoblinError(message: "Test image could not be created.")
    }
    return image
}

private func writeTestPNG(_ image: CGImage, to url: URL, metadata: [CFString: Any] = [:]) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                            UTType.png.identifier as CFString,
                                                            1,
                                                            nil) else {
        throw GoblinError(message: "Test PNG destination could not be created.")
    }

    if metadata.isEmpty {
        CGImageDestinationAddImage(destination, image, nil)
    } else {
        CGImageDestinationAddImage(destination, image, metadata as CFDictionary)
    }

    guard CGImageDestinationFinalize(destination) else {
        throw GoblinError(message: "Test PNG could not be written.")
    }
}

private func writeTestJPEG(_ image: CGImage, to url: URL, orientation: Int) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                            UTType.jpeg.identifier as CFString,
                                                            1,
                                                            nil) else {
        throw GoblinError(message: "Test JPEG destination could not be created.")
    }

    let properties: [CFString: Any] = [
        kCGImagePropertyOrientation: orientation,
        kCGImageDestinationLossyCompressionQuality: 0.9
    ]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        throw GoblinError(message: "Test JPEG could not be written.")
    }
}

private func loadTestImage(at url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        throw GoblinError(message: "Test image source could not be read.")
    }
    guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw GoblinError(message: "Test image could not be decoded.")
    }
    return image
}

private func imageDimensions(at url: URL) throws -> (width: Int, height: Int) {
    let image = try loadTestImage(at: url)
    return (image.width, image.height)
}

private func alphaComponent(of image: CGImage, x: Int, y: Int) throws -> UInt8 {
    let width = image.width
    let height = image.height
    guard x >= 0, x < width, y >= 0, y < height else {
        throw GoblinError(message: "Test pixel is outside the image.")
    }

    guard let context = CGContext(data: nil,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw GoblinError(message: "Test alpha context could not be created.")
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    guard let data = context.data else {
        throw GoblinError(message: "Test alpha data could not be read.")
    }
    let bytes = data.assumingMemoryBound(to: UInt8.self)
    let offset = (y * width + x) * 4 + 3
    return bytes[offset]
}
