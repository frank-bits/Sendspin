import CryptoKit
import Foundation

/// The sender's side of the password proof AirPlay 2 pairs with (SRP-6a, as HomeKit uses it:
/// a 3072-bit group and SHA-512). Both sides end up with the same key without the password
/// crossing the network.
struct SRPClient {
    /// The 3072-bit group of RFC 5054, with generator 5.
    static let modulus = BigUInt(hex: """
        FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DD
        EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED
        EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F
        83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B
        E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6955817183995497CEA956AE515D2261898FA0510
        15728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7
        ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864D87602733EC86A64521F2B18177B200C
        BBE117577A615D6C770988C0BAD946E208E24FA074E5AB3143DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF
        """.replacingOccurrences(of: "\n", with: ""))!
    static let generator = BigUInt(5)
    static let modulusBytes = 384

    let secret: BigUInt
    /// What we send the speaker: the generator to the power of our secret.
    let publicKey: Data

    /// `secret` is random, 32 bytes.
    init(secret: Data) {
        self.secret = BigUInt(secret)
        publicKey = Self.generator.power(self.secret, modulus: Self.modulus).data()
    }

    struct Proof: Equatable {
        /// The key both sides now share.
        var key: Data
        /// Our proof that we know the password.
        var proof: Data
        /// The proof the speaker must answer with.
        var answer: Data
    }

    /// Our proof for the speaker's salt and public key; nil for a key no honest speaker sends.
    func prove(username: String, password: String, salt: Data, serverKey: Data) -> Proof? {
        let modulus = Self.modulus, generator = Self.generator
        let theirs = BigUInt(serverKey)
        guard !(theirs % modulus).isZero else { return nil }
        func hash(_ parts: Data...) -> Data { Data(SHA512.hash(data: parts.reduce(Data(), +))) }
        let multiplier = BigUInt(hash(modulus.data(count: Self.modulusBytes), generator.data(count: Self.modulusBytes)))
        let scramble = BigUInt(hash(Data(count: Self.modulusBytes - publicKey.count) + publicKey, theirs.data(count: Self.modulusBytes)))
        guard !scramble.isZero else { return nil }
        // Numbers are hashed without zeros in front, the salt included.
        let saltBytes = BigUInt(salt).data()
        let exponent = BigUInt(hash(saltBytes, hash(Data("\(username):\(password)".utf8))))
        let verifier = generator.power(exponent, modulus: modulus)
        // (B - k * g^x) ^ (a + u * x), kept above zero by adding the modulus first.
        let base = (theirs % modulus + modulus - (multiplier * verifier) % modulus) % modulus
        let shared = base.power(secret + scramble * exponent, modulus: modulus)
        let key = hash(shared.data())
        let groupHash = Data(zip(hash(modulus.data()), hash(generator.data())).map { $0 ^ $1 })
        let proof = hash(groupHash, hash(Data(username.utf8)), saltBytes, publicKey, theirs.data(), key)
        return Proof(key: key, proof: proof, answer: hash(publicKey, proof, key))
    }
}

/// The typed fields pairing messages are made of. A value longer than 255 bytes is split over
/// several fields of the same type, one after the other.
enum TLV8 {
    static let method: UInt8 = 0, salt: UInt8 = 2, publicKey: UInt8 = 3, proof: UInt8 = 4
    static let state: UInt8 = 6, error: UInt8 = 7, flags: UInt8 = 0x13

    static func encode(_ fields: [(UInt8, Data)]) -> Data {
        var data = Data()
        for (type, value) in fields {
            var rest = value[...]
            repeat {
                let piece = rest.prefix(255)
                data.append(contentsOf: [type, UInt8(piece.count)])
                data.append(piece)
                rest = rest.dropFirst(piece.count)
            } while !rest.isEmpty
        }
        return data
    }

    static func decode(_ data: Data) -> [UInt8: Data] {
        var fields: [UInt8: Data] = [:]
        var rest = data[...]
        while rest.count >= 2 {
            let type = rest[rest.startIndex], length = Int(rest[rest.startIndex + 1])
            rest = rest.dropFirst(2)
            guard rest.count >= length else { break }
            fields[type, default: Data()].append(rest.prefix(length))
            rest = rest.dropFirst(length)
        }
        return fields
    }
}
