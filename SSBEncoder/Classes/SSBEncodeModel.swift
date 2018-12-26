//
//  SSBEncodeModel.swift
//  SSBEncoder
//
//  Created by Jiang,Zhenhua on 2018/12/18.
//

import Foundation

@objcMembers open class SSBFrame: NSObject {
    public var timestamp: Int64 = 0
    public var data: Data?
    /// flv或者rtmp包头
    public var header: Data?
}

@objcMembers open class SSBVideoFrame: SSBFrame {
    public var isKeyFrame = false
    public var sps: Data?
    public var pps: Data?
}

@objcMembers open class SSBAudioFrame: SSBFrame {
    public var audioInfo: Data?
}
