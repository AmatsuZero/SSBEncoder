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
        if fourcc == OSType("uuid") {
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
        
        private var pnalu: SSBNALUnit
        public private(set) var frameBits = 0
        public private(set) var encodedWidth: Int64 = 0
        public private(set) var encodedHeight: Int64 = 0
        public private(set) var isInterLaced = false
        public private(set) var profile: UInt = 0
        public private(set) var level: UInt = 0
        public private(set) var compact: CChar = 0
        
        public init(pnalu: SSBNALUnit) {
            self.pnalu = pnalu.copy() as! SSBNALUnit
            super.init()
        }
        
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
            self.pnalu = pnalu.copy() as! SSBNALUnit
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
    private func nextUE() -> UInt64 {
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
    
}

extension Data {
    func toHost() -> UInt64 {
        return (UInt64(self[0]) << 24) + (UInt64(self[1]) << 16) + (UInt64(self[2]) << 8) + UInt64(self[3])
    }
}
