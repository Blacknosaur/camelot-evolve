import CoreGraphics
import Foundation
import ImageIO
import UIKit
import os
import UniformTypeIdentifiers
import Vision

/// Squad player photos: square 512 px JPEGs at `Documents/SquadPhotos/<id>.jpg`.
/// Thread-safe; the 2D and 3D renderers and exports call `image(for:)` from any thread.
///
/// Photos are the coach's own content and cannot be regenerated, so unlike recordings (multi-GB
/// videos) and board thumbnails (re-rendered on demand) they are *included* in the device backup:
/// a restored phone would otherwise keep every player and silently lose every face, at ~40 KB each.
///
/// Decoded images (and "no photo") are cached with a byte budget and dropped on a memory warning.
/// Saving or deleting invalidates the entry, and a generation counter stops a read that raced a
/// save from caching the old image. Draw paths on the main thread use `cachedImage(for:)`, which
/// never touches the disk and warms the entry in the background instead.
enum SquadPhotoStore {
    static let pixelSize = 512
    static let quality = 0.85

    /// Posted on the main queue when a background warm makes a photo available to `cachedImage(for:)`.
    static let didWarmPhoto = Notification.Name("SquadPhotoStore.didWarmPhoto")

    private static let root = OSAllocatedUnfairLock(initialState: URL.documentsDirectory)

    /// Folder photos live in. Tests point it at a temporary directory so they never touch the real
    /// Documents folder of the app that hosts them.
    static var rootDirectory: URL {
        get { root.withLock { $0 } }
        set {
            root.withLock { $0 = newValue }
            cache.storage.removeAllObjects()
            generations.withLock { $0.removeAll() }
        }
    }

    static var folder: URL { rootDirectory.appending(path: "SquadPhotos", directoryHint: .isDirectory) }

    static func url(for id: UUID) -> URL { folder.appending(path: "\(id.uuidString).jpg") }

    /// A decoded photo (or "none") plus a version that changes whenever the stored file does.
    private final class Entry: @unchecked Sendable {
        let image: CGImage?
        let version: String
        let cost: Int
        init(_ image: CGImage?, version: String) {
            self.image = image
            self.version = version
            cost = image.map { $0.bytesPerRow * $0.height } ?? 1
        }
    }

    /// NSCache with a byte budget and a memory-warning purge, as `VideoThumbnailService` does.
    private final class PhotoCache: @unchecked Sendable {
        let storage = NSCache<NSUUID, Entry>()
        private var observer: NSObjectProtocol?

        init() {
            storage.countLimit = 200
            storage.totalCostLimit = 16 * 1_024 * 1_024
            observer = NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil
            ) { [weak self] _ in
                self?.storage.removeAllObjects()
            }
        }
    }

    private static let cache = PhotoCache()
    private static let generations = OSAllocatedUnfairLock(initialState: [UUID: Int]())
    private static let warming = OSAllocatedUnfairLock(initialState: Set<UUID>())

    // MARK: Reading

    /// The decoded photo, or nil when the player has none. Reads and decodes from disk on a miss,
    /// so call it off the main thread.
    static func image(for id: UUID) -> CGImage? { entry(for: id).image }

    /// The photo and its version, decoding from disk on a miss (offscreen renders and exports).
    static func imageWithVersion(for id: UUID) -> (image: CGImage, version: String)? {
        let entry = entry(for: id)
        return entry.image.map { ($0, entry.version) }
    }

    /// The photo and its version, but only when it is already decoded: a miss starts a background
    /// warm and posts `didWarmPhoto`, so a draw pass never blocks on disk I/O.
    static func cachedImage(for id: UUID) -> (image: CGImage, version: String)? {
        guard let entry = cache.storage.object(forKey: id as NSUUID) else {
            warm(id)
            return nil
        }
        return entry.image.map { ($0, entry.version) }
    }

    /// Decodes a photo in the background unless that is already happening.
    static func warm(_ id: UUID) {
        guard warming.withLock({ $0.insert(id).inserted }) else { return }
        Task.detached(priority: .userInitiated) {
            let found = entry(for: id).image != nil
            _ = warming.withLock { $0.remove(id) }
            guard found else { return }
            await MainActor.run { NotificationCenter.default.post(name: didWarmPhoto, object: nil) }
        }
    }

    private static func entry(for id: UUID) -> Entry {
        let key = id as NSUUID
        if let entry = cache.storage.object(forKey: key) { return entry }
        let generation = generations.withLock { $0[id, default: 0] }
        let url = url(for: id)
        let entry = Entry(decode(url), version: version(of: url))
        generations.withLock { current in
            if current[id, default: 0] == generation { cache.storage.setObject(entry, forKey: key, cost: entry.cost) }
        }
        return entry
    }

    /// Identifies the stored file by size and modification time, so a replaced photo gets a new
    /// texture key without holding the old image alive to compare addresses.
    private static func version(of url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return "\(values?.fileSize ?? 0)-\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }

    /// Whether a photo is stored, without decoding it.
    static func hasPhoto(for id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: url(for: id).path(percentEncoded: false))
    }

    /// The stored JPEG bytes (for duplicating a player).
    static func jpegData(for id: UUID) -> Data? { try? Data(contentsOf: url(for: id)) }

    // MARK: Writing

    /// Crops `data` (any ImageIO format) to a square around the most prominent face, or the centre,
    /// scales it to 512 px and stores it as JPEG.
    static func save(_ data: Data, for id: UUID) throws {
        try store(squareJPEG(from: data), for: id)
    }

    /// Writes JPEG bytes already produced by `squareJPEG(from:)` (editor previews, duplicates).
    static func store(_ jpeg: Data, for id: UUID) throws {
        try prepareFolder()
        try jpeg.write(to: url(for: id), options: .atomic)
        invalidate(id)
    }

    /// The stored representation of a picked photo: square, face-centred, 512 px JPEG.
    static func squareJPEG(from data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let oriented = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 2048,
              ] as CFDictionary)
        else { throw PhotoError.unreadable }
        let square = try squareImage(oriented)
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw PhotoError.unwritable }
        CGImageDestinationAddImage(destination, square, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PhotoError.unwritable }
        return output as Data
    }

    static func decodeJPEG(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func delete(for id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
        invalidate(id)
    }

    enum PhotoError: Error { case unreadable, unwritable }

    // MARK: Helpers

    private static func invalidate(_ id: UUID) {
        generations.withLock { current in
            current[id, default: 0] += 1
            cache.storage.removeObject(forKey: id as NSUUID)
        }
    }

    private static func prepareFolder() throws {
        var directory = folder
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Photos are irreplaceable user content: back them up. Installs made before this cleared
        // the flag they used to inherit from the recordings folder.
        if (try? directory.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup == true {
            var values = URLResourceValues()
            values.isExcludedFromBackup = false
            try? directory.setResourceValues(values)
        }
    }

    private static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// Square crop in pixel coordinates (origin top-left): around the largest face with room for hair
    /// and shoulders, else centred.
    static func cropRect(imageSize: CGSize, face: CGRect?) -> CGRect {
        let short = min(imageSize.width, imageSize.height)
        guard let face, face.width > 0 else {
            return CGRect(x: (imageSize.width - short) / 2, y: (imageSize.height - short) / 2, width: short, height: short).integral
        }
        let side = min(short, max(face.width, face.height) * 2.4)
        let center = CGPoint(x: face.midX, y: face.midY + face.height * 0.1)
        let x = min(max(0, center.x - side / 2), imageSize.width - side)
        let y = min(max(0, center.y - side / 2), imageSize.height - side)
        return CGRect(x: x, y: y, width: side, height: side).integral
    }

    private static func largestFace(in image: CGImage) -> CGRect? {
        let request = VNDetectFaceRectanglesRequest()
        do { try VNImageRequestHandler(cgImage: image).perform([request]) } catch { return nil }
        guard let face = request.results?.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) else { return nil }
        let w = CGFloat(image.width), h = CGFloat(image.height), box = face.boundingBox
        // Vision's normalised boxes have their origin at the bottom-left.
        return CGRect(x: box.minX * w, y: (1 - box.maxY) * h, width: box.width * w, height: box.height * h)
    }

    private static func squareImage(_ image: CGImage) throws -> CGImage {
        let crop = cropRect(imageSize: CGSize(width: image.width, height: image.height), face: largestFace(in: image))
        guard let cropped = image.cropping(to: crop),
              let context = CGContext(data: nil, width: pixelSize, height: pixelSize, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw PhotoError.unreadable }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
        guard let result = context.makeImage() else { throw PhotoError.unreadable }
        return result
    }
}
