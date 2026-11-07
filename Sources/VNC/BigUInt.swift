// VNC — Lightweight BigUInt supporting arbitrary-precision Diffie-Hellman modular exponentiation.
import Foundation

/// Fail-closed arithmetic errors; wire bytes must never trap.
public enum BigUIntError: Error, Sendable {
    case divisionByZero
    case zeroModulus
}

public struct BigUInt: Equatable, Comparable, Sendable {
    public var limbs: [UInt64]

    public init() {
        limbs = []
    }

    public init(_ value: UInt64) {
        limbs = value == 0 ? [] : [value]
    }

    public init(limbs: [UInt64]) {
        var trimmed = limbs
        while let last = trimmed.last, last == 0 {
            trimmed.removeLast()
        }
        self.limbs = trimmed
    }

    public init(bigEndian data: Data) {
        var parsedLimbs: [UInt64] = []
        let byteCount = data.count
        if byteCount > 0 {
            let stride = 8
            var index = byteCount
            while index > 0 {
                let start = max(0, index - stride)
                let chunk = data[start ..< index]
                var limb: UInt64 = 0
                for byte in chunk {
                    limb = (limb << 8) | UInt64(byte)
                }
                parsedLimbs.append(limb)
                index = start
            }
        }
        self.init(limbs: parsedLimbs)
    }

    public var isZero: Bool {
        limbs.isEmpty
    }

    public func serialize(minBytes: Int = 0) -> Data {
        var bytes = [UInt8]()
        for limb in limbs {
            var temp = limb
            for _ in 0 ..< 8 {
                bytes.append(UInt8(temp & 0xFF))
                temp >>= 8
            }
        }
        // Remove trailing zero bytes
        while bytes.last == 0 {
            bytes.removeLast()
        }
        // Big endian is reversed
        bytes.reverse()

        if bytes.count < minBytes {
            let padding = [UInt8](repeating: 0, count: minBytes - bytes.count)
            return Data(padding + bytes)
        }
        return Data(bytes)
    }

    public static func < (lhs: BigUInt, rhs: BigUInt) -> Bool {
        if lhs.limbs.count != rhs.limbs.count {
            return lhs.limbs.count < rhs.limbs.count
        }
        for (a, b) in zip(lhs.limbs.reversed(), rhs.limbs.reversed()) {
            if a != b {
                return a < b
            }
        }
        return false
    }

    public static func + (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        let maxCount = max(lhs.limbs.count, rhs.limbs.count)
        var result = [UInt64]()
        result.reserveCapacity(maxCount + 1)
        var carry: UInt64 = 0

        for i in 0 ..< maxCount {
            let a = i < lhs.limbs.count ? lhs.limbs[i] : 0
            let b = i < rhs.limbs.count ? rhs.limbs[i] : 0
            let (sum1, overflow1) = a.addingReportingOverflow(b)
            let (sum2, overflow2) = sum1.addingReportingOverflow(carry)
            carry = (overflow1 ? 1 : 0) + (overflow2 ? 1 : 0)
            result.append(sum2)
        }
        if carry > 0 {
            result.append(carry)
        }
        return BigUInt(limbs: result)
    }

    public static func - (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        guard lhs >= rhs else { return BigUInt() }
        var result = [UInt64]()
        result.reserveCapacity(lhs.limbs.count)
        var borrow: UInt64 = 0

        for i in 0 ..< lhs.limbs.count {
            let a = lhs.limbs[i]
            let b = i < rhs.limbs.count ? rhs.limbs[i] : 0
            let (diff1, overflow1) = a.subtractingReportingOverflow(b)
            let (diff2, overflow2) = diff1.subtractingReportingOverflow(borrow)
            borrow = (overflow1 ? 1 : 0) + (overflow2 ? 1 : 0)
            result.append(diff2)
        }
        return BigUInt(limbs: result)
    }

    public static func * (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        if lhs.isZero || rhs.isZero {
            return BigUInt()
        }
        var result = [UInt64](repeating: 0, count: lhs.limbs.count + rhs.limbs.count)

        for i in 0 ..< lhs.limbs.count {
            var carry: UInt64 = 0
            let a = lhs.limbs[i]
            for j in 0 ..< rhs.limbs.count {
                let b = rhs.limbs[j]
                let (high, low) = a.multipliedFullWidth(by: b)
                let (sum1, o1) = result[i + j].addingReportingOverflow(low)
                let (sum2, o2) = sum1.addingReportingOverflow(carry)
                result[i + j] = sum2
                carry = high &+ (o1 ? 1 : 0) &+ (o2 ? 1 : 0)
            }
            var k = i + rhs.limbs.count
            while carry > 0, k < result.count {
                let (sum, o) = result[k].addingReportingOverflow(carry)
                result[k] = sum
                carry = o ? 1 : 0
                k += 1
            }
        }
        return BigUInt(limbs: result)
    }

    public static func / (lhs: BigUInt, rhs: BigUInt) throws -> BigUInt {
        try divmod(lhs, rhs).quotient
    }

    public static func % (lhs: BigUInt, rhs: BigUInt) throws -> BigUInt {
        try divmod(lhs, rhs).remainder
    }

    public static func divmod(_ u: BigUInt, _ v: BigUInt) throws -> (quotient: BigUInt, remainder: BigUInt) {
        // Reject zero divisor; server-supplied prime reaches here.
        guard !v.isZero else { throw BigUIntError.divisionByZero }
        if u < v {
            return (BigUInt(), u)
        }
        if v.limbs.count == 1 {
            return divmodWord(u, v.limbs[0])
        }

        // Knuth Algorithm D for multiple-word division
        let n = v.limbs.count
        let m = u.limbs.count - n

        // D1. Normalize: shift v and u so high bit of v is set
        let shift = UInt64(v.limbs[n - 1].leadingZeroBitCount)
        let vNorm = v.shiftLeft(bits: Int(shift))
        var uNorm = u.shiftLeft(bits: Int(shift))
        if uNorm.limbs.count <= u.limbs.count {
            uNorm.limbs.append(0)
        }

        var q = [UInt64](repeating: 0, count: m + 1)
        let vn1 = vNorm.limbs[n - 1]
        let vn2 = vNorm.limbs[n - 2]

        // D2-D7. Loop on j from m down to 0
        for j in stride(from: m, through: 0, by: -1) {
            let ujn = uNorm.limbs[j + n]
            let ujn1 = uNorm.limbs[j + n - 1]
            let ujn2 = uNorm.limbs[j + n - 2]

            var qhat: UInt64
            var rhat: UInt64
            if ujn == vn1 {
                qhat = UInt64.max
                let (r, o) = ujn1.addingReportingOverflow(vn1)
                rhat = o ? UInt64.max : r
            } else {
                let divResult = vn1.dividingFullWidth((ujn, ujn1))
                qhat = divResult.quotient
                rhat = divResult.remainder
            }

            // Refine qhat
            while true {
                let (prodHigh, prodLow) = qhat.multipliedFullWidth(by: vn2)
                if prodHigh < rhat || (prodHigh == rhat && prodLow <= ujn2) {
                    break
                }
                qhat &-= 1
                let (newR, o) = rhat.addingReportingOverflow(vn1)
                if o {
                    break
                }
                rhat = newR
            }

            // Multiply and subtract: u[j..j+n] -= qhat * vNorm
            var borrow: UInt64 = 0
            for i in 0 ..< n {
                let (pHigh, pLow) = qhat.multipliedFullWidth(by: vNorm.limbs[i])
                let (sub1, b1) = uNorm.limbs[j + i].subtractingReportingOverflow(pLow)
                let (sub2, b2) = sub1.subtractingReportingOverflow(borrow)
                uNorm.limbs[j + i] = sub2
                borrow = pHigh &+ (b1 ? 1 : 0) &+ (b2 ? 1 : 0)
            }
            let (subFinal, bFinal) = uNorm.limbs[j + n].subtractingReportingOverflow(borrow)
            uNorm.limbs[j + n] = subFinal

            if bFinal {
                // Add back if overflow occurred
                qhat &-= 1
                var carry: UInt64 = 0
                for i in 0 ..< n {
                    let (sum1, o1) = uNorm.limbs[j + i].addingReportingOverflow(vNorm.limbs[i])
                    let (sum2, o2) = sum1.addingReportingOverflow(carry)
                    uNorm.limbs[j + i] = sum2
                    carry = (o1 ? 1 : 0) + (o2 ? 1 : 0)
                }
                uNorm.limbs[j + n] &+= carry
            }

            q[j] = qhat
        }

        let quotient = BigUInt(limbs: q)
        let remainder = uNorm.shiftRight(bits: Int(shift))
        return (quotient, remainder)
    }

    private static func divmodWord(_ u: BigUInt, _ v: UInt64) -> (quotient: BigUInt, remainder: BigUInt) {
        var q = [UInt64](repeating: 0, count: u.limbs.count)
        var rem: UInt64 = 0
        for i in stride(from: u.limbs.count - 1, through: 0, by: -1) {
            let res = v.dividingFullWidth((rem, u.limbs[i]))
            q[i] = res.quotient
            rem = res.remainder
        }
        return (BigUInt(limbs: q), BigUInt(rem))
    }

    public func shiftLeft(bits: Int) -> BigUInt {
        guard bits > 0, !isZero else { return self }
        let limbShift = bits / 64
        let bitShift = UInt64(bits % 64)

        var result = [UInt64](repeating: 0, count: limbs.count + limbShift + 1)
        if bitShift == 0 {
            for i in 0 ..< limbs.count {
                result[i + limbShift] = limbs[i]
            }
        } else {
            var carry: UInt64 = 0
            for i in 0 ..< limbs.count {
                let limb = limbs[i]
                result[i + limbShift] = (limb << bitShift) | carry
                carry = limb >> (64 - bitShift)
            }
            result[limbs.count + limbShift] = carry
        }
        return BigUInt(limbs: result)
    }

    public func shiftRight(bits: Int) -> BigUInt {
        guard bits > 0, !isZero else { return self }
        let limbShift = bits / 64
        let bitShift = UInt64(bits % 64)
        guard limbShift < limbs.count else { return BigUInt() }

        var result = [UInt64](repeating: 0, count: limbs.count - limbShift)
        if bitShift == 0 {
            for i in limbShift ..< limbs.count {
                result[i - limbShift] = limbs[i]
            }
        } else {
            for i in limbShift ..< limbs.count {
                let low = limbs[i] >> bitShift
                let high = (i + 1 < limbs.count) ? (limbs[i + 1] << (64 - bitShift)) : 0
                result[i - limbShift] = low | high
            }
        }
        return BigUInt(limbs: result)
    }

    /// Modular exponentiation: computes (base^exp) % modulus via square-and-multiply.
    public func power(_ exp: BigUInt, modulus: BigUInt) throws -> BigUInt {
        // Reject zero modulus; all-zero prime on the wire fails here.
        guard !modulus.isZero else { throw BigUIntError.zeroModulus }
        if modulus == BigUInt(1) {
            return BigUInt()
        }
        var result = BigUInt(1)
        var base = try self % modulus

        for limb in exp.limbs {
            var temp = limb
            for _ in 0 ..< 64 {
                if (temp & 1) == 1 {
                    result = try (result * base) % modulus
                }
                base = try (base * base) % modulus
                temp >>= 1
            }
        }
        return result
    }
}
