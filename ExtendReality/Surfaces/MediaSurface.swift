import AVFoundation
import AVKit
import ImageIO
import Observation
import SwiftUI
import UniformTypeIdentifiers
import UIKit

enum MediaPresentationMode: String, CaseIterable, Hashable, Identifiable, Sendable {
    case twoDimensional
    case spatial3D

    var id: String { rawValue }

    var title: String {
        switch self {
        case .twoDimensional: "2D"
        case .spatial3D: "3D SBS"
        }
    }

    var systemImage: String {
        switch self {
        case .twoDimensional: "rectangle"
        case .spatial3D: "view.3d"
        }
    }
}

struct SpatialPhotoStereoPair {
    let left: UIImage
    let right: UIImage
}

enum MediaImportError: LocalizedError {
    case unsupportedImage
    case unavailablePhotoData

    var errorDescription: String? {
        switch self {
        case .unsupportedImage: "The selected image could not be decoded."
        case .unavailablePhotoData: "The selected photo or video could not be loaded."
        }
    }
}

enum SpatialPhotoDecoder {
    struct DecodedPhoto {
        let primary: UIImage
        let stereoPair: SpatialPhotoStereoPair?
    }

    struct StereoImageIndices: Equatable {
        let left: Int
        let right: Int
    }

    static func decode(_ data: Data) throws -> DecodedPhoto {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw MediaImportError.unsupportedImage
        }

        let primaryIndex = CGImageSourceGetPrimaryImageIndex(source)
        guard let primary = image(at: primaryIndex, in: source) ?? UIImage(data: data) else {
            throw MediaImportError.unsupportedImage
        }

        guard let sourceProperties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any],
              let indices = stereoImageIndices(in: sourceProperties),
              indices.left < CGImageSourceGetCount(source),
              indices.right < CGImageSourceGetCount(source),
              let left = image(at: indices.left, in: source),
              let right = image(at: indices.right, in: source) else {
            return DecodedPhoto(primary: primary, stereoPair: nil)
        }

        return DecodedPhoto(
            primary: primary,
            stereoPair: SpatialPhotoStereoPair(left: left, right: right)
        )
    }

    static func stereoImageIndices(in properties: [CFString: Any]) -> StereoImageIndices? {
        guard let groups = properties[kCGImagePropertyGroups] as? [[CFString: Any]] else {
            return nil
        }
        let stereoType = kCGImagePropertyGroupTypeStereoPair as String
        guard let stereoGroup = groups.first(where: {
            ($0[kCGImagePropertyGroupType] as? String) == stereoType
        }),
        let left = integer(stereoGroup[kCGImagePropertyGroupImageIndexLeft]),
        let right = integer(stereoGroup[kCGImagePropertyGroupImageIndexRight]),
        left >= 0,
        right >= 0,
        left != right else {
            return nil
        }
        return StereoImageIndices(left: left, right: right)
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        return (value as? NSNumber)?.intValue
    }

    private static func image(at index: Int, in source: CGImageSource) -> UIImage? {
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let orientationValue = integer(properties?[kCGImagePropertyOrientation]) ?? 1
        let orientation = UIImage.Orientation(imagePropertyOrientation: orientationValue)
        return UIImage(cgImage: cgImage, scale: 1, orientation: orientation)
    }
}

private extension UIImage.Orientation {
    init(imagePropertyOrientation: Int) {
        self = switch imagePropertyOrientation {
        case 2: .upMirrored
        case 3: .down
        case 4: .downMirrored
        case 5: .leftMirrored
        case 6: .right
        case 7: .rightMirrored
        case 8: .left
        default: .up
        }
    }
}

@MainActor
@Observable
final class MediaSession: InputTarget {
    private(set) var image: UIImage?
    private(set) var spatialPhoto: SpatialPhotoStereoPair?
    private(set) var fileName: String?
    private(set) var isPlaying = false
    private(set) var presentationMode: MediaPresentationMode = .twoDimensional
    private(set) var lastErrorMessage: String?
    @ObservationIgnored private(set) var player: AVPlayer?

    var isSpatialPhoto: Bool { spatialPhoto != nil }
    var isVideo: Bool { player != nil }

    func importFile(_ sourceURL: URL) throws {
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }

        let imports = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        let destination = imports.appendingPathComponent("\(UUID().uuidString)-\(sourceURL.lastPathComponent)")
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        try loadLocalURL(destination)
    }

    func loadPhotoData(_ data: Data, suggestedName: String = "Photo") throws {
        let decoded = try SpatialPhotoDecoder.decode(data)
        player?.pause()
        player = nil
        image = decoded.primary
        spatialPhoto = decoded.stereoPair
        presentationMode = decoded.stereoPair == nil ? .twoDimensional : .spatial3D
        fileName = decoded.stereoPair == nil ? suggestedName : "Spatial Photo"
        isPlaying = false
        lastErrorMessage = nil
    }

    func importMediaData(_ data: Data, filenameExtension: String) throws {
        let imports = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        let destination = imports
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(filenameExtension)
        try data.write(to: destination, options: .atomic)
        try loadLocalURL(destination)
    }

    func setPresentationMode(_ mode: MediaPresentationMode) {
        guard mode == .twoDimensional || spatialPhoto != nil else { return }
        presentationMode = mode
    }

    func reportImportError(_ error: any Error) {
        lastErrorMessage = error.localizedDescription
    }

    func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    func seek(seconds: Double) {
        guard let player else { return }
        let current = player.currentTime().seconds
        guard current.isFinite else { return }
        player.seek(to: CMTime(seconds: max(0, current + seconds), preferredTimescale: 600))
    }

    func handle(_ command: InputCommand) {
        guard case .media(let media) = command else { return }
        switch media {
        case .play:
            player?.play()
            isPlaying = true
        case .pause:
            player?.pause()
            isPlaying = false
        case .togglePlayback:
            togglePlayback()
        case .seek(let seconds):
            seek(seconds: seconds)
        }
    }

    private func loadLocalURL(_ url: URL) throws {
        fileName = url.lastPathComponent
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .image) == true {
            try loadPhotoData(Data(contentsOf: url), suggestedName: url.lastPathComponent)
        } else {
            image = nil
            spatialPhoto = nil
            presentationMode = .twoDimensional
            player = AVPlayer(url: url)
            lastErrorMessage = nil
        }
        isPlaying = false
    }
}

struct MediaSurfaceView: View {
    let session: MediaSession

    var body: some View {
        Group {
            if let image = session.image {
                if session.presentationMode == .spatial3D, let pair = session.spatialPhoto {
                    SpatialPhotoSideBySideView(pair: pair)
                } else {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                }
            } else if let player = session.player {
                VideoPlayer(player: player)
            } else {
                ContentUnavailableView(
                    "No media selected",
                    systemImage: "photo.on.rectangle",
                    description: Text("Choose a photo or video on the iPhone.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

struct SpatialPhotoSideBySideView: View {
    let pair: SpatialPhotoStereoPair

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                eyeView(pair.left, width: proxy.size.width / 2)
                eyeView(pair.right, width: proxy.size.width / 2)
            }
        }
        .background(Color.black)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Spatial photo in side-by-side 3D")
    }

    private func eyeView(_ image: UIImage, width: CGFloat) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .clipped()
    }
}

#if DEBUG
#Preview("Media Surface — Empty") {
    MediaSurfaceView(session: MediaSession())
        .frame(width: 960, height: 540)
        .preferredColorScheme(.dark)
}
#endif
