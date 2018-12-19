//
//  SSBConfiguration.swift
//  SSBEncoder
//
//  Created by Jiang,Zhenhua on 2018/12/18.
//

import Foundation

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
    
    fileprivate var quality: AudioQuality
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
        self.quality = quality
        numberOfChannels = 2
        sampleRate = quality.sampleRate
        audioBitRate = quality.bitRate(numberOfChannels)
        super.init()
    }
    
    public required init?(coder aDecoder: NSCoder) {
        numberOfChannels = aDecoder.decodeInteger(forKey: NSStringFromSelector(#selector(getter: numberOfChannels)))
        sampleRate = .init(rawValue: aDecoder.decodeInteger(forKey: NSStringFromSelector(#selector(getter: sampleRate))))
        audioBitRate = .init(rawValue: aDecoder.decodeInteger(forKey: NSStringFromSelector(#selector(getter: audioBitRate))))
        quality = .init(sampleRate: sampleRate)
        super.init()
    }
    
    public func encode(with aCoder: NSCoder) {
        aCoder.encode(numberOfChannels, forKey: NSStringFromSelector(#selector(getter: numberOfChannels)))
        aCoder.encode(sampleRate.rawValue, forKey: NSStringFromSelector(#selector(getter: sampleRate)))
        aCoder.encode(audioBitRate.rawValue, forKey: NSStringFromSelector(#selector(getter: audioBitRate)))
        aCoder.encode(_asc, forKey: NSStringFromSelector(#selector(getter: _asc)))
    }
    
    public func copy(with zone: NSZone? = nil) -> Any {
        let instance = SSBAudioConfiguration(quality: quality)
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
}
