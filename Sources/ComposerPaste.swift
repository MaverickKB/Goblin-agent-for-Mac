import AppKit

/// Turns a pasteboard into files the composer can attach to the next turn.
///
/// A screenshot arrives as TIFF or PNG image data, not text. A copy from Finder
/// arrives as file URLs. Both become attachments; anything else falls through to
/// the text view's own paste.
enum ComposerPaste {
    static func attachmentURLs(from pasteboard: NSPasteboard, directory: URL) -> [URL] {
        let files = fileURLs(from: pasteboard)
        if !files.isEmpty {
            return files
        }
        guard let image = imageData(from: pasteboard) else {
            return []
        }
        guard let url = writeImage(image, to: directory) else {
            return []
        }
        return [url]
    }

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options)
        guard let urls = objects as? [URL] else {
            return []
        }
        return urls
    }

    static func imageData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) {
            return png
        }
        if let tiff = pasteboard.data(forType: .tiff) {
            return pngData(fromTIFF: tiff)
        }
        return nil
    }

    static func pngData(fromTIFF tiff: Data) -> Data? {
        guard let image = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return image.representation(using: .png, properties: [:])
    }

    static func writeImage(_ data: Data, to directory: URL) -> URL? {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let base = fileName(date: Date())
        var url = directory.appendingPathComponent(base)
        var copyNumber = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent(numberedName(base: base, copyNumber: copyNumber))
            copyNumber += 1
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        return url
    }

    static func numberedName(base: String, copyNumber: Int) -> String {
        let name = base as NSString
        let stem = name.deletingPathExtension
        let extensionName = name.pathExtension
        return stem + " (" + String(copyNumber) + ")." + extensionName
    }

    static func fileName(date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss.SSS"
        return "Pasted Image " + formatter.string(from: date) + ".png"
    }
}
