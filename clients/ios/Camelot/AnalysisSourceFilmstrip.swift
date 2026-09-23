import SwiftUI

/// Only visible source tiles are decoded. Stable time buckets reuse the editor's
/// thumbnail cache while the playhead scrolls; nothing is written to the project.
struct AnalysisSourceFilmstrip: View {
    let url: URL
    let bounds: ClosedRange<Double>
    let visibleStart: Double
    let scale: CGFloat
    let width: CGFloat
    let freezeTime: Double?
    var height: CGFloat = 48

    var body: some View {
        let interval = max(0.25, ceil(80 / max(0.01, scale) * 4) / 4)
        let first = max(0, Int(floor((visibleStart - bounds.lowerBound) / interval)))
        let last = max(first, min(Int(ceil((bounds.upperBound - bounds.lowerBound) / interval)),
                                 Int(ceil((visibleStart + width / max(0.01, scale) - bounds.lowerBound) / interval))))
        ZStack(alignment: .leading) {
            ForEach(first..<min(last, first + 32), id: \.self) { index in
                let start = bounds.lowerBound + Double(index) * interval
                let end = min(bounds.upperBound, start + interval)
                AnalysisSourceThumbnail(url: url, time: freezeTime ?? min(bounds.upperBound - 1 / 30, start))
                    .frame(width: max(1, (end - start) * scale), height: height)
                    .clipped().offset(x: (start - visibleStart) * scale)
            }
        }.frame(width: width, height: height, alignment: .leading).clipped()
            .accessibilityElement(children: .ignore).accessibilityLabel("Source video frames")
            .accessibilityIdentifier("analysis-source-filmstrip")
    }
}

private struct AnalysisSourceThumbnail: View {
    let url: URL
    let time: Double
    @State private var image: UIImage?

    var body: some View {
        Color.white.opacity(0.06)
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
            }
            .task(id: "\(url.path)-\(time)") {
                let result = await VideoThumbnailService.shared.image(url: url, seconds: max(0, time), size: .init(width: 160, height: 100))
                guard !Task.isCancelled else { return }
                image = result
            }
    }
}
