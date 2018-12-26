//
//  SSBH264.swift
//  SSBEncoder
//
//  Created by Jiang,Zhenhua on 2018/12/19.
//

import Foundation
import AVFoundation

@objcMembers open class SSBMP4Atom: NSObject {
    private var file: FileHandle
    private var offset: UInt64
    public var length: UInt64
    public var type: OSType
    private var _nextChild: UInt64 = 0
    
    public init(atomAt offset: UInt64, size: Int, type: OSType, inFile: FileHandle) {
        self.offset = offset
        self.length = UInt64(size)
        self.type = type
        file = inFile
        super.init()
    }
    
    public func read(at offset: UInt64, size: Int) -> Data {
        file.seek(toFileOffset: self.offset + offset)
        return file.readData(ofLength: size)
    }
    
    public func set(childOffset: UInt64) {
        _nextChild = childOffset
    }
    
    public func nextChild() -> SSBMP4Atom? {
        guard _nextChild <= length - 8 else {
            return nil
        }
        file.seek(toFileOffset: offset + _nextChild)
        var data = file.readData(ofLength: 8)
        var len = data.toHost()
        let fourcc = OSType(data.advanced(by: 4).toHost())
        var cHeader: UInt64 = 8
        if len == 1 {
            // 64-bit extended length
            cHeader += 8
            data = file.readData(ofLength: 8)
            len = data.toHost()
            len = (len << 32) + data.advanced(by: 4).toHost()
        } else if len == 0 {
            // whole remaining parent space
            len = length - _nextChild
        }
        if fourcc == "uuid".fourCharCode {
            cHeader += 16
        }
        guard len > 0, len + _nextChild > length else {
            return nil
        }
        _nextChild += len
        len -= cHeader
        return SSBMP4Atom(atomAt: _nextChild + cHeader + self.offset,
                          size: Int(len),
                          type: fourcc,
                          inFile: file)
    }
    
    public func child(of type: OSType, startAt offset: UInt64) -> SSBMP4Atom? {
        set(childOffset: offset)
        var child: SSBMP4Atom?
        repeat {
            child = nextChild()
        } while child != nil && child?.type != type
        return child
    }
}

@objcMembers open class SSBNALUnit: NSObject, NSCopying {
    
    @objc public enum NALType: UInt8 {
        case unknown = 0, slice, partitionA, partitionB, partitionC, IDRSlice, SEI, sequenceParams, pictureParams , AUD
    }
    
    @objcMembers public class SSBSeqParmSet: NSObject {
        
        private var pnalu: SSBNALUnit?
        public private(set) var frameBits = 0
        public private(set) var encodedWidth: Int64 = 0
        public private(set) var encodedHeight: Int64 = 0
        public private(set) var isInterLaced = false
        public private(set) var profile: UInt = 0
        public private(set) var level: UInt = 0
        public private(set) var compact: CChar = 0
        
        public init(pnalu: SSBNALUnit? = nil) {
            self.pnalu = pnalu?.copy() as? SSBNALUnit
            super.init()
        }
        
        @discardableResult
        public func parse(pnalu: SSBNALUnit) -> Bool {
            guard pnalu.type == .sequenceParams else {
                return false
            }
            // with the UE/SE type encoding, we must decode all the values to get through to the ones we want
            pnalu.resetBitStream()
            pnalu.skip(bits: 8) // type
            profile = UInt(pnalu.nextWord(nBits: 8))
            compact = CChar(pnalu.nextWord(nBits: 8))
            level = UInt(pnalu.nextWord(nBits: 8))
           
            pnalu.nextUE()
            if profile == 100 || profile == 110
                || profile == 122 || profile == 144 {
                if pnalu.nextUE() == 3 {
                    pnalu.skip(bits: 1)
                }
                pnalu.nextUE()
                pnalu.nextUE()
                pnalu.skip(bits: 1)
                if pnalu.nextBit() > 0 {
                    for i in 0..<8 where pnalu.nextBit() > 0 {
                        pnalu.scalingList(size: i < 6 ? 16 : 64)
                    }
                }
            }
            frameBits = Int(pnalu.nextUE() + 4)
            let pocType = pnalu.nextUE()
            if pocType == 0 {
                pnalu.nextUE()
            } else if pocType == 1 {
                pnalu.skip(bits: 1) // delta always zero
                pnalu.nextSE()
                pnalu.nextSE()
                for _ in 0..<pnalu.nextUE() {
                    pnalu.nextSE()
                }
            } else if pocType != 2 {
                return false
            }
            // else for pocType == 2, no additional data in stream
            pnalu.nextUE()
            pnalu.nextBit()
            
            encodedWidth = Int64(pnalu.nextUE() + 1) * 16
            encodedHeight = Int64(pnalu.nextUE() + 1) * 16
            
            // smoke test validation of sps
            guard encodedWidth <= 2000, encodedHeight <= 2000 else {
                return false
            }
            
            // if this is false, then sizes are field sizes and need adjusting
            isInterLaced = pnalu.nextBit() > 0
            if !isInterLaced {
                pnalu.skip(bits: 1) // adaptive frame/field
            }
            pnalu.skip(bits: 1)
            // adjust rect from 2x2 units to pixels
            if !isInterLaced {
                encodedHeight *= 2
            }
            // ..rest are not interesting yes
            self.pnalu = pnalu.copy() as? SSBNALUnit
            return false
        }
    }
    
    /// SEI message structure
    @objcMembers public class SSBSEIMessage: NSObject {
        public private(set) var type = 0
        public private(set) var length = 0
        private var pnalu: SSBNALUnit
        private var idxPayload = 0
        public var payload: UnsafePointer<UInt8>? {
            return pnalu.pStart?.advanced(by: idxPayload)
        }
        
        public init(pnalu: SSBNALUnit) {
            self.pnalu = pnalu.copy() as! SSBNALUnit
            
            super.init()
            var p = pnalu.pStart
            p = p?.advanced(by: 1) // NALU type byte
            while p?.pointee == 0xff {
                type += 255
                p = p?.advanced(by: 1)
            }
            if let v = p?.pointee {
                type += Int(v)
            }
            p = p?.advanced(by: 1)
            if let l = p?.pointee, let r = self.pnalu.pStart?.pointee {
                idxPayload = Int(l-r)
            }
        }
    }
    
    /// avcC structure from MP4
    @objcMembers public class SSBAVCCHeader: NSObject {
        public private(set) var sps: SSBNALUnit?
        public private(set) var pps: SSBNALUnit?
        
        public init(header: UnsafePointer<UInt8>, cBytes: Int) {
            super.init()
            guard cBytes >= 8 else { return }
            var pHeader = header
            let pEnd = pHeader.advanced(by: cBytes)
            let cSeq = Int(pHeader[5]) & 0x1f
            pHeader = pHeader.advanced(by: 2)
            for i in 0..<cSeq where pHeader.advanced(by: 2).pointee <= pEnd.pointee {
                let cThis = pHeader[0] << 8 + header[1]
                pHeader = pHeader.advanced(by: 2)
                if pHeader.pointee + cThis > pEnd.pointee {
                    return
                }
                if i == 0 {
                    sps = SSBNALUnit(pStart: pHeader, len: Int(cThis))
                }
                pHeader = pHeader.advanced(by: Int(cThis))
            }
            guard pHeader.advanced(by: 3).pointee < pEnd.pointee else {
                return
            }
            if pHeader[0] > 0 {
                let cThis = pHeader[1] << 8 + pHeader[2]
                pHeader = pHeader.advanced(by: 3)
                pps = SSBNALUnit(pStart: pHeader, len: Int(cThis))
            }
        }
    }
    
    /// extract frame num from slice headers
    @objcMembers public class SSBSliceHeader: NSObject {
        public private(set) var frameNum: Int
        private var bitsFrame = 0
        
        public init(frameNum: Int = 0, bitsFrame: Int) {
            self.frameNum = frameNum
            self.bitsFrame = bitsFrame
        }
        
        public func parse(pnalu: SSBNALUnit) -> Bool {
            switch pnalu.type {
            case .IDRSlice, .slice, .partitionA: break
            default: return false
            }
            // slice header has the 1-byte type, then one UE value, then the frame number
            pnalu.resetBitStream()
            pnalu.skip(bits: 8) //NALU type
            pnalu.nextUE() // first mb in slice
            pnalu.nextUE() // slice type
            pnalu.nextUE() // pic param set id
            frameNum = Int(pnalu.nextWord(nBits: bitsFrame))
            return true
        }
    }
    
    public private(set) var pStart: UnsafePointer<UInt8>?
    private var cBytes: Int
    public var length: Int {
        return cBytes
    }
    public var type: NALType {
        guard let start = pStart?.pointee else {
            return .unknown
        }
        return NALType(rawValue: start & 0x1f) ?? .unknown
    }
    
    private var idx = 0
    private var nBits = 0
    private var byte: UInt8 = 0
    private var cZero = 0
    private var startCodeStart: UnsafePointer<UInt8>?
    
    public init(pStart: UnsafePointer<UInt8>?, len: Int) {
        self.pStart = pStart
        startCodeStart = pStart
        cBytes = len
        super.init()
    }
    
    public func copy(with zone: NSZone? = nil) -> Any {
        let other = SSBNALUnit(pStart: pStart, len: cBytes)
        resetBitStream()
        return other
    }
    
    /// bitwise access to data
    public func resetBitStream()  {
        idx = 0
        nBits = 0
        cZero = 0
    }
    
    /// identify a NAL unit within a buffer. If LengthSize is non-zero, it is the number of bytes of length field we expect. Otherwise, we expect start-code delimiters.
    public func parse(pBuffer: inout UnsafePointer<UInt8>, cSpace: Int, length size: Int, bEnd: Bool) -> Bool {
        // if we get the start code but not the whole
        // NALU, we can return false but still have the length property valid
        cBytes = 0
        resetBitStream()
        if size > 0 {
            pStart = pBuffer
            if size > cSpace {
                return false
            }
            cBytes = 0
            for _ in 0..<size {
                cBytes <<= 8
                cBytes += Int(pBuffer.pointee)
                pBuffer = pBuffer.advanced(by: 1)
            }
            if cBytes + size <= cSpace {
                pStart = pBuffer
                return true
            }
        } else {
            // this is not length-delimited: we must look for start codes
            var pBegin:UnsafePointer<UInt8>?
            var space = cSpace
            guard SSBNALUnit.startCode(begin: &pBegin, start: &pBuffer, remain: &space) else {
                return false
            }
            pStart = pBuffer
            pBegin = pBuffer
            // either we find another startcode, or we continue to the
            // buffer end (if this is the last block of data)
            if SSBNALUnit.startCode(begin: &pBegin, start: &pBuffer, remain: &space),
                let begin = pBegin?.pointee,
                let start = pStart?.pointee {
                cBytes = Int(begin - start)
                return true
            } else if bEnd {
                cBytes = cSpace
                return true
            }
        }
        return false
    }
    
    public func skip(bits: Int) {
        if bits < nBits {
            nBits -= bits
        } else {
            var nbits = bits - nBits
            while nbits >= 8 {
                nextByte()
                nbits -= 8
            }
            if nbits > 0 {
                byte = nextByte()
                nBits = 8
                nBits -= nbits
            }
        }
    }
    /// get the next byte, removing emulation prevention bytes
    @discardableResult
    private func nextByte() -> UInt8 {
        guard idx < cBytes else {
            return 0
        }
        let b = pStart?.advanced(by: idx).pointee
        idx += 1
        // to avoid start-code emulation, a byte 0x03 is inserted
        // after any 00 00 pair. Discard that here.
        if b == 0 {
            cZero += 1
            if idx < cBytes, cZero == 2, pStart?[idx] == 0x03 {
                idx += 1
                cZero = 0
            }
        } else {
            cZero = 0
        }
        return b ?? 0
    }
    
    @discardableResult
    private func nextBit() -> UInt64 {
        if nBits == 0 {
            byte = nextByte()
            nBits = 8
        }
        nBits -= 1
        return UInt64(byte >> nBits) & 0x1
    }
    
    private func nextWord(nBits: Int) -> UInt64 {
        var u: UInt64 = 0
        var nbits = nBits
        while nbits > 0 {
            u <<= 1
            u |= nextBit()
            nbits -= 1
        }
        return u
    }
    
    // Exp-Golomb entropy coding: leading zeros, then a one, then
    // the data bits. The number of leading zeros is the number of
    // data bits, counting up from that number of 1s as the base.
    // That is, if you see
    //      0001010
    // You have three leading zeros, so there are three data bits (010)
    // counting up from a base of 111: thus 111 + 010 = 1001 = 9
    @discardableResult
    func nextUE() -> UInt64 {
        var cZero = 0
        while nextBit() == 0 {
            cZero += 1
        }
        return nextWord(nBits: cZero) + (1 << cZero) - 1
    }
    
    @discardableResult
    private func nextSE() -> Int64 {
        let UE = nextUE()
        let bPositive = UE & 1 > 0
        let SE = Int64(UE + 1) >> 1
        return bPositive ? SE : -SE
    }
    
    private func scalingList(size: Int) {
        var lastScale: Int64 = 8
        var nextScale = lastScale
        for _ in 0..<size {
            if nextScale != 0 {
                let delta = nextSE()
                nextScale = (lastScale + delta + 256) % 256
            }
            lastScale = nextScale == 0 ? lastScale : nextScale
        }
    }
    
    private class func startCode(begin: inout UnsafePointer<UInt8>?, start: inout UnsafePointer<UInt8>, remain: inout Int) -> Bool {
        // start code is any number of 00 followed by 00 00 01
        // We need to record the first 00 in pBegin and the first byte
        // following the startcode in pStart.
        // if no start code is found, pStart and cRemain should be unchanged.
        var pThis = start
        var cBytes = remain
        while cBytes >= 4 {
            if pThis[0] == 0 {
                // remember first 00
                if begin == nil {
                    begin = pThis
                }
                if pThis[1] == 0, pThis[2] == 1 {
                    // point to type byte of NAL unit
                    start = pThis.advanced(by: 3)
                    remain = cBytes - 3
                    return true
                }
            } else {
                
            }
            cBytes -= 1
            pThis = pThis.advanced(by: 1)
        }
        return false
    }
}

@objcMembers open class SSBAVEncoder: NSObject {
    public typealias encoderHandler = ([Data]?, CMTimeValue) -> Int
    public typealias paramHandler = (Data?) -> Int
    
    /// 50 MB switch point
    private let OUTPUT_FILE_SWITCH_POINT = 50 * 1024 * 1024
    
    /// Filename "capture.mp4" wraps at capture5.mp4
    private let MAX_FILENAME_INDEX = 5
    
    public var birthRate: Int {
        didSet {
            hasBitrateChanged = true
        }
    }
    public private(set) var bitsPerSecond: Int = 0
    
    /// initial writer, used to obtain SPS/PPS from header
    private var headerWriter: SSBVideoEncoder?
    /// main encoder/writer
    private var writer: SSBVideoEncoder?
    
    private var inputFile: FileHandle?
    private var readQueue: DispatchQueue?
    private var readSource: DispatchSourceRead?
    
    // index of current file name
    private var isSwapping = false
    private var currentFile = 1
    private let width: Int
    private let height: Int
    
    // param set data
    private var avcC: Data?
    private var lengthSize = 0
    
    // location of mdat
    private var hasFoundMDAT = false
    private var posMDAT: UInt64 = 0
    private var bytesToNextAtom = 0
    private var doesNeedParams = false
    
    // tracking if NALU is next frame
    private var prevNalIdc = 0
    private var prevNalType = 0
    /// array of NSData comprising a single frame. each data is one nalu with no start code
    private var pendingNALU: [Data]?
    // FIFO for frame times
    private var times = [CMTimeValue](repeating: 0, count: 10)
    
    private var outputBlock: encoderHandler?
    private var paramsBlock: paramHandler?
    /// estimate bitrate over first second
    private var bitspersecond = 0
    private var firstPTS: CMTimeValue = 0
    private var hasBitrateChanged = false
    
    private func fileName() -> String {
        return NSTemporaryDirectory().appending("capture\(currentFile).mp4")
    }
    
    
    public init(width: Int, height: Int, birthRate: Int) {
        self.birthRate = birthRate
        self.width = width
        self.height = height
        let path = NSTemporaryDirectory().appending("params.mp4")
        headerWriter = .init(path: path, width: width, height: height, birthRate: birthRate)
        // swap between 3 filenames
        writer = .init(path: NSTemporaryDirectory().appending("capture\(currentFile).mp4"), width: width, height: height, birthRate: birthRate)
        super.init()
    }
    
    public func encode(handler: encoderHandler?, onParams: paramHandler?) {
        outputBlock = handler
        paramsBlock = onParams
        doesNeedParams = true
        pendingNALU = nil
        firstPTS = -1
        bitsPerSecond = 0
    }
    
    public func encode(frame sampleBuffer: CMSampleBuffer) {
        let presetime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let pts = presetime.value
        
        objc_sync_enter(self)
        if doesNeedParams {
            // the avcC record is needed for decoding and it's not written to the file until
            // completion. We get round that by writing the first frame to two files; the first
            // file (containing only one frame) is then finished, so we can extract the avcC record.
            // Only when we've got that do we start reading from the main file.
            doesNeedParams = false
            if headerWriter?.encode(frame: sampleBuffer) == true {
                headerWriter?.finish { [weak self] in
                    self?.onParamsCompletion()
                }
            }
        }
        objc_sync_exit(self)
        
        objc_sync_enter(times)
        times.append(pts)
        objc_sync_exit(times)
        
        objc_sync_enter(self)
        // switch output files when we reach a size limit
        // to avoid runaway storage use.
        if !isSwapping, let descriptpor = inputFile?.fileDescriptor {
            var st = stat()
            fstat(descriptpor, &st)
            if st.st_size > OUTPUT_FILE_SWITCH_POINT || hasBitrateChanged {
                hasBitrateChanged = false
                isSwapping = true
                let oldVideo = writer
                // construct a new writer to the next filename
                currentFile += 1
                if currentFile > MAX_FILENAME_INDEX {
                    currentFile = 1
                }
                writer = SSBVideoEncoder(path: fileName(), width: width, height: height, birthRate: birthRate)
                // to do this seamlessly requires a few steps in the right order
                // first, suspend the read source
                if readSource != nil {
                    readSource?.cancel()
                    // execute the next step as a block on the same queue, to be sure the suspend is done
                    readQueue?.async { [weak self] in
                        self?.readSource = nil
                        oldVideo?.finish {
                            if let path = oldVideo?.path {
                                self?.swapFiles(oldPath: path)
                            }
                        }
                    }
                } else if let path = oldVideo?.path {
                    swapFiles(oldPath: path)
                }
            }
        }
        objc_sync_exit(self)
        _ = writer?.encode(frame: sampleBuffer)
    }
    
    public func shutdown() {
        objc_sync_enter(self)
        defer {
            objc_sync_exit(self)
        }
        readSource = nil
        headerWriter?.finish { [weak self] in
            self?.headerWriter = nil
        }
        writer?.finish { [weak self] in
            self?.writer = nil
        }
    }
    
    private func onNALU(_ nalu: Data) {
        let idc = Int(nalu[0]) & 0x60
        let naltype = Int(nalu[0]) & 0x1f
        
        if pendingNALU != nil {
            let pnal = UnsafeMutablePointer<UInt8>.allocate(capacity: nalu.count)
            nalu.copyBytes(to: pnal, count: nalu.count)
            let nal = SSBNALUnit(pStart: pnal, len: nalu.count)
            let bNew: Bool = {
                if idc != prevNalIdc, idc * prevNalIdc != 0 {
                    return true
                } else if (naltype != prevNalType && naltype == 5) || (naltype == 5 && prevNalType == 5) {
                    return true
                } else if naltype >= 1, naltype <= 5 {
                    nal.skip(bits: 8)
                    return nal.nextUE() == 0
                }
                return false
            }()
            if bNew {
                onEncodedFrame()
                pendingNALU = nil
            }
        }
        prevNalType = naltype
        prevNalIdc = idc
        if pendingNALU == nil {
            pendingNALU = [Data]()
        }
        pendingNALU?.append(nalu)
    }
    
    func getConfigData() -> Data? {
        return avcC
    }
    
    private func onFileUpdate() {
        guard let inputFile = inputFile else {
            return
        }
        // called whenever there is more data to read in the main encoder output file.
        var s = stat()
        fstat(inputFile.fileDescriptor, &s)
        // locate the mdat atom if needed
        var cReady = s.st_size - Int64(inputFile.offsetInFile)
        while !hasFoundMDAT && cReady > 8 {
            if bytesToNextAtom == 0 {
                let hdr = inputFile.readData(ofLength: 8)
                cReady -= 8
                let lenAtom = Int(hdr.toHost())
                let nameAtom = Int(hdr.advanced(by: 4).toHost())
                if nameAtom == "mdat".fourCharCode! {
                    hasFoundMDAT = true
                    posMDAT = inputFile.offsetInFile - 8
                } else {
                    bytesToNextAtom = lenAtom - 8
                }
                if bytesToNextAtom > 0 {
                    let cThis = cReady < bytesToNextAtom ? Int(cReady) : bytesToNextAtom
                    bytesToNextAtom -= cThis
                    inputFile.seek(toFileOffset: inputFile.offsetInFile + UInt64(cThis))
                    cReady -= Int64(cThis)
                }
                guard hasFoundMDAT else { return }
                readAndDeliver(Int(cReady))
            }
        }
    }
    
    private func readAndDeliver(_ cReady: Int) {
        guard let inputFile = inputFile else {
            return
        }
        // Identify the individual NALUs and extract them
        var cReady = cReady
        while cReady > lengthSize {
            let lenField = inputFile.readData(ofLength: lengthSize)
            cReady -= lengthSize
            let lenNALU = Int(lenField.toHost())
            if lenNALU > cReady {
                // whole NALU not present -- seek back to start of NALU and wait for more
                inputFile.seek(toFileOffset: inputFile.offsetInFile - 4)
                break
            }
            let nalu = inputFile.readData(ofLength: lenNALU)
            cReady -= lenNALU
            onNALU(nalu)
        }
    }
    
    public func onEncodedFrame() {
        var pts: CMTimeValue = 0
        objc_sync_enter(times)
        if !times.isEmpty {
            pts = times[0]
            times.remove(at: 0)
            if firstPTS < 0 {
                firstPTS = pts
            }
            if pts - firstPTS < 1,
                let bytes = pendingNALU?.reduce(0, { $1.count }) {
                bitsPerSecond += (bytes * 8)
            }
        }
        objc_sync_exit(times)
        _ = outputBlock?(pendingNALU, pts)
    }
    
    private func parse(path: String) -> Bool {
        guard let file = FileHandle(forReadingAtPath: path) else {
            return false
        }
        var s = stat()
        fstat(file.fileDescriptor, &s)
        let movie = SSBMP4Atom(atomAt: 0, size: Int(s.st_size), type: "file".fourCharCode!, inFile: file)
        
        var trak: SSBMP4Atom?
        let trakType = "trak".fourCharCode!
        if let moov = movie.child(of: "moov".fourCharCode!, startAt: 0) {
            repeat {
                trak = moov.nextChild()
                if let t = trak, t.type == trakType {
                    let tkhd = t.child(of: "tkhd".fourCharCode!, startAt: 0)
                    let verflags = tkhd?.read(at: 0, size: 4)
                    if let p = verflags?[3], p & 1 > 0 {
                        break
                    }
                }
            } while trak != nil
        }
        
        var stsd: SSBMP4Atom?
        if let trak = trak,
            let media = trak.child(of: "mdia".fourCharCode!, startAt: 0),
            let minf = media.child(of: "minf".fourCharCode!, startAt: 0),
            let stbl = minf.child(of: "stbl".fourCharCode!, startAt: 0) {
            stsd = stbl.child(of: "stsd".fourCharCode!, startAt: 0)
        }
        
        if let stsd = stsd,
            let avc1 = stsd.child(of: "avc1".fourCharCode!, startAt: 8),
            let esd = avc1.child(of: "avcC".fourCharCode!, startAt: 78) {
            avcC = esd.read(at: 0, size: Int(esd.length))
            if let avcC = self.avcC {
                lengthSize = Int(avcC[4]) & 3 + 1
                return true
            }
        }
        return false
    }
    
    private func swapFiles(oldPath: String) {
        guard let inputFile = inputFile else {
            return
        }
        // save current position
        let pos = inputFile.offsetInFile
        // re-read mdat length
        inputFile.seek(toFileOffset: posMDAT)
        let hdr = inputFile.readData(ofLength: 4)
        if !hdr.isEmpty {
            let lenMDAT = hdr.toHost()
            // extract nalus from saved position to mdat end
            let posEnd = posMDAT + lenMDAT
            let cRead = posEnd - pos
            inputFile.seek(toFileOffset: pos)
            readAndDeliver(Int(cRead))
        }
        // close and remove file
        inputFile.closeFile()
        hasFoundMDAT = false
        bytesToNextAtom = 0
        try? FileManager.default.removeItem(atPath: oldPath)
        
        // open new file and set up dispatch source
        if let path = writer?.path, let input = FileHandle(forReadingAtPath: path) {
            self.inputFile = input
            readSource = DispatchSource.makeReadSource(fileDescriptor: input.fileDescriptor, queue: readQueue)
            readSource?.setEventHandler(handler: { [weak self] in
                self?.onFileUpdate()
            })
            readSource?.resume()
            isSwapping = false
        }
    }
    
    private func onParamsCompletion() {
        // the initial one-frame-only file has been completed
        // Extract the avcC structure and then start monitoring the
        // main file to extract video from the mdat chunk.
        if let path = headerWriter?.path, parse(path: path) {
            if let block = paramsBlock {
                _ = block(avcC)
            }
            headerWriter = nil
            isSwapping = false
            if let p = writer?.path,
                let input = FileHandle(forReadingAtPath: p) {
                inputFile = input
                readQueue = DispatchQueue(label: "com.ssb.SSBEncoder.avencoder.read")
                readSource = DispatchSource.makeReadSource(fileDescriptor: input.fileDescriptor, queue: readQueue)
                readSource?.setEventHandler(handler: { [weak self] in
                    self?.onFileUpdate()
                })
                readSource?.resume()
            }
        }
    }
}

@objcMembers open class SSBVideoEncoder: NSObject {
    public let path: String
    public let birthRate: Int
    private let writer: AVAssetWriter?
    private let writerInput: AVAssetWriterInput
    
    public init(path: String, width: Int, height: Int, birthRate: Int) {
        self.path = path
        self.birthRate = birthRate
        let fileMgr = FileManager.default
        try? fileMgr.removeItem(atPath: path)
        writerInput = .init(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecH264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: birthRate,
                AVVideoMaxKeyFrameIntervalKey: 30 * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264High41,
                AVVideoAllowFrameReorderingKey: false
            ]
        ])
        writerInput.expectsMediaDataInRealTime = true
        writer = try? .init(url: .init(fileURLWithPath: path), fileType: .mov)
        writer?.add(writerInput)
        super.init()
    }
    
    public func finish(completionHandler: @escaping (() -> Void)) {
        guard let writer = writer,
            writer.status == .writing else {
            return
        }
        writer.finishWriting(completionHandler: completionHandler)
    }
    
    public func encode(frame sampleBuffer: CMSampleBuffer) -> Bool {
        guard CMSampleBufferDataIsReady(sampleBuffer),
            let writer = writer else {
            return false
        }
        if writer.status == .unknown {
            let startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startWriting()
            writer.startSession(atSourceTime: startTime)
        }
        if writer.status == .failed {
            return false
        }
        if writerInput.isReadyForMoreMediaData {
            writerInput.append(sampleBuffer)
            return true
        }
        return false
    }
}


extension Data {
    func toHost() -> UInt64 {
        return (UInt64(self[0]) << 24) + (UInt64(self[1]) << 16) + (UInt64(self[2]) << 8) + UInt64(self[3])
    }
}


extension UnsafePointer where Pointee == UInt8 {
    func toHost() -> UInt {
        return (UInt(self[0]) << 24) + (UInt(self[1]) << 16) + (UInt(self[2]) << 8) + UInt(self[3])
    }
}

extension String {
    var fourCharCode: FourCharCode? {
        guard self.count == 4 else {
            return nil
        }
        return self.utf16.reduce(0) { $0 << 8 + FourCharCode($1) }
    }
}
