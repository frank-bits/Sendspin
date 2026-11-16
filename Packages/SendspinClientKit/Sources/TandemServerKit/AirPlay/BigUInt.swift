import Foundation

/// A whole number of any size, for the arithmetic AirPlay 2's pairing asks for: numbers of
/// 3072 bits, raised to powers and reduced.
struct BigUInt: Equatable, Sendable {
    /// 32-bit digits, the lowest first, without zeros on top.
    private(set) var limbs: [UInt32]

    static let zero = BigUInt(limbs: [])

    private init(limbs: [UInt32]) {
        var limbs = limbs
        while limbs.last == 0 { limbs.removeLast() }
        self.limbs = limbs
    }

    init(_ value: UInt32) {
        self.init(limbs: [value])
    }

    /// From bytes, the highest first.
    init(_ data: Data) {
        var limbs: [UInt32] = []
        var index = data.endIndex
        while index > data.startIndex {
            var limb: UInt32 = 0
            for shift in 0..<4 where index > data.startIndex {
                index = data.index(before: index)
                limb |= UInt32(data[index]) << (8 * UInt32(shift))
            }
            limbs.append(limb)
        }
        self.init(limbs: limbs)
    }

    init?(hex: String) {
        var bytes = Data()
        var text = Substring(hex)
        if text.count % 2 == 1 { text = "0" + text }
        while !text.isEmpty {
            guard let byte = UInt8(text.prefix(2), radix: 16) else { return nil }
            bytes.append(byte)
            text = text.dropFirst(2)
        }
        self.init(bytes)
    }

    var isZero: Bool { limbs.isEmpty }

    /// As bytes, the highest first, with none to spare; filled up with zeros to `count`.
    func data(count: Int = 0) -> Data {
        var bytes = Data()
        for limb in limbs.reversed() {
            for shift in stride(from: 24, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: limb >> UInt32(shift))) }
        }
        bytes = Data(bytes.drop { $0 == 0 })
        return bytes.count >= count ? bytes : Data(count: count - bytes.count) + bytes
    }

    static func < (first: BigUInt, second: BigUInt) -> Bool {
        if first.limbs.count != second.limbs.count { return first.limbs.count < second.limbs.count }
        for index in first.limbs.indices.reversed() where first.limbs[index] != second.limbs[index] {
            return first.limbs[index] < second.limbs[index]
        }
        return false
    }

    static func + (first: BigUInt, second: BigUInt) -> BigUInt {
        var result: [UInt32] = []
        var carry: UInt64 = 0
        for index in 0..<max(first.limbs.count, second.limbs.count) {
            let sum = carry + UInt64(index < first.limbs.count ? first.limbs[index] : 0)
                + UInt64(index < second.limbs.count ? second.limbs[index] : 0)
            result.append(UInt32(truncatingIfNeeded: sum))
            carry = sum >> 32
        }
        if carry > 0 { result.append(UInt32(carry)) }
        return BigUInt(limbs: result)
    }

    /// `second` must not be the greater.
    static func - (first: BigUInt, second: BigUInt) -> BigUInt {
        var result = first.limbs
        var borrow: Int64 = 0
        for index in result.indices {
            let difference = Int64(result[index]) - borrow - Int64(index < second.limbs.count ? second.limbs[index] : 0)
            result[index] = UInt32(truncatingIfNeeded: difference)
            borrow = difference < 0 ? 1 : 0
        }
        return BigUInt(limbs: result)
    }

    static func * (first: BigUInt, second: BigUInt) -> BigUInt {
        guard !first.isZero, !second.isZero else { return .zero }
        var result = [UInt32](repeating: 0, count: first.limbs.count + second.limbs.count)
        for (place, digit) in first.limbs.enumerated() where digit != 0 {
            var carry: UInt64 = 0
            for (offset, other) in second.limbs.enumerated() {
                let product = UInt64(digit) * UInt64(other) + UInt64(result[place + offset]) + carry
                result[place + offset] = UInt32(truncatingIfNeeded: product)
                carry = product >> 32
            }
            result[place + second.limbs.count] = UInt32(carry)
        }
        return BigUInt(limbs: result)
    }

    /// What's left after dividing by `divisor`, which mustn't be zero (Knuth's algorithm D).
    static func % (value: BigUInt, divisor: BigUInt) -> BigUInt {
        precondition(!divisor.isZero)
        if value < divisor { return value }
        if divisor.limbs.count == 1 {
            var remainder: UInt64 = 0
            for limb in value.limbs.reversed() { remainder = (remainder << 32 | UInt64(limb)) % UInt64(divisor.limbs[0]) }
            return BigUInt(UInt32(remainder))
        }
        // Shifted so the divisor's top digit has its top bit set, which keeps each guess close.
        let shift = UInt32(divisor.limbs[divisor.limbs.count - 1].leadingZeroBitCount)
        let lower = shifted(divisor.limbs, by: shift)
        var upper = shifted(value.limbs, by: shift) + [0]
        let size = lower.count
        if upper.count == value.limbs.count + 1, shift > 0 {
            upper[value.limbs.count] = value.limbs[value.limbs.count - 1] >> (32 - shift)
        }
        for place in stride(from: upper.count - size - 1, through: 0, by: -1) {
            let top = UInt64(upper[place + size]) << 32 | UInt64(upper[place + size - 1])
            var guess = top / UInt64(lower[size - 1])
            var rest = top % UInt64(lower[size - 1])
            while guess > 0xFFFF_FFFF || guess * UInt64(lower[size - 2]) > (rest << 32 | UInt64(upper[place + size - 2])) {
                guess -= 1
                rest += UInt64(lower[size - 1])
                if rest > 0xFFFF_FFFF { break }
            }
            var borrow: Int64 = 0
            var carry: UInt64 = 0
            for index in 0..<size {
                let product = guess * UInt64(lower[index]) + carry
                carry = product >> 32
                let difference = Int64(upper[place + index]) - borrow - Int64(product & 0xFFFF_FFFF)
                upper[place + index] = UInt32(truncatingIfNeeded: difference)
                borrow = difference < 0 ? 1 : 0
            }
            let difference = Int64(upper[place + size]) - borrow - Int64(carry)
            upper[place + size] = UInt32(truncatingIfNeeded: difference)
            if difference < 0 {
                // The guess was one too many: put the divisor back once.
                var carried: UInt64 = 0
                for index in 0..<size {
                    let sum = UInt64(upper[place + index]) + UInt64(lower[index]) + carried
                    upper[place + index] = UInt32(truncatingIfNeeded: sum)
                    carried = sum >> 32
                }
                upper[place + size] = UInt32(truncatingIfNeeded: UInt64(upper[place + size]) + carried)
            }
        }
        var remainder = Array(upper[0..<size])
        if shift > 0 {
            for index in 0..<size {
                remainder[index] = remainder[index] >> shift | (index + 1 < size ? remainder[index + 1] << (32 - shift) : 0)
            }
        }
        return BigUInt(limbs: remainder)
    }

    /// The digits moved up by fewer than 32 bits; what falls off the top is dropped.
    private static func shifted(_ limbs: [UInt32], by shift: UInt32) -> [UInt32] {
        guard shift > 0 else { return limbs }
        var result = limbs
        for index in result.indices.reversed() {
            result[index] = limbs[index] << shift | (index > 0 ? limbs[index - 1] >> (32 - shift) : 0)
        }
        return result
    }

    /// This number to the power `exponent`, reduced by `modulus`.
    func power(_ exponent: BigUInt, modulus: BigUInt) -> BigUInt {
        var result = BigUInt(1) % modulus
        let base = self % modulus
        for limb in exponent.limbs.reversed() {
            for bit in stride(from: 31, through: 0, by: -1) {
                result = (result * result) % modulus
                if limb >> UInt32(bit) & 1 == 1 { result = (result * base) % modulus }
            }
        }
        return result
    }
}
