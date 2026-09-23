import AppKit
@preconcurrency import AVFoundation
import CryptoKit
import SwiftUI

@MainActor
final class VideoThumbnailService {
    private struct InFlightRequest {
        let id: UUID
        let task: Task<CGImage?, Never>
    }
    static let shared = VideoThumbnailService()
    private let cache = NSCache<NSString, CGImage>()
    private let generators = NSCache<NSString, AVAssetImageGenerator>()
    private var generatorKeys: Set<String> = []
    private var inFlight: [String: InFlightRequest] = [:]
    private let diskCacheDirectory: URL
    private var didScheduleDiskCleanup = false
    private var memoryWarningObserver: NSObjectProtocol?

    private init() {
        diskCacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "VideoThumbnails", directoryHint: .isDirectory)
        cache.countLimit = 300
        cache.totalCostLimit = 32 * 1_024 * 1_024
        generators.countLimit = 12
    }

    func image(url: URL, seconds: Double, size: CGSize, persistsToDisk: Bool = false, tolerance: Double = 0.2) async -> CGImage? {
        let bucket = Int((seconds * 4).rounded())
        let toleranceMilliseconds = Int((max(0, tolerance) * 1_000).rounded())
        let sourceStamp = (try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]))
        let keyValue = "\(url.path())-\(sourceStamp?.fileSize ?? 0)-\(sourceStamp?.contentModificationDate?.timeIntervalSince1970 ?? 0)-\(bucket)-\(Int(size.width))x\(Int(size.height))-t\(toleranceMilliseconds)"
        let key = keyValue as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let diskURL = persistsToDisk ? diskURL(for: keyValue) : nil
        if let diskURL,
           let data = await Task.detached(priority: .utility, operation: { try? Data(contentsOf: diskURL, options: .mappedIfSafe) }).value,
           let image = NSBitmapImageRep(data: data)?.cgImage {
            cache.setObject(image, forKey: key, cost: imageCost(image))
            scheduleDiskCleanupIfNeeded()
            return image
        }
        if let request = inFlight[keyValue] { return await request.task.value }
        let generatorKey = "\(url.path())-\(Int(size.width))x\(Int(size.height))-t\(toleranceMilliseconds)"
        let generator: AVAssetImageGenerator
        if let existing = generators.object(forKey: generatorKey as NSString) {
            generator = existing
        } else {
            let value = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            value.appliesPreferredTrackTransform = true; value.maximumSize = size
            let requestedTolerance = CMTime(seconds: max(0, tolerance), preferredTimescale: 600)
            value.requestedTimeToleranceBefore = requestedTolerance
            value.requestedTimeToleranceAfter = requestedTolerance
            generators.setObject(value, forKey: generatorKey as NSString)
            generatorKeys.insert(generatorKey)
            generator = value
        }
        let task: Task<CGImage?, Never> = Task { @MainActor [generator] in
            guard let value = try? await generator.image(at: CMTime(seconds: max(0, seconds), preferredTimescale: 600)) else { return nil }
            return value.image
        }
        let requestID = UUID()
        inFlight[keyValue] = InFlightRequest(id: requestID, task: task)
        let image = await task.value
        if inFlight[keyValue]?.id == requestID { inFlight[keyValue] = nil }
        if let image {
            cache.setObject(image, forKey: key, cost: imageCost(image))
            if let diskURL, let data = jpegData(from: image) {
                let directory = diskCacheDirectory
                Task.detached(priority: .utility) {
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try? data.write(to: diskURL, options: .atomic)
                }
                scheduleDiskCleanupIfNeeded()
            }
        }
        return image
    }

    private func jpegData(from image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.78])
    }

    private func diskURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return diskCacheDirectory.appending(path: "\(digest).jpg")
    }

    private func imageCost(_ image: CGImage) -> Int {
        image.width * image.height * 4
    }

    private func scheduleDiskCleanupIfNeeded() {
        guard !didScheduleDiskCleanup else { return }
        didScheduleDiskCleanup = true
        let directory = diskCacheDirectory
        Task.detached(priority: .background) {
            let manager = FileManager.default
            guard let files = try? manager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentAccessDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { return }
            let entries = files.compactMap { url -> (URL, Date, Int)? in
                guard let values = try? url.resourceValues(forKeys: [.contentAccessDateKey, .contentModificationDateKey, .fileSizeKey]) else { return nil }
                return (url, values.contentAccessDate ?? values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
            }.sorted { $0.1 > $1.1 }
            var retainedBytes = 0
            for entry in entries {
                retainedBytes += entry.2
                if retainedBytes > 64 * 1_024 * 1_024 { try? manager.removeItem(at: entry.0) }
            }
        }
    }

    func cancelRequests(url: URL, size: CGSize) {
        let width = Int(size.width)
        let height = Int(size.height)
        let generatorPrefix = "\(url.path())-\(width)x\(height)-t"
        for key in generatorKeys.filter({ $0.hasPrefix(generatorPrefix) }) {
            generators.object(forKey: key as NSString)?.cancelAllCGImageGeneration()
            generators.removeObject(forKey: key as NSString)
            generatorKeys.remove(key)
        }
        let prefix = "\(url.path())-"
        let sizeMarker = "-\(width)x\(height)-t"
        let matchingKeys = inFlight.keys.filter { $0.hasPrefix(prefix) && $0.contains(sizeMarker) }
        for key in matchingKeys {
            inFlight.removeValue(forKey: key)?.task.cancel()
        }
    }

    private func releaseTransientResources() {
        inFlight.values.forEach { $0.task.cancel() }
        inFlight.removeAll(keepingCapacity: false)
        generators.removeAllObjects()
        generatorKeys.removeAll(keepingCapacity: false)
        cache.removeAllObjects()
    }
}

struct VideoThumbnailView: View {
    let url: URL?
    var seconds: Double = 0
    var icon = "play.fill"
    var tint: Color = .blue
    @State private var image: CGImage?

    var body: some View {
        // `Color.clear` takes exactly the proposed size; the overlay fills it and is clipped,
        // so a scaled-to-fill frame can never push the thumbnail past its container.
        Color.clear
            .background(tint.gradient)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                } else {
                    Image(systemName: icon).font(.title2.bold()).foregroundStyle(.white)
                }
            }
            .overlay(LinearGradient(colors: [.clear, .black.opacity(0.25)], startPoint: .top, endPoint: .bottom))
            .overlay {
                Image(systemName: icon).font(.caption.bold()).foregroundStyle(.white)
                    .padding(6).background(.black.opacity(0.48), in: .circle)
            }
            .clipShape(.rect(cornerRadius: 12))
            .contentShape(.rect(cornerRadius: 12))
        .task(id: "\(url?.path() ?? "")-\(seconds)") {
            image = nil
            guard let url else { return }
            if url.isFileURL && !FileManager.default.fileExists(atPath: url.path()) { return }
            image = await VideoThumbnailService.shared.image(
                url: url,
                seconds: seconds,
                size: CGSize(width: 200, height: 120),
                persistsToDisk: true
            )
        }
    }
}