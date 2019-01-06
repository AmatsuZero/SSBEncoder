import Foundation
import CoreMedia
import VideoToolbox

private func getFilePath(by fileName: String) -> String {
    return NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first!.appending("/\(fileName)")
}

@objc public protocol SSBVideoEncoding: NSObjectProtocol {
    @objc func encode(videoData pixelBuffer: CVPixelBuffer, timeStamp: Int64)
}

/// 编码器抽象的接口
@objc public protocol SSBAudioEncoding: NSObjectProtocol {
    @objc func encode(audioData: Data?, timeStamp: Int64)
    @objc func stop()
    @objc init(audioStreamConfiguration: SSBLiveAudioConfiguration)
    @objc optional func setDelagate(_ delegate: SSBAudioEncodingDelegate)
    @objc optional func adts(data channel: Int, rawDataLength length: Int) -> Data
}

/// 编码器编码后回调
@objc public protocol SSBAudioEncodingDelegate: NSObjectProtocol {
    @objc func encoder(_ encoder: SSBAudioEncoding, audioFrame: SSBAudioFrame)
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
    private var enabledWriteVideoFile = true
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
    var hasEnabledWriteVideoFile = true
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
        guard VTCompressionSessionCreate(nil, Int32(configuration.videoSize.width), Int32(configuration.videoSize.height),
                                                kCMVideoCodecType_H264, nil, nil, nil,
                                                VideoCompressionOutputCallback,
                                                UnsafeMutableRawPointer(mutating: bridge(obj: self)),
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

/// AudioConverterFillComplexBuffer 编码过程中，会要求这个函数来填充输入数据，也就是原始PCM数据
private func inputDataProc(inConverter: AudioConverterRef,
                   ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
                   ioData: UnsafeMutablePointer<AudioBufferList>,
                   outDataPacketDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
                   inUserData: UnsafeMutableRawPointer?) -> OSStatus {
    if let bufferList = inUserData?.assumingMemoryBound(to: AudioBufferList.self) {
        let ptr = UnsafeMutableAudioBufferListPointer(bufferList)[0]
        var io = UnsafeMutableAudioBufferListPointer(ioData)[0]
        io.mNumberChannels = 1
        io.mData = ptr.mData
        io.mDataByteSize = ptr.mDataByteSize
    }
    return noErr
}

@objcMembers open class SSBHardwareAudioEncoder: NSObject, SSBAudioEncoding {
    
    private var fp: UnsafeMutablePointer<FILE>?
    private var enabledWriteAudioFile = true
    private var leftLength = 0
    private let leftBuf: UnsafeMutablePointer<CChar>
    private let aacBuf: UnsafeMutablePointer<CChar>
    private weak var delegate: SSBAudioEncodingDelegate?
    private let configuration: SSBLiveAudioConfiguration
    private var converter: AudioConverterRef?
    
    required public init(audioStreamConfiguration: SSBLiveAudioConfiguration) {
        configuration = audioStreamConfiguration
        leftBuf = UnsafeMutablePointer<CChar>.allocate(capacity: configuration.bufferLength)
        aacBuf = UnsafeMutablePointer<CChar>.allocate(capacity: configuration.bufferLength)
        super.init()
        #if DEBUG
        enabledWriteAudioFile = false
        initForFilePath()
        #endif
    }
    
    public func encode(audioData: Data?, timeStamp: Int64) {
        if leftLength + (audioData?.count ?? 0) >= configuration.bufferLength {
            ///<  发送
            let totalSize = leftLength + (audioData?.count ?? 0)
            let encodeCount = totalSize / configuration.bufferLength
            
            let totalBuf = malloc(totalSize)
            let p = totalBuf
            
            memset(totalBuf, Int32(totalSize), 0)
            memcpy(totalBuf, leftBuf, leftLength)
            memcpy(totalBuf?.advanced(by: leftLength), (audioData as NSData?)?.bytes, audioData?.count ?? 0)
            
            for _ in 0..<encodeCount {
                encode(buffer: p, timeStamp: timeStamp)
                _ = p?.advanced(by: configuration.bufferLength)
            }
            
            leftLength = totalSize % configuration.bufferLength
            memset(leftBuf, 0, configuration.bufferLength)
            memcpy(leftBuf, totalBuf?.advanced(by: totalSize - leftLength), leftLength)
            
            free(totalBuf)
        } else {
            ///< 积累
            memcpy(leftBuf.advanced(by: leftLength), (audioData as NSData?)?.bytes, audioData?.count ?? 0)
            leftLength += audioData?.count ?? 0
        }
    }
    
    public func stop() {
        
    }
    
    private func initForFilePath() {
        let path = getFilePath(by: "IOSCamDemo_HW.aac")
        fp = fopen(path.cString(using: .utf8), "wb".cString(using: .utf8))
    }
    
    public func setDelagate(_ delegate: SSBAudioEncodingDelegate) {
        self.delegate = delegate
    }
    
    func createAudioConvert() -> Bool {
        guard converter == nil else {
            return true
        }
        
        var inputFormat = AudioStreamBasicDescription()
        inputFormat.mSampleRate = Float64(configuration.sampleRate.rawValue)
        inputFormat.mFormatID = kAudioFormatLinearPCM
        inputFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger
            | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked
        inputFormat.mChannelsPerFrame = UInt32(configuration.numberOfChannels)
        inputFormat.mFramesPerPacket = 1
        inputFormat.mBitsPerChannel = 16
        inputFormat.mBytesPerFrame = inputFormat.mBitsPerChannel / 8 * inputFormat.mChannelsPerFrame
        inputFormat.mBytesPerPacket = inputFormat.mBytesPerFrame * inputFormat.mBytesPerPacket
        // 这里开始是输出音频格式
        var outputFormat = AudioStreamBasicDescription()
        memset(&outputFormat, 0, MemoryLayout.size(ofValue: outputFormat))
        outputFormat.mSampleRate = inputFormat.mSampleRate // 采样率保持一致
        outputFormat.mFormatID = kAudioFormatMPEG4AAC // AAC编码 kAudioFormatMPEG4AAC kAudioFormatMPEG4AAC_HE_V2
        outputFormat.mChannelsPerFrame = UInt32(configuration.numberOfChannels)
        outputFormat.mFramesPerPacket = 1024 // AAC一帧是1024个字节
        
        let subType = kAudioFormatMPEG4AAC
        let requestedCodecs = [
            AudioClassDescription(mType:kAudioEncoderComponentType, mSubType: subType, mManufacturer: kAppleSoftwareAudioCodecManufacturer),
            AudioClassDescription(mType:kAudioEncoderComponentType, mSubType: subType, mManufacturer: kAppleSoftwareAudioCodecManufacturer)
        ]
        let result = AudioConverterNewSpecific(&inputFormat, &outputFormat, 2, requestedCodecs, &converter)
        var outputBitrate = configuration.audioBitRate
        let propSize = MemoryLayout.size(ofValue: outputBitrate)
        
        if result == noErr, let converter = converter {
            AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, UInt32(propSize), &outputBitrate)
        }
        return true
    }
    
    /**
     *  Add ADTS header at the beginning of each and every AAC packet.
     *  This is needed as MediaCodec encoder generates a packet of raw
     *  AAC data.
     *
     *  Note the packetLen must count in the ADTS header itself.
     *  See: http://wiki.multimedia.cx/index.php?title=ADTS
     *  Also: http://wiki.multimedia.cx/index.php?title=MPEG-4_Audio#Channel_Configurations
     **/
    public func adts(data channel: Int, rawDataLength length: Int) -> Data {
        let adtsLength = 7
        var packet = [Int](repeating: 0, count: adtsLength)
        // Variables Recycled by addADTStoPacket
        let profile = 2  //AAC LC
        //39=MediaCodecInfo.CodecProfileLevel.AACObjectELD;
        let freqIdx = configuration.sampleRate.sampleRateIndex
        let chanCfg = channel //MPEG-4 Audio Channel Configuration. 1 Channel front-center
        let fullLength = adtsLength + length
        // fill in ADTS data
        packet[0] = 0xff // 11111111     = syncword
        packet[1] = 0xf9 // 1111 1 00 1  = syncword MPEG-2 Layer CRC
        packet[2] = ((profile - 1) << 6) + (freqIdx << 2) + (chanCfg >> 2)
        packet[3] = ((chanCfg & 3) << 6) + (fullLength >> 11)
        packet[4] = (fullLength & 0x7ff) >> 3
        packet[5] = ((fullLength & 7) << 5) + 0x1F
        packet[6] = 0xfc
        return Data(bytes: &packet, count: adtsLength)
    }
    
    private func encode(buffer: UnsafeMutableRawPointer?, timeStamp: Int64) {
        var inBuffer = AudioBuffer()
        inBuffer.mNumberChannels = 1
        inBuffer.mData = buffer
        inBuffer.mDataByteSize = UInt32(configuration.bufferLength)
        
        var buffers = AudioBufferList()
        buffers.mNumberBuffers = 1
        UnsafeMutableAudioBufferListPointer(&buffers)[0] = inBuffer
        // 初始化一个输出缓冲列表
        var outBufferList = AudioBufferList()
        outBufferList.mNumberBuffers = 1
        
        var newBuffer = inBuffer
        newBuffer.mDataByteSize = inBuffer.mDataByteSize // 设置缓冲区大小
        newBuffer.mData = UnsafeMutableRawPointer(aacBuf) // 设置AAC缓冲区
        UnsafeMutableAudioBufferListPointer(&outBufferList)[0] = newBuffer
    
        var outputDataPacketSize: UInt32 = 1
        guard let converter = converter,
            AudioConverterFillComplexBuffer(converter, inputDataProc, &buffers, &outputDataPacketSize, &outBufferList, nil) == noErr else {
            return
        }
        let audioFrame = SSBAudioFrame()
        audioFrame.timestamp = timeStamp
        audioFrame.data = Data(bytes: aacBuf, count: Int(UnsafeMutableAudioBufferListPointer(&outBufferList)[0].mDataByteSize))
        let extData = [configuration.asc[0], configuration.asc[1]]
        audioFrame.audioInfo = Data(bytes: extData, count: extData.count)
        if let delegate = delegate, delegate.responds(to: #selector(SSBAudioEncodingDelegate.encoder(_:audioFrame:))) {
            delegate.encoder(self, audioFrame: audioFrame)
        }
        if enabledWriteAudioFile {
            let adts = self.adts(data: configuration.numberOfChannels, rawDataLength: audioFrame.data?.count ?? 0)
            fwrite((adts as NSData).bytes, 1, adts.count, fp)
            fwrite((audioFrame.data as NSData?)?.bytes, 1, audioFrame.data?.count ?? 0, fp)
        }
        
    }
    
    deinit {
        leftBuf.deallocate()
        aacBuf.deallocate()
    }
}

extension Int {
    func sampleIndex() -> Int {
        switch self {
        case 96000: return 0
        case 88200: return 1
        case 64000: return 2
        case 48000: return 3
        case 44100: return 4
        case 32000: return 5
        case 24000: return 6
        case 22050: return 7
        case 16000: return 8
        case 12000: return 9
        case 11025: return 10
        case 8000: return 11
        case 7350: return 12
        default: return 15
        }
    }
}

func bridge<T : AnyObject>(obj : T) -> UnsafeRawPointer {
    return UnsafeRawPointer(Unmanaged.passUnretained(obj).toOpaque())
}

func bridge<T : AnyObject>(ptr : UnsafeRawPointer) -> T {
    return Unmanaged<T>.fromOpaque(ptr).takeUnretainedValue()
}

func bridgeRetained<T : AnyObject>(obj : T) -> UnsafeRawPointer {
    return UnsafeRawPointer(Unmanaged.passRetained(obj).toOpaque())
}

func bridgeTransfer<T : AnyObject>(ptr : UnsafeRawPointer) -> T {
    return Unmanaged<T>.fromOpaque(ptr).takeRetainedValue()
}
