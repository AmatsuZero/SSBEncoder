import Foundation
import CoreMedia

@objc public protocol SSBVideoEncoding: NSObjectProtocol {
    @objc func encode(videoData pixelBuffer: CVPixelBuffer?, timeStamp: UInt64)
}

@objc public protocol SSBVideoEncodingDelegate: NSObjectProtocol {
    @objc func video(encoder: SSBVideoEncoding?, videoFrame frame: SSBVideoFrame?)
    @objc optional var videoBitRate: Int { get set }
    @objc init(videoStreamConfiguration: SSBVideoConfiguration)
    @objc optional func stop()
    @objc optional func set(delegate: SSBVideoEncodingDelegate?)
}

@objcMembers open class SSBH264VideoEncoder: NSObject, SSBVideoEncoding {
    
    public func encode(videoData pixelBuffer: CVPixelBuffer?, timeStamp: UInt64) {
        
    }
    
    public func shutdown() {
        
    }
}
