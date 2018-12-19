//
//  SSBConfiguration.swift
//  SSBEncoder
//
//  Created by Jiang,Zhenhua on 2018/12/18.
//

import UIKit
import AVFoundation

@objcMembers open class SSBAudioConfiguration: NSObject, NSCopying, NSCoding {
    
    ///  Audio Live quality（音频质量）
    @objc public enum AudioQuality: Int {
        /// 音频码率 (默认96Kbps)
        @objc public enum AudioBitRate: Int {
            /// 32Kbps 音频码率
            case low = 32000
            /// 64Kbps 音频码率
            case medium = 64000
            /// 96Kbps 音频码率
            case high = 96000
            /// 128Kbps 音频码率
            case veryHigh = 128000
            /// 默认音频码率，默认为 96Kbps
            public static var `default`: AudioBitRate { return high }
            
            public init(rawValue: Int) {
                switch rawValue {
                case AudioBitRate.low.rawValue: self = .low
                case AudioBitRate.medium.rawValue: self = .medium
                case AudioBitRate.high.rawValue: self = .high
                case AudioBitRate.veryHigh.rawValue: self = .veryHigh
                default: self = AudioBitRate.default
                }
            }
        }
        
        /// 音频采样率 (默认44.1KHz)
        @objc public enum AudioSampleRate: Int {
            /// 16KHz 采样率
            case low = 16000
            /// 44.1KHz 采样率
            case medium = 44100
            /// 48KHz 采样率
            case high = 48000
            /// 默认音频采样率，默认为 44.1KHz
            static var `default`: AudioSampleRate { return medium }
            
            public var sampleRateIndex: Int {
                switch self {
                case .low: return 8
                case .medium: return 4
                case .high: return 3
                }
            }
            
            public init(rawValue:Int) {
                switch rawValue {
                case AudioSampleRate.low.rawValue: self = .low
                case AudioSampleRate.medium.rawValue: self = .medium
                case AudioSampleRate.high.rawValue: self = .high
                default: self = AudioSampleRate.default
                }
            }
        }
        /// 低音频质量 audio sample rate: 16KHz audio bitrate: numberOfChannels 1 : 32Kbps  2 : 64Kbps
        case low = 0
        /// 中音频质量 audio sample rate: 44.1KHz audio bitrate: 96Kbps
        case medium
        /// 高音频质量 audio sample rate: 44.1MHz audio bitrate: 128Kbps
        case high
        /// 超高音频质量 audio sample rate: 48KHz, audio bitrate: 128Kbps
        case veryHigh
        
        public init(sampleRate: AudioSampleRate) {
            switch sampleRate {
            case .low: self = .low
            case .medium: self = .medium
            case .high: self = .high
            default: self = AudioQuality.default
            }
        }
        
        public var sampleRate: AudioSampleRate {
            switch self {
            case .low: return .low
            case .medium, .high: return .medium
            case .veryHigh: return .high
            }
        }
        
        public func bitRate(_ numberOfChannels: Int) -> AudioBitRate {
            switch self {
            case .medium: return .high
            case .high, .veryHigh: return .veryHigh
            case .low: return numberOfChannels == 2 ? .medium : .low
            }
        }
        
        public static var `default`: AudioQuality { return high }
    }
    
    /// 采样率
    public var sampleRate: AudioQuality.AudioSampleRate {
        didSet {
            let sampleRateIndex = CChar(sampleRate.sampleRateIndex)
            _asc[0] = CChar(0x10 | ((sampleRate.sampleRateIndex >> 1) & 0x7))
            _asc[1] = (sampleRateIndex & 0x1) << 7  | CChar(((numberOfChannels & 0xF) << 3))
        }
    }
    /// 码率
    public var audioBitRate: AudioQuality.AudioBitRate
    /// 声道数目(default 2)
    public var numberOfChannels: Int {
        didSet {
            let sampleRateIndex = CChar(sampleRate.sampleRateIndex)
            _asc[0] = CChar(0x10 | ((sampleRate.sampleRateIndex >> 1) & 0x7))
            _asc[1] = (sampleRateIndex & 0x1) << 7  | CChar(((numberOfChannels & 0xF) << 3))
        }
    }
    /// flv编码音频头 44100 为0x12 0x10
    public var asc: UnsafeMutablePointer<CChar> {
        return UnsafeMutablePointer<CChar>(&_asc)
    }
    @objc private var _asc = [CChar](repeating: 0, count: 2)
    
    public var bufferLength: Int {
        return 1024 * 2 * numberOfChannels
    }
    
    public init(quality: AudioQuality = .default) {
        numberOfChannels = 2
        sampleRate = quality.sampleRate
        audioBitRate = quality.bitRate(numberOfChannels)
        super.init()
    }
    
    public required init?(coder aDecoder: NSCoder) {
        numberOfChannels = aDecoder.decodeInteger(forKey: NSStringFromSelector(#selector(getter: numberOfChannels)))
        sampleRate = .init(rawValue: aDecoder.decodeInteger(forKey: NSStringFromSelector(#selector(getter: sampleRate))))
        audioBitRate = .init(rawValue: aDecoder.decodeInteger(forKey: NSStringFromSelector(#selector(getter: audioBitRate))))
        super.init()
    }
    
    public func encode(with aCoder: NSCoder) {
        aCoder.encode(numberOfChannels, forKey: NSStringFromSelector(#selector(getter: numberOfChannels)))
        aCoder.encode(sampleRate.rawValue, forKey: NSStringFromSelector(#selector(getter: sampleRate)))
        aCoder.encode(audioBitRate.rawValue, forKey: NSStringFromSelector(#selector(getter: audioBitRate)))
        aCoder.encode(_asc, forKey: NSStringFromSelector(#selector(getter: _asc)))
    }
    
    public func copy(with zone: NSZone? = nil) -> Any {
        let instance = SSBAudioConfiguration()
        instance.numberOfChannels = numberOfChannels
        instance.audioBitRate = audioBitRate
        instance.sampleRate = sampleRate
        instance._asc = _asc
        return instance
    }
    
    open override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? SSBAudioConfiguration else {
            return false
        }
        return numberOfChannels == other.numberOfChannels
            && audioBitRate == other.audioBitRate
            && sampleRate == other.sampleRate
            && String(cString: asc) == String(cString: other.asc)
    }
    
    open override var hash: Int {
        var hasher = Hasher()
        hasher.combine(numberOfChannels)
        hasher.combine(audioBitRate)
        hasher.combine(sampleRate)
        hasher.combine(_asc)
        return hasher.finalize()
    }
    
    open override var description: String {
        return """
        <LFLiveAudioConfiguration: \(self)>
            numberOfChannels: \(numberOfChannels)
            audioSampleRate: \(sampleRate)
            audioBitrate: \(audioBitRate)
            audioHeader: \(String(cString: asc))
        """
    }
}

@objcMembers open class SSBVideoConfiguration: NSObject, NSCoding, NSCopying {
   
    /// 视频质量
    @objc public enum VideoQuality: Int {
        
        /// 视频分辨率(都是16：9 当此设备不支持当前分辨率，自动降低一级)
        @objc public enum VideoSessionPreset: Int {
            /// 低分辨率, 360x640
            case low = 0
            /// 中分辨率,540x960
            case medium
            /// 高分辨率，720x1280
            case high
            
            public var size: CGSize {
                switch self {
                case .low: return .init(width: 360, height: 640)
                case .medium: return .init(width: 540, height: 960)
                case .high: return .init(width: 720, height: 1280)
                }
            }
            
            public var avSessionPreset: AVCaptureSession.Preset {
                switch self {
                case .low: return .vga640x480
                case .medium: return .iFrame960x540
                case .high: return .iFrame1280x720
                }
            }
            
            public init?(rawValue: Int) {
                switch rawValue {
                case 0: self = .low
                case 1: self = .medium
                case 2: self = .high
                default: return nil
                }
            }
            
            mutating func support() {
                let device = AVCaptureDevice
                    .devices(for: .video)
                    .filter { $0.position == .front }
                    .first
                guard let inputCamera = device,
                    let videoInput = try? AVCaptureDeviceInput(device: inputCamera) else {
                    return
                }
                let session = AVCaptureSession()
                if session.canAddInput(videoInput) {
                    session.addInput(videoInput)
                }
                if !session.canSetSessionPreset(avSessionPreset) {
                    if self == .high {
                        self = .medium
                        if !session.canSetSessionPreset(avSessionPreset) {
                            self = .low
                        }
                    } else if self == .medium {
                        self = .low
                    }
                }
            }
        }
        
        /// 分辨率： 360 *640 帧数：15 码率：500Kps
        case low1 = 0
        /// 分辨率： 360 *640 帧数：24 码率：800Kps
        case low2
        /// 分辨率： 360 *640 帧数：30 码率：800Kps
        case low3
        /// 分辨率： 540 *960 帧数：15 码率：800Kps
        case medium1
        /// 分辨率： 540 *960 帧数：24 码率：800Kps
        case medium2
        /// 分辨率： 540 *960 帧数：30 码率：800Kps
        case medium3
        /// 分辨率： 720 *1280 帧数：15 码率：1000Kps
        case high1
        /// 分辨率： 720 *1280 帧数：24 码率：1200Kps
        case high2
        /// 分辨率： 720 *1280 帧数：30 码率：1200Kps
        case high3
        /// 默认配置
        public static var `default`: VideoQuality { return low2 }
        
        public var sessionPreset: VideoSessionPreset {
            switch self {
            case .low1, .low2, .low3: return .low
            case .medium1, .medium2, .medium3: return .medium
            case .high1, .high2, .high3: return .high
            }
        }
        
        public var frameRate: Int {
            switch self {
            case .low1, .medium1, .high1: return 15
            case .low2, .medium2, .high2: return 24
            case .low3, .medium3, .high3: return 30
            }
        }
        
        public var maxFrameRate: Int {
            return frameRate
        }
        
        public var minFrameRate: Int {
            switch self {
            case .low1, .medium1, .high1: return 10
            case .low2, .medium2, .high2: return 12
            case .low3, .medium3, .high3: return 15
            }
        }
        
        public var bitRate: Int {
            switch self {
            case .low1: return 500 * 1000
            case .low2: return 600 * 1000
            case .low3, .medium1, .medium2: return 800 * 1000
            case .medium3, .high1: return 1000 * 1000
            case .high2, .high3: return 1200 * 1000
            }
        }
        
        public var maxBitRate: Int {
            switch self {
            case .low1: return 600 * 1000
            case .low2: return 720 * 1000
            case .low3, .medium1, .medium2: return 960 * 1000
            case .medium3, .high1: return 1200 * 1000
            case .high2, .high3: return 1440 * 1000
            }
        }
        
        public var minBitRate: Int {
            switch self {
            case .low1: return 400 * 1000
            case .low2, .medium1, .medium2, .medium3, .high1, .high3: return 500 * 1000
            case .low3: return 600 * 1000
            case .high2: return 800 * 1000
            }
        }
    }
   
    private var _videoSize: CGSize
     /// 视频的分辨率，宽高务必设定为 2 的倍数，否则解码播放时可能出现绿边(这个videoSizeRespectingAspectRatio设置为YES则可能会改变)
    public var videoSize: CGSize {
        set {
            _videoSize = newValue
        }
        get {
            return isVideoSizeRespectingAspectRatio ? aspectRatioVideoSize : _videoSize
        }
    }
    /// 输出图像是否等比例,默认为NO
    public var isVideoSizeRespectingAspectRatio = false
    /// 自动旋转(这里只支持 left 变 right  portrait 变 portraitUpsideDown)
    public var isAutorotate = false
    /// 视频的帧率，即 fps
    public var videoFrameRate: Int
    
    private var _videoMaxFrameRate: Int
    /// 视频的最大帧率，即 fps
    public var videoMaxFrameRate: Int {
        set {
            guard newValue > _videoMaxFrameRate else {
                return
            }
            _videoMaxFrameRate = newValue
        }
        get {
            return _videoMaxFrameRate
        }
    }
    private var _videoMinFrameRate: Int
    /// 视频的最小帧率，即 fps
    public var videoMinFrameRate: Int {
        set {
            guard newValue < _videoMinFrameRate else {
                return
            }
            _videoMinFrameRate = newValue
        }
        get {
            return _videoMinFrameRate
        }
    }
    /// 最大关键帧间隔，可设定为 fps 的2倍，影响一个 gop 的大小
    public var videoMaxKeyframeInterval: Int
    /// 视频的最大码率，单位是 bps
    public var videoBitRate: Int
    
    private var _videoMaxBitRate: Int
    /// 视频的最大码率，单位是 bps
    public var videoMaxBitRate: Int {
        set {
            guard newValue > _videoMaxBitRate else {
                return
            }
            _videoMaxBitRate = newValue
        }
        get {
            return _videoMaxBitRate
        }
    }
    private var _videoMinBitRate: Int
    /// 视频的最小码率，单位是 bps
    public var videoMinBitRate: Int {
        set {
            guard newValue < _videoMinBitRate else {
                return
            }
            _videoMinBitRate = newValue
        }
        get {
            return _videoMinBitRate
        }
    }
    /// 是否是横屏
    public var isLandscape: Bool {
        return outputImageOrientation == .landscapeLeft || outputImageOrientation == .landscapeRight
    }
    /// sde3分辨率
    public var avSessionPresset: AVCaptureSession.Preset {
        return sessionPreset.avSessionPreset
    }
    /// 分辨率
    public var sessionPreset: VideoQuality.VideoSessionPreset {
        didSet {
            sessionPreset.support()
        }
    }
    /// 视频输出方向
    public var outputImageOrientation: UIInterfaceOrientation
    
    private var captureOutVideoSize: CGSize {
        let videoSize = sessionPreset.size
        return isLandscape ? CGSize(width: videoSize.height, height: videoSize.width) : videoSize
    }
    
    private var aspectRatioVideoSize: CGSize {
        let size = AVMakeRect(aspectRatio: captureOutVideoSize,
                              insideRect: .init(origin: .zero, size: videoSize)).size
        var width = ceil(size.width)
        var height = ceil(size.height)
        if width.truncatingRemainder(dividingBy: 2) != 0 {
            width -= 1
        }
        if height.truncatingRemainder(dividingBy: 2) != 0 {
            height -= 1
        }
        return .init(width: width, height: height)
    }
    
    public init(quality: VideoQuality = .default, outputImageOrientation: UIInterfaceOrientation = .portrait) {
        sessionPreset = quality.sessionPreset
        videoFrameRate = quality.frameRate
        _videoMaxFrameRate = quality.maxFrameRate
        _videoMinFrameRate = quality.minFrameRate
        videoBitRate = quality.bitRate
        _videoMaxBitRate = quality.maxBitRate
        _videoMinBitRate = quality.minBitRate
        videoMaxKeyframeInterval = videoFrameRate * 2
        self.outputImageOrientation = outputImageOrientation
        _videoSize = sessionPreset.size
        super.init()
        if isLandscape {
            videoSize = CGSize(width: videoSize.height, height: videoSize.width)
        }
    }

    public required init?(coder aDecoder: NSCoder) {
        _videoSize = aDecoder.decodeCGSize(forKey: NSStringFromSelector(#selector(getter: videoSize)))
        videoFrameRate = aDecoder.decodeInteger(forKey: NSStringFromSelector(#selector(getter: videoFrameRate)))
        _videoMaxFrameRate = aDecoder.decodeInteger(forKey: NSStringFromSelector(#selector(getter: videoMaxFrameRate)))
        _videoMinFrameRate = aDecoder.decodeInteger(forKey: NSStringFromSelector(#selector(getter: videoMinFrameRate)))
        videoMaxKeyframeInterval = aDecoder.decodeInteger(forKey: NSStringFromSelector(#selector(getter: videoMaxKeyframeInterval)))
        videoBitRate = aDecoder.decodeInteger(forKey: NSStringFromSelector(#selector(getter: videoBitRate)))
        _videoMaxBitRate = aDecoder.decodeInteger(forKey: NSStringFromSelector(#selector(getter: videoMaxBitRate)))
        _videoMinBitRate = aDecoder.decodeInteger(forKey: NSStringFromSelector(#selector(getter: videoMinBitRate)))
        sessionPreset = VideoQuality.VideoSessionPreset(rawValue: aDecoder.decodeInteger(forKey: NSStringFromSelector(#selector(getter: sessionPreset)))) ?? .low
        outputImageOrientation = UIInterfaceOrientation(rawValue: aDecoder.decodeInteger(forKey: NSStringFromSelector(#selector(getter: outputImageOrientation)))) ?? .portrait
        isVideoSizeRespectingAspectRatio = aDecoder.decodeBool(forKey: NSStringFromSelector(#selector(getter: isVideoSizeRespectingAspectRatio)))
        isAutorotate = aDecoder.decodeBool(forKey: NSStringFromSelector(#selector(getter: isAutorotate)))
        super.init()
    }
    
    public func encode(with aCoder: NSCoder) {
        aCoder.encode(_videoSize, forKey: NSStringFromSelector(#selector(getter: videoSize)))
        aCoder.encode(videoFrameRate, forKey: NSStringFromSelector(#selector(getter: videoFrameRate)))
        aCoder.encode(_videoMaxFrameRate, forKey: NSStringFromSelector(#selector(getter: videoMaxFrameRate)))
        aCoder.encode(_videoMinFrameRate, forKey: NSStringFromSelector(#selector(getter: videoMinFrameRate)))
        aCoder.encode(videoMaxKeyframeInterval, forKey: NSStringFromSelector(#selector(getter: videoMaxKeyframeInterval)))
        aCoder.encode(videoBitRate, forKey: NSStringFromSelector(#selector(getter: videoBitRate)))
        aCoder.encode(_videoMaxBitRate, forKey: NSStringFromSelector(#selector(getter: videoMaxBitRate)))
        aCoder.encode(_videoMinBitRate, forKey: NSStringFromSelector(#selector(getter: videoMinBitRate)))
        aCoder.encode(sessionPreset.rawValue, forKey: NSStringFromSelector(#selector(getter: sessionPreset)))
        aCoder.encode(outputImageOrientation.rawValue, forKey: NSStringFromSelector(#selector(getter: outputImageOrientation)))
        aCoder.encode(isVideoSizeRespectingAspectRatio, forKey: NSStringFromSelector(#selector(getter: isVideoSizeRespectingAspectRatio)))
        aCoder.encode(isAutorotate, forKey: NSStringFromSelector(#selector(getter: isAutorotate)))
    }
    
    public func copy(with zone: NSZone? = nil) -> Any {
        let other = SSBVideoConfiguration()
        other.videoBitRate = videoBitRate
        other.videoSize = videoSize
        other.videoFrameRate = videoFrameRate
        other.videoMaxFrameRate = videoMaxFrameRate
        other.videoMinFrameRate = videoMinFrameRate
        other.videoMaxKeyframeInterval = videoMaxKeyframeInterval
        other.videoMaxBitRate = videoMaxBitRate
        other.videoMinBitRate = videoMinBitRate
        other.sessionPreset = sessionPreset
        other.outputImageOrientation = outputImageOrientation
        other.isAutorotate = isAutorotate
        other.isVideoSizeRespectingAspectRatio = isVideoSizeRespectingAspectRatio
        return other
    }
    
    open override var hash: Int {
        var hasher = Hasher()
        hasher.combine(NSValue(cgSize: videoSize))
        hasher.combine(videoFrameRate)
        hasher.combine(videoMaxFrameRate)
        hasher.combine(videoMinFrameRate)
        hasher.combine(videoMaxKeyframeInterval)
        hasher.combine(videoBitRate)
        hasher.combine(videoMaxBitRate)
        hasher.combine(videoMinBitRate)
        hasher.combine(avSessionPresset)
        hasher.combine(sessionPreset)
        hasher.combine(outputImageOrientation)
        hasher.combine(isAutorotate)
        hasher.combine(isVideoSizeRespectingAspectRatio)
        return hasher.finalize()
    }
    
    open override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? SSBVideoConfiguration else {
            return false
        }
        return videoSize == other.videoSize
            && videoFrameRate == other.videoFrameRate
            && videoMaxFrameRate == other.videoMaxFrameRate
            && videoMaxKeyframeInterval == other.videoMaxKeyframeInterval
            && videoBitRate == other.videoBitRate
            && videoMaxBitRate == other.videoMaxBitRate
            && videoMinBitRate == other.videoMinBitRate
            && avSessionPresset == other.avSessionPresset
            && sessionPreset == other.sessionPreset
            && outputImageOrientation == other.outputImageOrientation
            && isAutorotate == other.isAutorotate
            && isVideoSizeRespectingAspectRatio == other.isVideoSizeRespectingAspectRatio
    }
    
    open override var description: String {
        return """
        <LFLiveVideoConfiguration: \(self)>
            videoSize: \(videoSize)
            videoSizeRespectingAspectRatio: \(isVideoSizeRespectingAspectRatio)
            videoFrameRate: \(videoFrameRate)
            videoMaxFrameRate: \(videoMaxFrameRate)
            videoMinFrameRate: \(videoMinFrameRate)
            videoMaxKeyframeInterval: \(videoMaxKeyframeInterval)
            videoBitRate: \(videoBitRate)
            videoMaxBitRate: \(videoMaxBitRate)
            videoMinBitRate: \(videoMinBitRate)
            avSessionPreset: \(avSessionPresset)
            sessionPreset: \(sessionPreset)
            outputImageOrientation: \(outputImageOrientation)
            autorotate: \(isAutorotate)
        """
    }
}
