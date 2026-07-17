import AVFoundation
import AVKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import UIKit

@MainActor
@Observable
final class MediaSession: InputTarget {
    private(set) var image: UIImage?
    private(set) var fileName: String?
    private(set) var isPlaying = false
    @ObservationIgnored private(set) var player: AVPlayer?

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
        loadLocalURL(destination)
    }

    func loadPhotoData(_ data: Data, suggestedName: String = "Photo") {
        player?.pause()
        player = nil
        image = UIImage(data: data)
        fileName = suggestedName
        isPlaying = false
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
        loadLocalURL(destination)
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

    private func loadLocalURL(_ url: URL) {
        fileName = url.lastPathComponent
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .image) == true, let data = try? Data(contentsOf: url) {
            image = UIImage(data: data)
            player = nil
        } else {
            image = nil
            player = AVPlayer(url: url)
        }
        isPlaying = false
    }
}

struct MediaSurfaceView: View {
    let session: MediaSession

    var body: some View {
        Group {
            if let image = session.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
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

#if DEBUG
#Preview("Media Surface — Empty") {
    MediaSurfaceView(session: MediaSession())
        .frame(width: 960, height: 540)
        .preferredColorScheme(.dark)
}
#endif
