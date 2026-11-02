import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An app-owned library of custom avatar images.
///
/// The library owns every file it writes. Imported images become
/// metadata-free PNGs inside `images/`, and `catalog.json` stores only
/// relative filenames and display names. The source file is never referenced
/// again after the import finishes.
@MainActor
final class AvatarLibrary {
    private static let catalogVersion = 1
    private static let catalogFileName = "catalog.json"
    private static let imagesDirectoryName = "images"
    private static let imageFileExtension = "png"
    private static let maximumPixelSize = 1600
    private static let maximumNameLength = 80

    private let directory: URL
    private let fileManager: FileManager

    init(directory: URL) {
        self.directory = directory.standardizedFileURL
        self.fileManager = FileManager.default
    }

    private var catalogURL: URL {
        return directory.appendingPathComponent(Self.catalogFileName)
    }

    private var imagesDirectory: URL {
        return directory.appendingPathComponent(Self.imagesDirectoryName, isDirectory: true)
    }

    /// Returns every imported avatar in catalog order.
    func avatars() throws -> [Avatar] {
        let catalog = try loadCatalog()
        var avatars: [Avatar] = []
        for record in catalog.avatars {
            let avatar = Avatar(id: record.id,
                                name: record.name,
                                file: record.file,
                                standingFile: record.standingFile)
            avatars.append(avatar)
        }
        return avatars
    }

    /// Copies an image into the library and records it in the catalog.
    ///
    /// The image is decoded with ImageIO, rotated upright, limited to 1600
    /// pixels on its longest side, and re-encoded as PNG. Re-encoding from the
    /// decoded pixels writes no source metadata. When a name is not supplied,
    /// the source filename stem is used as a display label only.
    func importImage(at source: URL, name: String? = nil) throws -> Avatar {
        try validateSourceFile(source)

        // Read before writing so a corrupted catalog is never overwritten.
        let existingCatalog = try loadCatalog()

        let identifier = UUID().uuidString.lowercased()
        let relativeFile = Self.imagesDirectoryName + "/" + identifier + "." + Self.imageFileExtension
        let destinationURL = directory.appendingPathComponent(relativeFile)
        let image = try normalizedImage(from: source)

        do {
            // Prove the destination path is inside the library before creating
            // the images folder or writing the normalized PNG.
            _ = try checkedImageURL(relativePath: relativeFile)
            try prepareImagesDirectory()
            try writePNG(image, to: destinationURL)
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }

        let record = StoredAvatar(id: identifier,
                                  name: displayName(requested: name, source: source),
                                  file: relativeFile,
                                  standingFile: relativeFile)
        var updatedCatalog = existingCatalog
        updatedCatalog.avatars.append(record)

        do {
            try saveCatalog(updatedCatalog)
        } catch {
            // The library owns the image only after the catalog points at it.
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }

        return Avatar(id: record.id,
                      name: record.name,
                      file: record.file,
                      standingFile: record.standingFile)
    }

    /// Resolves the stored image for an avatar returned by `avatars()`.
    func imageURL(for avatar: Avatar) throws -> URL {
        let catalog = try loadCatalog()
        var matchingRecord: StoredAvatar? = nil
        for record in catalog.avatars {
            if record.id == avatar.id {
                matchingRecord = record
                break
            }
        }
        guard let record = matchingRecord else {
            throw GoblinError(message: "This avatar is not in the custom avatar library.")
        }
        guard record.file == avatar.file else {
            throw GoblinError(message: "This avatar does not match the custom avatar library.")
        }

        let url = try checkedImageURL(relativePath: record.file)
        try verifyImageFileExists(url)
        return url
    }

    private func normalizedImage(from source: URL) throws -> CGImage {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else {
            throw GoblinError(message: "The selected file is not a readable image.")
        }
        guard CGImageSourceGetCount(imageSource) > 0 else {
            throw GoblinError(message: "The selected file does not contain an image.")
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource,
                                                              0,
                                                              options as CFDictionary) else {
            throw GoblinError(message: "The selected image could not be prepared for the avatar library.")
        }
        return image
    }

    private func writePNG(_ image: CGImage, to destination: URL) throws {
        let temporaryURL = imagesDirectory.appendingPathComponent(".import-" + UUID().uuidString + ".png")
        defer { try? fileManager.removeItem(at: temporaryURL) }

        guard let imageDestination = CGImageDestinationCreateWithURL(temporaryURL as CFURL,
                                                                     UTType.png.identifier as CFString,
                                                                     1,
                                                                     nil) else {
            throw GoblinError(message: "The avatar image could not be prepared for saving.")
        }

        // Passing nil properties writes pixels only. Source EXIF, GPS, and
        // descriptive metadata are not copied into the normalized PNG.
        CGImageDestinationAddImage(imageDestination, image, nil)
        guard CGImageDestinationFinalize(imageDestination) else {
            throw GoblinError(message: "The avatar image could not be saved.")
        }

        try fileManager.moveItem(at: temporaryURL, to: destination)
    }

    private func displayName(requested: String?, source: URL) -> String {
        if let requested = requested {
            let cleaned = cleanName(requested)
            if !cleaned.isEmpty {
                return String(cleaned.prefix(Self.maximumNameLength))
            }
        }

        let sourceStem = source.deletingPathExtension().lastPathComponent
        let cleanedStem = cleanName(sourceStem)
        if cleanedStem.isEmpty {
            return "Imported Avatar"
        }
        return String(cleanedStem.prefix(Self.maximumNameLength))
    }

    private func cleanName(_ value: String) -> String {
        let withoutNewlines = value.replacingOccurrences(of: "\n", with: " ")
        let withoutCarriageReturns = withoutNewlines.replacingOccurrences(of: "\r", with: " ")
        return withoutCarriageReturns.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func validateSourceFile(_ source: URL) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw GoblinError(message: "The selected image file does not exist.")
        }
        guard !isDirectory.boolValue else {
            throw GoblinError(message: "The selected image path is a folder.")
        }
        guard fileManager.isReadableFile(atPath: source.path) else {
            throw GoblinError(message: "The selected image file cannot be read.")
        }
    }

    private func prepareImagesDirectory() throws {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: imagesDirectory.path, isDirectory: &isDirectory)
        if exists {
            guard isDirectory.boolValue else {
                throw GoblinError(message: "The avatar images path is not a folder.")
            }

            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try fileManager.attributesOfItem(atPath: imagesDirectory.path)
            } catch {
                throw GoblinError(message: "The avatar images folder could not be checked.")
            }
            let fileType = attributes[.type] as? FileAttributeType
            guard fileType != .typeSymbolicLink else {
                throw GoblinError(message: "The avatar images folder cannot be a symbolic link.")
            }
            return
        }

        do {
            try fileManager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        } catch {
            throw GoblinError(message: "The avatar images folder could not be created.")
        }
    }

    private func verifyImageFileExists(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw GoblinError(message: "The avatar image file is missing.")
        }
        guard !isDirectory.boolValue else {
            throw GoblinError(message: "The avatar image path is a folder.")
        }
    }

    /// Builds an image URL and proves the resolved file stays inside the
    /// supplied library directory. Relative path checks reject traversal
    /// before the filesystem is consulted; symlink resolution catches a link
    /// that points outside the owned directory.
    private func checkedImageURL(relativePath: String) throws -> URL {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2 else {
            throw GoblinError(message: "Avatar catalog contains an invalid image path.")
        }
        guard String(components[0]) == Self.imagesDirectoryName else {
            throw GoblinError(message: "Avatar catalog contains an image outside the images folder.")
        }

        let fileName = String(components[1])
        guard !fileName.isEmpty else {
            throw GoblinError(message: "Avatar catalog contains an empty image filename.")
        }
        guard fileName != ".", fileName != ".." else {
            throw GoblinError(message: "Avatar catalog contains an invalid image filename.")
        }
        guard fileName.hasSuffix("." + Self.imageFileExtension) else {
            throw GoblinError(message: "Avatar catalog contains a filename that is not a PNG.")
        }

        let candidate = directory.appendingPathComponent(relativePath)
        let ownedRoot = directory.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedCandidate = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = ownedRoot.path.hasSuffix("/") ? ownedRoot.path : ownedRoot.path + "/"
        guard resolvedCandidate.path.hasPrefix(rootPath) else {
            throw GoblinError(message: "Avatar catalog contains a path outside the avatar library.")
        }
        return candidate
    }

    private func loadCatalog() throws -> StoredCatalog {
        var isDirectory: ObjCBool = false
        let rootExists = fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory)
        if rootExists && !isDirectory.boolValue {
            throw GoblinError(message: "The avatar library path is not a folder.")
        }
        if !rootExists {
            return StoredCatalog(version: Self.catalogVersion, avatars: [])
        }
        guard fileManager.fileExists(atPath: catalogURL.path) else {
            return StoredCatalog(version: Self.catalogVersion, avatars: [])
        }

        let data: Data
        do {
            data = try Data(contentsOf: catalogURL)
        } catch {
            throw GoblinError(message: "The avatar catalog could not be read.")
        }

        let catalog: StoredCatalog
        do {
            catalog = try JSONDecoder().decode(StoredCatalog.self, from: data)
        } catch {
            throw GoblinError(message: "The avatar catalog is corrupted and cannot be read.")
        }

        try validateCatalog(catalog)
        return catalog
    }

    private func validateCatalog(_ catalog: StoredCatalog) throws {
        guard catalog.version == Self.catalogVersion else {
            throw GoblinError(message: "The avatar catalog version is not supported.")
        }

        var seenIdentifiers = Set<String>()
        for record in catalog.avatars {
            guard UUID(uuidString: record.id) != nil else {
                throw GoblinError(message: "Avatar catalog contains an invalid avatar identifier.")
            }
            guard seenIdentifiers.insert(record.id).inserted else {
                throw GoblinError(message: "Avatar catalog contains a duplicate avatar identifier.")
            }
            guard !cleanName(record.name).isEmpty else {
                throw GoblinError(message: "Avatar catalog contains an avatar with no name.")
            }

            let fileURL = try checkedImageURL(relativePath: record.file)
            let standingURL = try checkedImageURL(relativePath: record.standingFile)
            try validateExistingImageFile(fileURL)
            try validateExistingImageFile(standingURL)
        }
    }

    private func validateExistingImageFile(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard exists else {
            return
        }
        guard !isDirectory.boolValue else {
            throw GoblinError(message: "Avatar catalog points at a folder instead of an image.")
        }
        // checkedImageURL already confirmed the resolved path stays inside the library.
    }

    private func saveCatalog(_ catalog: StoredCatalog) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(catalog)
        } catch {
            throw GoblinError(message: "The avatar catalog could not be prepared.")
        }

        do {
            try data.write(to: catalogURL, options: [.atomic])
        } catch {
            throw GoblinError(message: "The avatar catalog could not be saved.")
        }
    }
}

private struct StoredAvatar: Codable {
    let id: String
    let name: String
    let file: String
    let standingFile: String
}

private struct StoredCatalog: Codable {
    let version: Int
    var avatars: [StoredAvatar]
}
