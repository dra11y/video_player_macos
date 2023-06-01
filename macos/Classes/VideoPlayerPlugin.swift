//
//  VideoPlayerPlugin.swift
//  video_player_swift
//
//  Created by Tom Grushka on 5/13/23.
//

import AVFoundation
import FlutterMacOS
import GLKit

extension FlutterError: Error {}

protocol FVPPlayerFactory {
    func playerWithPlayerItem(_ playerItem: AVPlayerItem) -> AVPlayer
}

extension FlutterPluginRegistrar {
    /// https://github.com/flutter/flutter/issues/47681
    /// Replaces non-existent `FlutterPluginRegistrar.lookupKey`
    func url(forAsset asset: String, package: String? = nil) -> URL? {
        print("url(forAsset: \(asset), package: \(package)")
        guard
            let flutterBundle = Bundle(identifier: "io.flutter.flutter.app"),
            let path = flutterBundle.path(forResource: asset, ofType: nil, inDirectory: "flutter_assets")
        else { return nil }
        return URL(fileURLWithPath: path)
    }
}

class FVPDefaultPlayerFactory: NSObject, FVPPlayerFactory {
    func playerWithPlayerItem(_ playerItem: AVPlayerItem) -> AVPlayer {
        return AVPlayer(playerItem: playerItem)
    }
}

public class VideoPlayerPlugin: NSObject, AVFoundationVideoPlayerApi {
    func setMixWithOthers(msg: MixWithOthersMessage) throws {
        print("setMixWithOthers not needed on macOS.")
    }

    weak var registry: FlutterTextureRegistry?
    weak var messenger: FlutterBinaryMessenger?
    var playersByTextureId = [Int64: VideoPlayer]()
    var registrar: FlutterPluginRegistrar?
    var playerFactory: FVPPlayerFactory?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = VideoPlayerPlugin(registrar: registrar)
        AVFoundationVideoPlayerApiSetup.setUp(binaryMessenger: registrar.messenger, api: instance)
    }

    init(registrar: FlutterPluginRegistrar) {
        print("init registrar:")
        super.init()
        self.registry = registrar.textures
        self.messenger = registrar.messenger
        self.registrar = registrar
        self.playerFactory = FVPDefaultPlayerFactory()
    }

    func detach(from registrar: FlutterPluginRegistrar) {
        print("detach from registrar")
        playersByTextureId.values.forEach { $0.disposeSansEventChannel() }
        playersByTextureId.removeAll()
    }

    func onPlayerSetup(player: VideoPlayer, frameUpdater: FrameUpdater) -> TextureMessage {
        let textureId = registry!.register(player)
        print("onPlayerSetup textureId = \(textureId)")
        frameUpdater.textureId = textureId
        let eventChannel = FlutterEventChannel(name: "flutter.io/videoPlayer/videoEvents\(textureId)", binaryMessenger: messenger!)
        eventChannel.setStreamHandler(player)
        player.eventChannel = eventChannel
        playersByTextureId[textureId] = player
        return TextureMessage(textureId: textureId)
    }

    func initialize() throws {
        print("initialize()")

        playersByTextureId.forEach { (textureId, player) in
            print("disposing player by texture id \(textureId)")
            registry?.unregisterTexture(textureId)
            player.dispose()
        }
        playersByTextureId.removeAll()
    }

    func create(msg input: CreateMessage) throws -> TextureMessage {
        print("create msg: \(input)")

        guard let registry = registry else {
            throw FlutterError(code: "video_player", message: "Registry is nil", details: nil)
        }
        let frameUpdater = FrameUpdater(registry: registry)

        if let asset = input.asset {
            guard let url = registrar?.url(forAsset: asset, package: input.packageName)
            else {
                throw FlutterError(code: "video_player", message: "Flutter VideoPlayer asset not found: asset = \(asset), package = \(String(describing: input.packageName))", details: nil)
            }
            let player = VideoPlayer(url: url, frameUpdater: frameUpdater)
            return onPlayerSetup(player: player, frameUpdater: frameUpdater)
        } else if let uri = input.uri {
            print("create with uri = \(input.uri)")
            let player = VideoPlayer(url: URL(string: uri)!, frameUpdater: frameUpdater, httpHeaders: input.httpHeaders as? [String: String], playerFactory: playerFactory)
            return onPlayerSetup(player: player, frameUpdater: frameUpdater)
        } else {
            throw FlutterError(code: "video_player", message: "not implemented", details: nil)
        }
    }

    func dispose(msg input: TextureMessage) {
        print("dispose msg: \(input)")

        let player = playersByTextureId[input.textureId]
        registry?.unregisterTexture(input.textureId)
        playersByTextureId.removeValue(forKey: input.textureId)

        // Dispatch after hack to avoid potential crash due to texture unregistration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if player?.disposed == false {
                player?.dispose()
            }
        }
    }

    func setLooping(msg input: LoopingMessage) {
        print("setLooping msg: \(input)")

        let player = playersByTextureId[input.textureId]
        player?.isLooping = input.isLooping
    }

    func setVolume(msg input: VolumeMessage) {
        print("setVolume msg: \(input)")

        let player = playersByTextureId[input.textureId]
        player?.setVolume(input.volume)
    }

    func setPlaybackSpeed(msg input: PlaybackSpeedMessage) {
        print("setPlaybackSpeed msg: \(input)")

        let player = playersByTextureId[input.textureId]
        player?.setPlaybackSpeed(input.speed)
    }

    func play(msg input: TextureMessage) {
        print("play msg: \(input)")

        playersByTextureId[input.textureId]?.play()
    }

    func position(msg input: TextureMessage) throws -> PositionMessage {
        print("position msg: \(input)")

        let player = playersByTextureId[input.textureId]
        return PositionMessage(textureId: input.textureId, position: player?.position ?? 0)
    }

    func seekTo(msg input: PositionMessage, completion: @escaping (Result<Void, Error>) -> Void) {
        print("seekTo msg: \(input)")

        guard let player = playersByTextureId[input.textureId] else { return }
        player.seek(to: Int(input.position), completionHandler: { finished in
            DispatchQueue.main.async { [weak self] in
                self?.registry?.textureFrameAvailable(input.textureId)
                completion(.success(Void()))
            }
        })
    }

    func pause(msg input: TextureMessage) {
        print("pause msg: \(input)")

        let textureId = input.textureId
        let player = playersByTextureId[textureId]
        player?.pause()
    }
}


let CMTimeToMillis: (CMTime) -> Int64 = { time in
    if time.timescale == 0 {
        return 0
    } else {
        return time.value * 1000 / Int64(time.timescale)
    }
}

class FrameUpdater: NSObject {
    var textureId: Int64 = 0
    weak var registry: FlutterTextureRegistry?

    func notifyFrameAvailable() {
        registry?.textureFrameAvailable(textureId)
    }

    init(registry: FlutterTextureRegistry) {
        self.registry = registry
    }
}


enum ObserverKey: String, CaseIterable {
    case status
    case loadedTimeRanges
    case presentationSize
    case duration
    case playbackLikelyToKeepUp
    case playbackBufferEmpty
    case playbackBufferFull
    case rate
}

class VideoPlayer: NSObject, FlutterTexture, FlutterStreamHandler {
    var player: AVPlayer
    var playerItem: AVPlayerItem
    var videoOutput: AVPlayerItemVideoOutput?
    var displayLink: CVDisplayLink?
    var frameUpdater: FrameUpdater
    var lastValidFrame: CVPixelBuffer?
    var eventChannel: FlutterEventChannel?
    var eventSink: FlutterEventSink?
    var preferredTransform: CGAffineTransform
    var disposed: Bool
    var isPlaying: Bool
    var isLooping: Bool
    var isInitialized: Bool
    
    convenience init(
        url: URL,
        frameUpdater: FrameUpdater,
        httpHeaders headers: [String: String]? = nil,
        playerFactory: FVPPlayerFactory? = nil
    ) {
        var options = [String: Any]()
        if let headers = headers {
            options["AVURLAssetHTTPHeaderFieldsKey"] = headers
        }
        let asset = AVURLAsset(url: url, options: options)
        let playerItem = AVPlayerItem(asset: asset)
        self.init(playerItem: playerItem, frameUpdater: frameUpdater, playerFactory: playerFactory)
    }

    required init(playerItem item: AVPlayerItem, frameUpdater: FrameUpdater, playerFactory: FVPPlayerFactory? = nil) {
        print("VideoPlayer.init playerItem: \(item)")
        isInitialized = false
        isPlaying = false
        disposed = false
        playerItem = item
        player = playerFactory?.playerWithPlayerItem(item) ?? AVPlayer(playerItem: item)
        player.actionAtItemEnd = .none
        self.frameUpdater = frameUpdater
        preferredTransform = CGAffineTransform.identity
        isLooping = false
        
        super.init()

        let asset = item.asset

        let assetCompletionHandler: () -> Void = { [weak self] in
            guard let self = self else { return }

            var error: NSError?

            if asset.statusOfValue(forKey: "tracks", error: &error) == .loaded {
                let tracks = asset.tracks(withMediaType: .video)
                if !tracks.isEmpty {
                    let videoTrack = tracks[0]
                    let trackCompletionHandler: () -> Void = { [weak self] in
                        guard let self = self else { return }

                        if self.disposed { return }
                        if videoTrack.statusOfValue(forKey: "preferredTransform", error: &error) == .loaded {
                            // Rotate the video by using a videoComposition and the preferredTransform
                            self.preferredTransform = self.fixTransform(videoTrack: videoTrack)
                            // Note:
                            // https://developer.apple.com/documentation/avfoundation/avplayeritem/1388818-videocomposition
                            // Video composition can only be used with file-based media and is not supported for use with media served using HTTP Live Streaming.
                            let videoComposition = self.getVideoComposition(withTransform: self.preferredTransform, withAsset: asset, withVideoTrack: videoTrack)
                            item.videoComposition = videoComposition
                        }
                    }
                    videoTrack.loadValuesAsynchronously(forKeys: ["preferredTransform"], completionHandler: trackCompletionHandler)
                }
            }
        }

        createVideoOutputAndDisplayLink(frameUpdater: frameUpdater)

        addObservers(item: item)

        asset.loadValuesAsynchronously(forKeys: ["tracks"], completionHandler: assetCompletionHandler)
    }

    func addObservers(item: AVPlayerItem) {
        print("addObservers item: \(item)")
        for key in ObserverKey.allCases {
            if key == .rate {
                player.addObserver(self, forKeyPath: key.rawValue, context: nil)
                continue
            }
            item.addObserver(self, forKeyPath: key.rawValue, options: [.initial, .new], context: nil)
        }

        NotificationCenter.default.addObserver(self, selector: #selector(itemDidPlayToEndTime), name: .AVPlayerItemDidPlayToEndTime, object: item)
     }

    @objc func itemDidPlayToEndTime(notification: Notification) {
        print("itemDidPlayToEndTime")
        if isLooping {
            guard let p = notification.object as? AVPlayerItem else { return }
            p.seek(to: .zero, completionHandler: nil)
        } else {
            if let eventSink = eventSink {
                eventSink(["event" : "completed"])
            }
        }
    }

    static func radiansToDegrees(_ radians: CGFloat) -> CGFloat {
        print("radiansToDegrees radians: \(radians)")
        // Input range [-pi, pi] or [-180, 180]
        var degrees = GLKMathRadiansToDegrees(Float(radians))
        if degrees < 0 {
            // Convert -90 to 270 and -180 to 180
            degrees += 360
        }
        // Output degrees in between [0, 360[
        return CGFloat(degrees)
    }

    func getVideoComposition(withTransform transform: CGAffineTransform, withAsset asset: AVAsset, withVideoTrack videoTrack: AVAssetTrack) -> AVMutableVideoComposition {
        print("getVideoComposition")
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRangeMake(start: .zero, duration: asset.duration)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layerInstruction.setTransform(preferredTransform, at: .zero)

        let videoComposition = AVMutableVideoComposition()
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        // If in portrait mode, switch the width and height of the video
        var width = videoTrack.naturalSize.width
        var height = videoTrack.naturalSize.height
        let rotationDegrees = Int(round(Self.radiansToDegrees(atan2(preferredTransform.b, preferredTransform.a))))
        if rotationDegrees == 90 || rotationDegrees == 270 {
            width = videoTrack.naturalSize.height
            height = videoTrack.naturalSize.width
        }
        videoComposition.renderSize = CGSize(width: width, height: height)

        // TODO(@recastrodiaz): should we use videoTrack.nominalFrameRate ?
        // Currently set at a constant 30 FPS
        videoComposition.frameDuration = CMTimeMake(value: 1, timescale: 30)

        return videoComposition
    }


    func createVideoOutputAndDisplayLink(frameUpdater: FrameUpdater) {
        print("createVideoOutputAndDisplayLink")
        let pixBuffAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [AnyHashable: Any],
            kCVPixelBufferOpenGLCompatibilityKey as String: true,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: pixBuffAttributes)

        startDisplayLink()
        if let displayLink = displayLink {
            CVDisplayLinkStop(displayLink)
        }
    }

    func notifyIfFrameAvailable() {
//        print("notifyIfFrameAvailable()")
        guard let videoOutput = videoOutput else { return }
        let outputItemTime = videoOutput.itemTime(forHostTime: CACurrentMediaTime())
        if playerItem.status != .readyToPlay || !videoOutput.hasNewPixelBuffer(forItemTime: outputItemTime) {
            return
        } else {
            guard let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: outputItemTime, itemTimeForDisplay: nil) else { return }
            synchronized(lock: self) {
                lastValidFrame = pixelBuffer
            }
            frameUpdater.notifyFrameAvailable()
        }
    }

    // Synchronized function for thread safety
    func synchronized(lock: AnyObject, closure: () -> ()) {
        objc_sync_enter(lock)
        closure()
        objc_sync_exit(lock)
    }

    let OnDisplayLink: CVDisplayLinkOutputCallback = { (displayLink, inNow, inOutputTime, flagsIn, flagsOut, displayLinkContext) -> CVReturn in
//        print("OnDisplayLink")
        let videoPlayer = Unmanaged<VideoPlayer>.fromOpaque(displayLinkContext!).takeUnretainedValue()
        videoPlayer.notifyIfFrameAvailable()
        return kCVReturnSuccess
    }

    func startDisplayLink() {
        print("startDisplayLink()")
        guard displayLink == nil else { return }

        if CVDisplayLinkCreateWithCGDisplay(CGMainDisplayID(), &displayLink) != kCVReturnSuccess {
            displayLink = nil
            return
        }

        CVDisplayLinkSetOutputCallback(displayLink!, OnDisplayLink, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(displayLink!)
    }

    func stopDisplayLink() {
        print("stopDisplayLink()")
        guard displayLink != nil else { return }

        CVDisplayLinkStop(displayLink!)
        displayLink = nil
    }

    func fixTransform(videoTrack: AVAssetTrack) -> CGAffineTransform {
        print("fixTransform()")
        var transform = videoTrack.preferredTransform
        // TODO(@recastrodiaz): why do we need to do this? Why is the
        // preferredTransform incorrect? At least 2 user videos show a black screen
        // when in portrait mode if we directly use the
        // videoTrack.preferredTransform Setting tx to the height of the video
        // instead of 0, properly displays the video
        // https://github.com/flutter/flutter/issues/17606#issuecomment-413473181
        if transform.tx == 0 && transform.ty == 0 {
            let rotationDegrees = Int(round(Self.radiansToDegrees(atan2(transform.b, transform.a))))
            print("TX and TY are 0. Rotation: \(rotationDegrees). Natural width,height: \(videoTrack.naturalSize.width), \(videoTrack.naturalSize.height)")
            if rotationDegrees == 90 {
                print("Setting transform tx")
                transform.tx = videoTrack.naturalSize.height
                transform.ty = 0
            } else if rotationDegrees == 270 {
                print("Setting transform ty")
                transform.tx = 0
                transform.ty = videoTrack.naturalSize.width
            }
        }
        return transform
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        guard let key = ObserverKey(rawValue: keyPath ?? "")
        else { return }

        switch key {
        case .status:
            guard let item = object as? AVPlayerItem
            else { return }
            switch item.status {
            case .failed:
                if let eventSink = eventSink {
                    eventSink(FlutterError(code: "VideoError", message: "Failed to load video: \(item.error?.localizedDescription ?? "")", details: nil))
                }
            case .unknown:
                break
            case .readyToPlay:
                print(".readyToPlay")
                if let videoOutput = videoOutput {
                    item.add(videoOutput)
                    setupEventSinkIfReadyToPlay()
                    updatePlayingState()
                }
            @unknown default:
                break
            }

        case .loadedTimeRanges:
            guard
                let eventSink = eventSink,
                let item = object as? AVPlayerItem
            else { return }
            var values = [[NSNumber]]()
            for rangeValue in item.loadedTimeRanges {
                let range = rangeValue.timeRangeValue
                let start = CMTimeToMillis(range.start)
                values.append([NSNumber(value: start), NSNumber(value: start + CMTimeToMillis(range.duration))])
            }
            eventSink(["event" : "bufferingUpdate", "values" : values] as [String : Any])
            return

        case .presentationSize, .duration:
            guard
                let item = object as? AVPlayerItem,
                item.status == .readyToPlay
            else { return }
            
            // Due to an apparent bug, when the player item is ready, it still may not have determined
            // its presentation size or duration. When these properties are finally set, re-check if
            // all required properties and instantiate the event sink if it is not already set up.
            setupEventSinkIfReadyToPlay()
            updatePlayingState()
            return

        case .playbackLikelyToKeepUp:
            guard
                let eventSink = eventSink,
                player.currentItem?.isPlaybackLikelyToKeepUp ?? false
            else { return }
            updatePlayingState()
            eventSink(["event" : "bufferingEnd"])

        case .playbackBufferEmpty:
            eventSink?(["event" : "bufferingStart"])

        case .playbackBufferFull:
            eventSink?(["event" : "bufferingEnd"])

        case .rate:
            // Important: Make sure to cast the object to AVPlayer when observing the rate property,
            // as it is not available in AVPlayerItem.
            eventSink?(["event" : "isPlayingStateUpdate", "isPlaying" : !player.rate.isZero as Any])
        }
    }

    func updatePlayingState() {
        print("updatePlayingState()")

        guard
            isInitialized,
            let displayLink = displayLink
        else { return }
        if isPlaying {
            player.play()
            CVDisplayLinkStart(displayLink)
        } else {
            player.pause()
            CVDisplayLinkStop(displayLink)
        }
    }

    func setupEventSinkIfReadyToPlay() {
        print("setupEventSinkIfReadyToPlay()")
        if eventSink != nil && !isInitialized {
            let size = player.currentItem?.presentationSize ?? .zero
            
            if let asset = player.currentItem?.asset {
                
                if asset.statusOfValue(forKey: "tracks", error: nil) != .loaded {
                    
                    let trackCompletionHandler: () -> Void = {
                        if asset.statusOfValue(forKey: "tracks", error: nil) != .loaded {
                            // Cancelled, or something failed.
                            return
                        }
                        // This completion block will run on an AVFoundation background queue.
                        // Hop back to the main thread to set up event sink.
                        DispatchQueue.main.async { [weak self] in
                            self?.setupEventSinkIfReadyToPlay()
                        }
                    }
                    asset.loadValuesAsynchronously(forKeys: ["tracks"], completionHandler: trackCompletionHandler)
                }
                
                let hasVideoTracks = !asset.tracks(withMediaType: .video).isEmpty
                let hasNoTracks = asset.tracks.isEmpty
                
                // The player has not yet initialized when it has no size, unless it is an audio-only track.
                // HLS m3u8 video files never load any tracks, and are also not yet initialized until they have
                // a size.
                if ((hasVideoTracks || hasNoTracks) && size == .zero) {
                    return
                }
                
                // The player may be initialized but still needs to determine the duration.
                let duration = asset.duration
                if duration == .zero {
                    return
                }
                
                print("isInitialized = true")
                
                isInitialized = true
                eventSink?([
                    "event" : "initialized",
                    "duration" : NSNumber(value: duration.seconds),
                    "width" : NSNumber(value: Double(size.width)),
                    "height" : NSNumber(value: Double(size.height))
                ] as [String : Any])
                
                //            // The player has not yet initialized.
                //            if height == .zero && width == .zero {
                //                return
                //            }
                //            // The player may be initialized but still needs to determine the duration.
                //            if duration == 0 {
                //                return
                //            }
                //
                //            isInitialized = true
                //            eventSink([
                //                "event" : "initialized",
                //                "duration" : NSNumber(value: duration),
                //                "width" : NSNumber(value: Double(width)),
                //                "height" : NSNumber(value: Double(height))
                //            ] as [String : Any])
                
            }
        }
    }

    func play() {
        print("play()")
        isPlaying = true
        updatePlayingState()
    }

    func pause() {
        print("pause()")
        isPlaying = false
        updatePlayingState()
    }

    var position: Int64 {
        return CMTimeToMillis(player.currentTime())
    }

    var duration: Int64 {
        // Note: https://openradar.appspot.com/radar?id=4968600712511488
        // `[AVPlayerItem duration]` can be `kCMTimeIndefinite`,
        // use `[[AVPlayerItem asset] duration]` instead.
        return CMTimeToMillis(player.currentItem?.asset.duration ?? CMTime.zero)
    }

    func seek(to location: Int, completionHandler: @escaping (Bool) -> Void) {
        print("seek to: \(location)")
        player.seek(to: CMTimeMake(value: Int64(location), timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: completionHandler)
        notifyIfFrameAvailable()
    }

    func setIsLooping(_ isLooping: Bool) {
        self.isLooping = isLooping
    }

    func setVolume(_ volume: Double) {
        print("setVolume: \(volume)")
        player.volume = Float(volume < 0.0 ? 0.0 : (volume > 1.0 ? 1.0 : volume))
    }

    func setPlaybackSpeed(_ speed: Double) {
        print("setPlaybackSpeed: \(speed)")
        // See https://developer.apple.com/library/archive/qa/qa1772/_index.html for
        // an explanation of these checks.
        if speed > 2.0, player.currentItem?.canPlayFastForward == false {
            if let eventSink = eventSink {
                eventSink(FlutterError(code: "VideoError", message: "Video cannot be fast-forwarded beyond 2.0x", details: nil))
            }
            return
        }

        if speed < 1.0, player.currentItem?.canPlaySlowForward == false {
            if let eventSink = eventSink {
                eventSink(FlutterError(code: "VideoError", message: "Video cannot be slow-forwarded", details: nil))
            }
            return
        }

        player.rate = Float(speed)
    }
    
    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        // Creates a memcpy of the last valid frame.
        //
        // Unlike on iOS, the macOS embedder does show the last frame when
        // we return NULL from `copyPixelBuffer`.

        guard let lastValidFrame = lastValidFrame else {
            return nil
        }

        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        CVPixelBufferLockBaseAddress(lastValidFrame, .readOnly)
        let bufferWidth = Int(CVPixelBufferGetWidth(lastValidFrame))
        let bufferHeight = Int(CVPixelBufferGetHeight(lastValidFrame))

        let bytesPerRow = CVPixelBufferGetBytesPerRow(lastValidFrame)
        guard let baseAddress = CVPixelBufferGetBaseAddress(lastValidFrame) else {
            NSLog("----> baseadress is NULL")
            return nil
        }

        let pixBuffAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [AnyHashable: Any],
            kCVPixelBufferOpenGLCompatibilityKey as String: true,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]

        var pixelBufferCopy: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, bufferWidth, bufferHeight, kCVPixelFormatType_32BGRA, pixBuffAttributes as CFDictionary, &pixelBufferCopy)
        CVPixelBufferLockBaseAddress(pixelBufferCopy!, [])
        let copyBaseAddress = CVPixelBufferGetBaseAddress(pixelBufferCopy!)
        memcpy(copyBaseAddress, baseAddress, bufferHeight * bytesPerRow)

        CVPixelBufferUnlockBaseAddress(lastValidFrame, .readOnly)
        CVPixelBufferUnlockBaseAddress(pixelBufferCopy!, [])
        if let pixelBufferCopy = pixelBufferCopy {
            return Unmanaged.passRetained(pixelBufferCopy)
        }
        return nil
    }

    func onTextureUnregistered(_ texture: FlutterTexture) {
        print("onTextureUnregistered")
        DispatchQueue.main.async {
            self.dispose()
        }
    }
    
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        print("onCancel")
        eventSink = nil
        return nil
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        print("onListen withArguments: \(arguments)")
        self.eventSink = events
        // TODO(@recastrodiaz): remove the line below when the race condition is
        // resolved: https://github.com/flutter/flutter/issues/21483 This line
        // ensures the 'initialized' event is sent when the event
        // 'AVPlayerItemStatusReadyToPlay' fires before _eventSink is set (this
        // function onListenWithArguments is called)
        setupEventSinkIfReadyToPlay()
        return nil
    }

    /// This method allows you to dispose without touching the event channel.  This
    /// is useful for the case where the Engine is in the process of deconstruction
    /// so the channel is going to die or is already dead.
    func disposeSansEventChannel() {
        print("disposeSansEventChannel()")
        disposed = true
        stopDisplayLink()
        if let currentItem = player.currentItem {
            currentItem.removeObserver(self, forKeyPath: "status")
            currentItem.removeObserver(self, forKeyPath: "loadedTimeRanges")
            currentItem.removeObserver(self, forKeyPath: "presentationSize")
            currentItem.removeObserver(self, forKeyPath: "duration")
            currentItem.removeObserver(self, forKeyPath: "playbackLikelyToKeepUp")
            currentItem.removeObserver(self, forKeyPath: "playbackBufferEmpty")
            currentItem.removeObserver(self, forKeyPath: "playbackBufferFull")
        }
        player.replaceCurrentItem(with: nil)
        NotificationCenter.default.removeObserver(self)
    }
    

    func dispose() {
        print("dispose()")
        disposeSansEventChannel()
        eventChannel?.setStreamHandler(nil)
    }

}
