import Foundation
import CoreMedia
import VideoToolbox

private func getFilePath(by fileName: String) -> String {
    return NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first!.appending("/\(fileName)")
}

@objc public protocol SSBVideoEncoding: NSObjectProtocol {
    @objc func encode(videoData pixelBuffer: CVPixelBuffer, timeStamp: Int64)
}

@objc public protocol SSBVideoEncodingDelegate: NSObjectProtocol {
    @objc func video(encoder: SSBVideoEncoding?, videoFrame frame: SSBVideoFrame?)
    @objc optional var videoBitRate: Int { get set }
    @objc init(videoStreamConfiguration: SSBVideoConfiguration)
    @objc optional func stop()
    @objc optional func set(delegate: SSBVideoEncodingDelegate?)
}

@objcMembers open class SSBH264VideoEncoder: NSObject, SSBVideoEncoding {
    
    private var fp: UnsafeMutablePointer<FILE>?
    private var frameCount = 0
    private var enabledWriteVideoFile = false
    private let configuration: SSBVideoConfiguration
    private let sendQueue = DispatchQueue(label: "com.ssb.h264.sendframe")
    private let naluStartCode = Data(bytes:  [0x00, 0x00, 0x00, 0x01])
    private var encoder: SSBAVEncoder?
    private var spsData: Data?
    private var ppsData: Data?
    private var sei: Data?
    private var videoSPSAndPPS: Data?
    private var currentVideoBitRate = 0
    private weak var delegate: SSBVideoEncodingDelegate?
    private var orphanedFrames = [Data]()
    private var orphanedSEIFrames = [Data]()
    private var lastPTS = kCMTimeInvalid
    private let timeScale: CMTimeScale = 1000
    
    public var videoBitRate: Int {
        get {
            return currentVideoBitRate
        }
        set {
            currentVideoBitRate = newValue
            encoder?.birthRate = newValue
        }
    }
    
    public init(videoStreamConfiguration configuration: SSBVideoConfiguration) {
        self.configuration = configuration
        super.init()
        initCompressionSession()
    }
    
    private func initCompressionSession() {
        #if DEBUG
        enabledWriteVideoFile = false
        initForFilePath()
        #endif
        
        encoder = SSBAVEncoder(width: Int(configuration.videoSize.width),
                               height: Int(configuration.videoSize.height),
                               birthRate: configuration.videoBitRate)
        encoder?.encode(handler: { [weak self] (dataArray, ptsValue) -> Int in
            guard let self = self, let data = dataArray else { return 0 }
            self.write(videoFrames: data, pts: .init(value: ptsValue, timescale: self.timeScale))
            return 0
        }, onParams: { [weak self] _ -> Int in
            self?.generateSPSandPPS()
            return 0
        })
    }
    
    public func encode(videoData pixelBuffer: CVPixelBuffer, timeStamp: Int64) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .init(rawValue: 0))
        var videoInfo: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(nil, pixelBuffer, &videoInfo)
        
        let frameTime = CMTime(value: timeStamp, timescale: 1000)
        let duration = CMTime(value: 1, timescale: CMTimeScale(configuration.videoFrameRate))
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: frameTime, decodeTimeStamp: kCMTimeInvalid)
        
        var sampleBuffer: CMSampleBuffer?
        guard let videoInfoRef = videoInfo else {
            return
        }
        CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, true, nil, nil, videoInfoRef, &timing, &sampleBuffer)
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .init(rawValue: 0))
        
        frameCount += 1
    }
    
    private func add(orphanedFrames frames: [Data]) {
        frames.forEach { data in
            let idc = Int(data[0]) & 0x60
            let nalType = Int(data[0]) & 0x1f
            if idc == 0, nalType == 6 { // SEI
                self.orphanedSEIFrames.append(data)
            } else {
                self.orphanedFrames.append(data)
            }
        }
    }
    
    private func write(videoFrames frames: [Data], pts: CMTime) {
        var totalFrames = [Data]()
        if !orphanedSEIFrames.isEmpty {
            totalFrames += orphanedSEIFrames
            orphanedSEIFrames.removeAll()
        }
        totalFrames += frames
        
        var aggregateFrameData = Data()
        for data in totalFrames {
            let idc = Int(data[0]) & 0x60
            let nalType = Int(data[0]) & 0x1f
            var videoData = Data()
            
            if idc == 0, nalType == 6 {// SEI
                sei = data
                continue
            } else if nalType == 5 {// IDR
                var idrData = videoSPSAndPPS ?? Data()
                if sei != nil {
                    idrData.append(naluStartCode)
                    idrData.append(sei!)
                    sei = nil
                }
                idrData.append(naluStartCode)
                idrData.append(data)
                videoData = idrData
            } else {
                var regularData = naluStartCode
                regularData.append(data)
                videoData = regularData
            }
            
            aggregateFrameData.append(videoData)
            let videoFrame = SSBVideoFrame()
            videoFrame.data = aggregateFrameData.advanced(by: naluStartCode.count)
            videoFrame.timestamp = pts.value
            videoFrame.isKeyFrame = nalType == 5
            videoFrame.sps = spsData
            videoFrame.pps = ppsData
            if let delegate = self.delegate,
                delegate.responds(to: #selector(SSBVideoEncodingDelegate.video(encoder:videoFrame:))) {
                delegate.video(encoder: self, videoFrame: videoFrame)
            }
        }
        if enabledWriteVideoFile {
            fwrite((aggregateFrameData as NSData).bytes, 1, aggregateFrameData.count, fp)
        }
    }
    
    private func incoming(videoFrames frames: [Data], pstValue: CMTimeValue) {
        guard pstValue != 0 else {
            add(orphanedFrames: frames)
            return
        }
        
        if videoSPSAndPPS == nil {
            generateSPSandPPS()
        }
        
        let pts = CMTime(value: pstValue, timescale: timeScale)
        if !orphanedFrames.isEmpty {
            let ptsDiff = CMTimeSubtract(pts, lastPTS)
            let orphanedFramesCount = orphanedFrames.count
            for frame in orphanedFrames {
                let fakePTSDiff = CMTimeMultiplyByFloat64(ptsDiff, 1.0 / Double(orphanedFramesCount + 1))
                let fakePTS = CMTimeAdd(lastPTS, fakePTSDiff)
                write(videoFrames: [frame], pts: fakePTS)
            }
            orphanedFrames.removeAll()
        }
        
        write(videoFrames: frames, pts: pts)
        lastPTS = pts
    }
    
    public func shutdown() {
        encoder?.encode(handler: nil, onParams: nil)
    }
    
    private func initForFilePath() {
        let path = getFilePath(by: "IOSCamDemo.h264")
        fp = fopen(path.cString(using: .utf8), "wb".cString(using: .utf8))
    }
    
    private func generateSPSandPPS() {
        guard let config = encoder?.getConfigData()  else {
            return
        }
        let avcC = SSBNALUnit.SSBAVCCHeader(header: config.withUnsafeBytes({
            UnsafePointer<UInt8>($0)
        }), cBytes: config.count)
        guard let sps = avcC.sps,
            let pps = avcC.pps else {
            return
        }
        let seqParams = SSBNALUnit.SSBSeqParmSet()
        seqParams.parse(pnalu: sps)
        
        guard let spsBytes = sps.pStart,
            let ppsBytes = pps.pStart else {
            return
        }
        let spsData = Data(bytes: spsBytes, count: sps.length)
        let ppsData = Data(bytes: ppsBytes, count: pps.length)
        
        let data = naluStartCode
        self.spsData = Data(count: sps.length + data.count)
        self.ppsData = Data(count: pps.length + data.count)
        
        self.spsData?.append(data)
        self.spsData?.append(spsData)
        self.ppsData?.append(data)
        self.ppsData?.append(ppsData)
        
        videoSPSAndPPS = Data(count: sps.length + pps.length + data.count)
        videoSPSAndPPS?.append(data)
        videoSPSAndPPS?.append(spsData)
        videoSPSAndPPS?.append(data)
        videoSPSAndPPS?.append(ppsData)
    }
    
    func set(delegate: SSBVideoEncodingDelegate?) {
        self.delegate = delegate
    }
    
    deinit {
        shutdown()
    }
}


private func VideoCompressionOutputCallback(vtref: UnsafeMutableRawPointer?, vtfFrameRef: UnsafeMutableRawPointer?, status: OSStatus, inflags: VTEncodeInfoFlags, sample: CMSampleBuffer?) {
    guard let sampleBuffer = sample,
        let array = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true) else { return }
    
    let dic = CFArrayGetValueAtIndex(array, 0) as! CFDictionary
    var key = kCMSampleAttachmentKey_NotSync
    let isKeyFrame = !CFDictionaryContainsKey(dic, withUnsafePointer(to: &key, { UnsafeRawPointer($0) }))
    
    guard let timeStamp = vtfFrameRef?.assumingMemoryBound(to: Int64.self).pointee,
        let videoEncoder = vtref?.assumingMemoryBound(to: SSBHardwareVideoEncoder.self).pointee,
        status == noErr else {
        return
    }
    
    if isKeyFrame, videoEncoder.sps == nil,
        let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
        var sparameterSetSize = 0
        var sparamenterSetCount = 0
        if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 0, nil, &sparameterSetSize, &sparamenterSetCount, nil) == noErr {
            let sparameterSet = UnsafeMutablePointer<UnsafePointer<UInt8>?>.allocate(capacity: sparameterSetSize)
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 0, sparameterSet, nil, nil, nil)
            
            var pparameterSetSize = 0
            var pparameterSetCount = 0
            
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 1, nil, &pparameterSetSize, &pparameterSetCount, nil) == noErr {
                let pparameterSet = UnsafeMutablePointer<UnsafePointer<UInt8>?>.allocate(capacity: pparameterSetSize)
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 1, pparameterSet, nil, nil, nil)
                
                videoEncoder.sps = Data(bytes: sparameterSet, count: sparameterSetSize)
                videoEncoder.pps = Data(bytes: pparameterSet, count: pparameterSetSize)
                
                if videoEncoder.hasEnabledWriteVideoFile,
                    let sps = videoEncoder.sps,
                    let pps = videoEncoder.pps {
                    var data = Data()
                    let header = Data(bytes: [0x00, 0x00, 0x00, 0x01])
                    data.append(header)
                    data.append(sps)
                    data.append(header)
                    data.append(pps)
                    fwrite((data as NSData).bytes, 1, data.count, videoEncoder.fp)
                }
            }
        }
    }
    
    var length = 0
    var totalLength = 0
    
    guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
        CMBlockBufferGetDataPointer(dataBuffer, 0, &length, &totalLength, nil) == noErr else {
        return
    }
   
    let dataPointer = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: totalLength)
    CMBlockBufferGetDataPointer(dataBuffer, 0, nil, nil, dataPointer)
    
    var bufferOffset = 0
    let AVCCHeaderLength = 4
    
    while bufferOffset < totalLength - AVCCHeaderLength {
        // Read the NAL unit length
        var nalUnitLength: UInt32 = 0
        memcpy(&nalUnitLength, dataPointer.advanced(by: bufferOffset), AVCCHeaderLength)
        
        nalUnitLength =  CFSwapInt32BigToHost(nalUnitLength)
        
        let videoFrame = SSBVideoFrame()
        videoFrame.timestamp = timeStamp
        videoFrame.data = Data(bytes: dataPointer.advanced(by: bufferOffset + AVCCHeaderLength),
                               count: Int(nalUnitLength))
        videoFrame.isKeyFrame = isKeyFrame
        videoFrame.sps = videoEncoder.sps
        videoFrame.pps = videoEncoder.pps
        
        if let delegate = videoEncoder.delegate,
            delegate.responds(to: #selector(SSBVideoEncodingDelegate.video(encoder:videoFrame:))) {
            delegate.video(encoder: videoEncoder, videoFrame: videoFrame)
        }
        
        if videoEncoder.hasEnabledWriteVideoFile,
            let extra = videoFrame.data {
            var data = Data()
            let header = Data(bytes: isKeyFrame ? [0x00, 0x00, 0x00, 0x01] : [0x00, 0x00, 0x01])
            data.append(header)
            data.append(extra)
            
            fwrite((data as NSData).bytes, 1, data.count, videoEncoder.fp)
        }
        
        bufferOffset += AVCCHeaderLength + Int(nalUnitLength)
    }
}

@objcMembers open class SSBHardwareVideoEncoder: NSObject, SSBVideoEncoding {
    
    private var compressionSession: VTCompressionSession?
    private var frameCount = 0
    var sps: Data?
    var pps: Data?
    var fp: UnsafeMutablePointer<FILE>?
    var hasEnabledWriteVideoFile = false
    weak var delegate: SSBVideoEncodingDelegate?
    private var currentVideoBitrate = 0
    private var isBackground = false
    private let configuration: SSBVideoConfiguration
    
    public var videoBitRate: Int {
        set {
            guard !isBackground, let compressionSession = self.compressionSession else { return }
            VTSessionSetProperty(compressionSession, kVTCompressionPropertyKey_AverageBitRate, newValue as CFTypeRef)
            VTSessionSetProperty(compressionSession, kVTCompressionPropertyKey_DataRateLimits, [Float(newValue) * 1.5 / 8, 1] as CFArray)
            currentVideoBitrate = newValue
        }
        
        get {
            return currentVideoBitrate
        }
    }
    
    public init(videoStreamConfiguration configuration: SSBVideoConfiguration) {
        self.configuration = configuration
        super.init()
        resetCompressionSession()
        NotificationCenter.default.addObserver(self, selector: #selector(SSBHardwareVideoEncoder.willEnterBackground(notification:)),
                                               name:.UIApplicationWillResignActive,
                                               object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(SSBHardwareVideoEncoder.willEnterForeground(notification:)),
                                               name: .UIApplicationDidBecomeActive,
                                               object: nil)
        #if DEBUG
        hasEnabledWriteVideoFile = false
        initForFilePath()
        #endif
    }
    
    public func encode(videoData pixelBuffer: CVPixelBuffer, timeStamp: Int64) {
        guard !isBackground, let compressionSession = self.compressionSession else { return }
        frameCount += 1
        let presentationTimeStamp = CMTimeMake(Int64(frameCount), Int32(configuration.videoFrameRate))
        var flags = VTEncodeInfoFlags()
        let duration = CMTimeMake(1, Int32(configuration.videoFrameRate))
        
        var properties = [String: Any]()
        if frameCount % configuration.videoMaxKeyframeInterval == 0 {
            properties[kVTEncodeFrameOptionKey_ForceKeyFrame as String] = true
        }
        
        var timeNumber = timeStamp
        if VTCompressionSessionEncodeFrame(compressionSession, pixelBuffer, presentationTimeStamp,
                                           duration, properties as CFDictionary, &timeNumber, &flags) != noErr {
            resetCompressionSession()
        }
    }
    
    public func stop() {
        if let compressionSession = self.compressionSession {
            VTCompressionSessionCompleteFrames(compressionSession, kCMTimeIndefinite)
        }
    }
    
    public func set(delegate: SSBVideoEncodingDelegate?) {
        self.delegate = delegate
    }
    
    private func resetCompressionSession() {
        if let compressionSession = self.compressionSession {
            VTCompressionSessionCompleteFrames(compressionSession, kCMTimeInvalid)
            VTCompressionSessionInvalidate(compressionSession)
            self.compressionSession = nil
        }
        var mySelf = self
        guard VTCompressionSessionCreate(nil, Int32(configuration.videoSize.width), Int32(configuration.videoSize.height),
                                                kCMVideoCodecType_H264, nil, nil, nil,
                                                VideoCompressionOutputCallback,
                                                withUnsafeMutablePointer(to: &mySelf, { UnsafeMutableRawPointer($0)}),
                                                &compressionSession) == noErr,
            let compressionSession = self.compressionSession else { return }
        
        currentVideoBitrate = configuration.videoBitRate
        VTSessionSetProperty(compressionSession, kVTCompressionPropertyKey_MaxKeyFrameInterval, configuration.videoMaxKeyframeInterval as CFTypeRef)
        VTSessionSetProperty(compressionSession, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, (configuration.videoMaxKeyframeInterval / configuration.videoFrameRate) as CFTypeRef)
        VTSessionSetProperty(compressionSession, kVTCompressionPropertyKey_ExpectedFrameRate, configuration.videoFrameRate as CFTypeRef)
        VTSessionSetProperty(compressionSession, kVTCompressionPropertyKey_AverageBitRate, configuration.videoBitRate as CFTypeRef)
        let limit: [Float] = [Float(configuration.videoBitRate) * 1.5 / 8, 1]
        VTSessionSetProperty(compressionSession, kVTCompressionPropertyKey_DataRateLimits, limit as CFArray)
        VTSessionSetProperty(compressionSession, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        VTSessionSetProperty(compressionSession, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(compressionSession, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanTrue)
        VTSessionSetProperty(compressionSession, kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CABAC)
        VTCompressionSessionPrepareToEncodeFrames(compressionSession)
    }
    
    private func initForFilePath() {
        let path = getFilePath(by: "IOSCamDemo.h264")
        fp = fopen(path.cString(using: .utf8), "wb".cString(using: .utf8))
    }
    
    func willEnterBackground(notification: Notification) {
        isBackground = true
    }
    
    func willEnterForeground(notification: Notification) {
        resetCompressionSession()
        isBackground = false
    }
    
    deinit {
        if let compressionSession = self.compressionSession {
            VTCompressionSessionCompleteFrames(compressionSession, kCMTimeInvalid)
            VTCompressionSessionInvalidate(compressionSession)
            self.compressionSession = nil
        }
        NotificationCenter.default.removeObserver(self)
    }
}
