import Foundation
import CoreMedia

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
    
    var videoBitRate: Int {
        get {
            return currentVideoBitRate
        }
        set {
            currentVideoBitRate = newValue
            encoder?.birthRate = newValue
        }
    }
    
    init(videoStreamConfiguration configuration: SSBVideoConfiguration) {
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
