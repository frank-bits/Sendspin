import CryptoKit
import Foundation
import Testing
@testable import TandemServerKit

@Suite struct BigUIntTests {
    @Test func bytesGoInAndComeOutTheSame() {
        let bytes = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09])
        #expect(BigUInt(bytes).data() == bytes)
        #expect(BigUInt(Data([0, 0, 5])).data() == Data([5]))
        #expect(BigUInt(Data([5])).data(count: 4) == Data([0, 0, 0, 5]))
        #expect(BigUInt(Data()).isZero)
    }

    @Test func sumsDifferencesAndProductsCarry() throws {
        let big = try #require(BigUInt(hex: "ffffffffffffffffffffffff"))
        let one = BigUInt(1)
        #expect((big + one).data() == Data([1] + [UInt8](repeating: 0, count: 12)))
        #expect((big + one) - one == big)
        #expect(big * big == BigUInt(hex: "fffffffffffffffffffffffe000000000000000000000001"))
        #expect(big % BigUInt(hex: "10000000000000001")! == BigUInt(hex: "ffffffff00000000")!)
        #expect(BigUInt(7) % BigUInt(hex: "10000000000000001")! == BigUInt(7))
    }

    @Test func powersAreReducedAsAnotherImplementationHasThem() throws {
        let cases = [
            ("7ebff2867347214cdd2055930d6eaf14f4733f3e7d1bfbc7a2ea20b2f14c942e05319acb5c74273f98e2774cbd87ad5c90a9587403e430ec66a78795e761d17731af10506bf2efc6f877186d76b07e881ed162ae2eb1547f15052434b9b5df9e7769b10f4205b4907a70c31012f037b64ce4228c38fb2918f135d25f557203301850c5a38fd547923a736994e3bf911a61dbe22e44158bae97ba94d0eda82f8f6d05584ef8aa38922766581e27a1c08a6a63ec24ede6a46b4cb2424a23d5962217beaddbc496cb8e81973e0becd7b03898d190f9ebdacc0cb1e29c658cda1495e60af593bd04cf0fd630f1f29d0da9953f48f1a09f76b5a170b33839263059f28c105d1fb17c2390c192cfd3ac94af0f21ddb66cad4a268d116ece1738f7d93d9c172411e20b8f6b0d549b6f03675a1600a35a099950d836f675cc81e74ef5e8e25d940ed904759531985d5d9dc9f81818e811892f902bd23f0824128b2f330c5c7fd0a6a3a4506513270e269e0d37f2a74de452e6b438", "5d17f9acae01f5057ca02135e92b1d3f28ede0d7ac3baea9e13deef86ab1031d0f646e1f40a097c976bf46c697d2caf82eeeacbe226e875555790f82ec1d3fcff2a3af4d46b0a18e8830e07bc1e398f1012bd4acefaecbd389be4bcfc49b64a0872e6cc3ababced2057ee05cde00902c7", "90fbbd119c1caaf75e8766ed88daf4016b4013ef254b0c4e010c4759482c9cbc43435cc52eae05cf96d0cc5fd4c28c2e7c26847f0316909e3bbbe9eaa8948c893b61867626bb7dbd2d1c9af0153e7c2a26a2c0bd3b1287fff52ddf5d616499c9e25a7605aec6f0245bd86d40fc891b4a6a50df4db4d66a3a47469a4d8cdb305fdd2e16096e36aab0d1bc52d9230d977ee22571594720771f8ca8181166d2287672fdf2022a96fb1a14a0f9e77f1b103cdf1582b0eab477d26415479c65dc9f503f63af83bd0561e6211c70cf49952399c4aaeac137dc76fb0f17a3007e62aa0a1df9fd789c6539382b0537e65affb2297631a992f0ce583505c6af0758d5563dab2cd31ee315128862c33a4fb774eb5248db40af72158370d269a9a5ae658f33fe3b890b93f448b3a5aa3c814f426dcbb394fb36bb2d420f0f88080b10a3d6b2aa05e11ab2715945795e8229451abd81f1d69ed617f5e837d70820fe119a72d174c9df6acc011cdd9474031b7f26144b98289fcd59a54a7bb1fee08f57124243", "5b2317d99b5348a3596ef57144abb3ae760a0c18411e9d335bb59d66110604300096b6129e27b6a816b1ef98955ae1c41c433eb908d5b043a3ad9e7a693467fba178990b078cdb444e203438c0550877fd303315d3f03da7a9d4d80e58cbae4f653a9a133909428cf093f5050159f564f101e6592a9e2954911d13d3460793bcc33e6cb55f0be4ea83ec2d607abcf799375776f0d388e905f715118f355a13a02615396aed0860455911bb6f47daaf33686075e93001b419116429faaeef61e7b4552da6de60e0574c399c3e2a8d26ba751e65a1ed3ac0ee64ebe3b06826d1c5381df98a4a619592628d56d24d06efd5c8101ab6c4200b3008fdf99fd4dbf9ba187418f23b756d1ba699ee27837259c909e8445390f2bcc79d88fad981591097ebadfcc07f02cf1814a5c51ffec0b3b7233a312f65433812bb087b2470fff0330d57e945d375038f0376423b07ea0883e5a2ae42c6c34861aa82281efd7842b6a23cc2c8f1269fc83b8549d24f8600a538556759cb50fcc188a302b0b52126c0"),
            ("8b0d59b0a844e52587be6b5c9bcf35873be078f3b7a50df373ca533488f87605e999f3842e7fc229540a6eb12aa1f6d42fddbb7a86f7a243c71b9abd87a86557b6fb7ebfeaa1551a28f7b324e4e25a15fc899e4fd58dbe7bdc968b7afb2c68774b15d7fa529ba3fe3bfada7cf20724d953ee261d87cec31f7296ab7961fd925d39d0a89a2ef80f58ee8571f4998d7c4093f6dea268aa872607679d6050914a9d33a01c353c631cdfd43f371200339d068739fa9d1de2a05d158a2ff2ee4e4519f9919c895fd7b326b94c7f9118bb16000f49c81a358ca00d75985d99c94309570dc1951c2442f9298cb3a570ccec313571810afc132d0d113db17d30cbc97d0fef792866836886a260cd0b7b45145c1a81682c64e50cad66237a0465e7e4236472f1a38f2c6ec8cc4169a3ae3a2b7fdfe01893f3aed0b6c7ac1491def88334e647cb8f74e69a5d0dd27a65bd628881ad1b72dba7abe1c29e1a8ef4f341e07a83f73f16dbf4a8b2b0c4312d20203626f3fe39c0519088f5", "ccfbf33609cfc865239194242a2eddbbd5464ecc280b0c08bc77024208aa4248c8857f9a43908f227c59db9165b0ee76f2ac34446e883a1d45de0099784b5a81842d87208d86f40f6b239f3c7174c77a2dd02de92a49636a2fa7f0eab4c4f9b0687322e25c215a82a06ec41adea057543", "f7216e9ee7a46309973f798626b1cffc070d710920859634fe3c9c8f2b855c1f28aaca51b98c67c215bd448ff26149edbe4c5ce666c1494e7691b06f6555abfeb8c9817af8be8831f237e45acd02c5e116353d03551fd8f9a2c68e45ca04c79f6f15b6ad2db3997fe39639be7a605a91330698a1c0093492b6246771c845007063771407e8e727891eb20109a91c2439d5ab8b4d15b40aeba4a45effccb573d95810d60ea72991b9e8c147437abec539007d1034d726c86b9c3a23cde67a9b75fc3947249fc2d0a17b8f2ab53451d0135675f6ad325b55dd785729763a12917c1a26f88938703800149e259b5d58c705f979d04af47aebdd597a1ecffcf00fecb91ee9e5efe09f07cefe2a1f727d83495822cb77f4de2c089aea6429b1491e243192b7044259405278e4b98d4787f93bca44eb860726e25cfd56a926076b3e36bb2313f55b06258e7e26f36a8483f8b8332dd3313a0b9965cda6c6fdbd68516766934036d17e44973d4882a5ce5b2a9231f51707da45e18ac2216b02fc241d0b", "24c543420e14dde5c5e26bba40d52d27b938a80aed5c033d623357325a4bb177ec8520e1e93f6c1fda627b72a1e8064df022e60ceefba4ba9c0795dc305862dd67addc01bc13aa63336c46017785d7eec21488487f680de5326678fb16de2e950c933edd724295864754b4bd67762636c1640312991f5a9922b6d8dffa5fb152e3fd84619e70b169bb09f2ba7efb670a6a0a6f33fdc63404a5fbc08866009ea50dad014192d3aca18cc06110b08e033f8fa7315aaae34441528c1c9f719e7e39b9b4a400d8c5024375a1742cd723aa444269d2e96c27d7e5939f582f35bb2277c9b20fc63bb8704e4f32a75a967a890897dd9e4307ffdc5d74da151d139fede2e07aaa79dfe3d5b9a932b36eefb75435cda5e9332fbe999598a9005ba8ad264926fda6128db920435a8c7a03b5f3ce44b3c77c7ea0da69b340c7eedb6631ee43c06dfe90d28074c9c13a5259cdacbb9334d3717e309b015c8a64aa8d87fada1b52c445873c95d54387a02953275d29ba03b9304810f8b3327dbbe98dfc8bd2c0"),
            ("c6c80ec8c614b27b8444d18e31704187ddaeb784b28054aead44b0537390e50fcf31ca8e752fdf1ece615db9a6442e9e7d6b377936d536243d35702c1eea1f265974a7cc966f46c6aa7d550101b8119bca3cb72ee0289dc6c91b9270ac06acdf70301704c9d78d82b335998604871926debfdb8825ae562179b37d806c10b5e0cfab4ceaefc4d2d3bf6d016bae4b5b844a7034e77ffe48d0a6ec179556585ea997f351754a09cde5cfedfa5a9196f0bd6b881ae8f6e0bd0f977044218e0b7bd58dcdb46b4468068b5ab3ee4265bb31537409029620bf0dc38084a03d93fd4c804c25d64affdcd13678bc8d40783f0a072a98d23606defcdfb85c0dd37ee91531dec4f4df2a8b79fc8e80b36f0e228923a5ef88ef02090bbfdefc1586ce03f91a4f44f9a6511445b9f3635cf88c422bcca2a92b03a56cc1057a40b22188287e8c5c715f8c74fc1e27e9e06f59b44e92effddeeaa842bc19796f74adfaf55496988af3fbd39630d69c9011ef256badf9a7e6529bce76e9f4", "746f5a1b4b156d1ad330c16a3831d03bf9b2bd6c0816bee06f92e23399ccea098535b6a437178ba0a1038f0b5e998d0eee4ddf9b9c28ee907072235c28fcd7f4073c1cd2c81f98b521905d591c5b2e75a0acd8be146e4099030f970583f9d52f90e8bec948f6f915fe21b37ca1b29fc99", "c9d22950eb25f8a1fc2e6a591ce3bc0c10755c97f5f554ed83239ef54ba2e1619fb9af5084768b8c54dd0ba5626467ba04a10547b401ba8570c1dca1756b72898dd63cb95685d62404fcd5555daf106db8dee081179a071e518ae4525b4b1b75321c52966bd8c67656d050cd6760136783feb17bfe7b8ae46e7836a4b4d19ec12955d6f03945336bd51b1815aaf719f3fd68373b29acf1a57cbd1f5ae28af60465f4298618189af4f3d74f82bf268ea03836e86577bd891ff7b103df23231e1ee201552240cbacd0249a45845dbe3023a906922fa4b9a9c4b753a1eef08360852789d059c6e50df2e5a3863e1f525265c8b007ee4d82feacab6286cd3672d6ae12b80aed6da79a873d9a8079abd0d7fb1292618550e40d54712ea6b36471fde41f229dd06aa8b9e0231b3e14729135bdd70a39d133dcd77ff179f2d2e48b96628f3c4be3ec3b96054274a3ebed84e91ef132bf2de040015ce064a11485f1115bb2fff17b3f665edef10637ce81fc069e7a609683ceaf4915888564e88216858f", "8c0908e69a75afebd234d025491b795772792c390146082ec7f2235b10503704e375e3118c215d7835916c6289e5c0a816fc6647d9f3d73e0a27a589102043bd82c92093af08c554a377131bfb1d8e31616152681b050140711ac0ec96d279adeaf5e4c435cd7bceaec60fa6652e2cdfb3807607be0b2335205bb61bc9f9de7f706d4f519983983c2b5c2be50e9d9354749c1e183dc405e9958cd1ac09f4927494958af6575106ba281227242e69f21d82023de067d566627221791c991ffc1ce7235747e91ee3fe199950343e7049f6983de4741e85f5f93e6b900d5c5a054ad8327d679bc5c5b39bbdbba128e4e3943aeea57260f4f1638fcd88b89067f42a68074ab6db87d9d3a68768d070cab61eb5df24bc0c978b6ea70580b0067e4f56b966b4613184a1c8d85f41a8df46cc7ec72d52214ffa74a6b8d51363aa70000ba16ae889313df5ea2f0818fb521e1f93d2435e394e88d0aa0b1fbfb594d98364269f05611762a875c10f189242a5dbe67ca60d23b1b98f1a4237f0aaa652b7fd")
        ]
        for (base, exponent, modulus, result) in cases {
            let power = try #require(BigUInt(hex: base)).power(try #require(BigUInt(hex: exponent)), modulus: try #require(BigUInt(hex: modulus)))
            #expect(power == BigUInt(hex: result))
        }
    }
}

@Suite struct PairingTests {
    /// An exchange worked out by another implementation, with a salt that starts with a zero.
    @Test func theProofIsWhatASpeakerExpects() throws {
        let client = SRPClient(secret: Data(hex: "0a227385459c945c43fc052715850a031ad2d5f1e05b3e13f8c110fb3a828159"))
        #expect(client.publicKey == Data(hex: "ab77ab44af3a0da4e365850d2376dbe6000170f7cead58be7530dde8deb005ada6000e8785ebbad7b9edff90da4f9c54a1999031e135799bddd8c2e13c855cfd7b75465adddd60a6a3125b86f4513a573fc916adf0f35704f0aa70bd6c67ab921f6dc736bdbf43c9cea644445033ce293ae35af5a4ed675fd6e5e82c569d167143ea251d5a84d8c3dbf2ce6cc62436c5828575b48a458fdbfef9041a44db0b8a0d480f703cfc8ff6c914e5b7ae6a0bcd79b89af965dd765fdb9a7b97057c3680ebfab19c1bbd8c84aece977f15942cd7229bb80c808f10529279bde5829f701c01e857a202bd3ea2b9daa446852a551dfaf6d77dfaa11a28cb7c5b9af266e32fa2a123e55931c155a14d22790626db157c82307968e2df2e2af9f3d80da386144e0562446eab59404bbea186868286735803497ee2e81491e604e6f4d8e62da31f27600be3e20e16ab9567332300c06129d136b048e055e86afec57c4e83fe32dc429f7b67922b33105e09cd25f78143ba7f93d8a5af2d9b8632aa47d9ee5e02"))
        let proof = try #require(client.prove(username: "Pair-Setup", password: "3939", salt: Data(hex: "00e7c72e45c121d16cd9e9add1f24267"),
                                              serverKey: Data(hex: "7d90db775834007630d515f355d00f857409e77bc1ef09704f25454e5310a3a03bff92b17f179202a531105681c5b4ee2b95e50aad66fee8c9de10a642fdddd50e0f486fd2902d4958654fe381fa8241b773086588165416b0f67d9b685733f7e8b944d9d44c8b799e4c797b57dfc25ec62c5139025373fe7d2f3c6b6a45826ec07c78607d046d52455b007533267343e98f0b999d28263c170047e1fa0b4de402359d7714f1726d0e9a2609706847e58712ae7457ca7e79b4cff2fa093ec225dd4d8048c83225f05141fb90bfca6b95d918c51da60db1cbc0fd55fd08765b6886f60c24595796f272ba67ebeed984b0cde5ddb2d67ed3543c20c36e14afcdcc4200118823ee60781d0f610824a0f808de1c60cac736cd548693d5df91fdeffedf21a9cb0e76bf33f7e033b8bfe11e81953ed5642a465f835987e66a17a97cb63a62ac5105cda578dd61dc41ad248d54ca6d2e0d62be523ebff9530de2bbd41663e73fe984c7969421d9d10a01f293a457ed24c0e5a2780cba52178edd51748b")))
        #expect(proof.key == Data(hex: "72561cfb7f46e77bf9f4cf53927457919d0c7733a161ac07a8a20770b91eb8da391323c59bc01964726d696ea767491050b0435d87df4a87d1f1d6d5866f525f"))
        #expect(proof.proof == Data(hex: "51f34748132cdea2366ca9f8cf7c9b88b3378d7ed5ca01235b323ac15e163e398c2021b207284bd5c166cae8123ed15a3a1e72d396f292cf97c47926a0062463"))
        #expect(proof.answer == Data(hex: "7c21d17079931490b65885c4046283e3a82788d93693a164afbd6adbb22ae424fda57042fb77bc61026239fb0a624f309af79e797e7d5da6752ff05d86008ab4"))
        #expect(client.prove(username: "Pair-Setup", password: "3939", salt: Data(hex: "00e7c72e45c121d16cd9e9add1f24267"), serverKey: Data([0])) == nil)
    }

    @Test func longValuesAreSplitOverSeveralFields() {
        let long = Data((0..<300).map { UInt8($0 % 251) })
        let message = TLV8.encode([(TLV8.state, Data([3])), (TLV8.publicKey, long)])
        #expect(message.count == 3 + 2 + 255 + 2 + 45)
        #expect(Array(message[3..<5]) == [TLV8.publicKey, 255])
        let fields = TLV8.decode(message)
        #expect(fields[TLV8.state] == Data([3]))
        #expect(fields[TLV8.publicKey] == long)
    }
}

@Suite struct NetworkClockTests {
    private let clock: UInt64 = 0x1122_33FF_FE44_5566

    @Test func messagesAreTheLengthTheySay() {
        let messages = [
            PTP.announce(clock: clock, sequence: 1), PTP.sync(clock: clock, sequence: 2),
            PTP.followUp(clock: clock, sequence: 2, sentNanos: 5), PTP.signaling(clock: clock, sequence: 3),
        ]
        #expect(messages.map(\.count) == [76, 44, 96, 106])
        for message in messages {
            #expect(Int(message[2]) << 8 | Int(message[3]) == message.count)
            // The dialect speakers listen to, version 2, from our clock.
            #expect(message[0] >> 4 == 1)
            #expect(message[1] == 2)
            #expect(Array(message[20..<28]) == [0x11, 0x22, 0x33, 0xFF, 0xFE, 0x44, 0x55, 0x66])
        }
        #expect(messages[1][0] & 0x0F == 0)
        #expect(Array(messages[1][30..<32]) == [0, 2])
        // Sync says a second message follows with the time; that one doesn't.
        #expect(messages[1][6] == 0x06)
        #expect(messages[2][6] == 0x04)
    }

    @Test func timesAreSecondsThenNanoseconds() {
        #expect(Array(PTP.timestamp(3_000_000_007)) == [0, 0, 0, 0, 0, 3, 0, 0, 0, 7])
        let late = PTP.timestamp(UInt64(0x1_0000_0002) * 1_000_000_000)
        #expect(Array(late.prefix(6)) == [0, 1, 0, 0, 0, 2])
    }

    @Test func aDelayRequestIsAnsweredWithItsOwnIdentityAndNumber() throws {
        var request = Data([0x11, 2, 0, 44]) + Data(count: 16)
        request.append(contentsOf: [9, 8, 7, 6, 5, 4, 3, 2, 0, 1])
        request.append(contentsOf: [0x12, 0x34, 0, 0x7F])
        request.append(Data(count: 10))
        let answer = try #require(PTP.delayResponse(to: request, clock: clock, receivedNanos: 2_000_000_001))
        #expect(answer.count == 54)
        #expect(answer[0] == 0x19)
        #expect(Array(answer[30..<32]) == [0x12, 0x34])
        #expect(Array(answer[34..<44]) == [0, 0, 0, 0, 0, 2, 0, 0, 0, 1])
        #expect(Array(answer[44..<54]) == [9, 8, 7, 6, 5, 4, 3, 2, 0, 1])
        #expect(PTP.delayResponse(to: PTP.sync(clock: clock, sequence: 1), clock: clock, receivedNanos: 0) == nil)
    }

    @Test func syncPacketsOnTheClockCarryItsTimeAndIdentity() {
        let packet = RAOP.clockSyncPacket(first: true, heard: 1_000, clockNanos: 0x0102_0304_0506_0708, clock: clock)
        #expect(packet.count == 28)
        #expect(Array(packet.prefix(4)) == [0x90, 0xD7, 0x00, 0x06])
        #expect(Array(packet[4..<8]) == [0, 0, 0x2F, 0x03])
        #expect(Array(packet[8..<16]) == [1, 2, 3, 4, 5, 6, 7, 8])
        #expect(Array(packet[20..<28]) == [0x11, 0x22, 0x33, 0xFF, 0xFE, 0x44, 0x55, 0x66])
    }

    @Test func featureBitsSayWhichFormASpeakerTakes() {
        // A Sonos or WiiM: AirPlay 2, pairing without a code, and the network clock.
        #expect(AirPlayBrowser.usesAirPlay2(features: "0x445F8A00,0x801C340", flags: "0x4"))
        #expect(AirPlayBrowser.features("0x445F8A00,0x801C340") >> 41 & 1 == 1)
        // A speaker of the first AirPlay only, and one that wants a PIN.
        #expect(!AirPlayBrowser.usesAirPlay2(features: "0x4A7FFFF7", flags: "0x4"))
        #expect(!AirPlayBrowser.usesAirPlay2(features: "0x445F8A00,0x801C340", flags: "0xC"))
        #expect(!AirPlayBrowser.usesAirPlay2(features: nil, flags: nil))
    }

    @Test func theControlChannelsTwoEndsUnderstandEachOther() throws {
        let secret = Data((0..<64).map { UInt8($0) })
        var sender = ControlCipher(secret: secret), speaker = ControlCipher(secret: secret, answering: true)
        let request = Data((0..<2_500).map { UInt8($0 % 256) })
        var wire = try sender.seal(request)
        // Three pieces, each with two bytes of length and a 16-byte seal.
        #expect(wire.count == 2_500 + 3 * 18)
        var arrived = wire.prefix(1_000)
        var plain = try speaker.open(&arrived)
        #expect(plain.isEmpty)
        arrived += wire.dropFirst(1_000)
        plain = try speaker.open(&arrived)
        #expect(plain == request)
        #expect(arrived.isEmpty)
        wire = try speaker.seal(Data("ok".utf8))
        #expect(try sender.open(&wire) == Data("ok".utf8))
    }

    @Test func audioPacketsAreSealedWithTheirNumberAndTimestamp() throws {
        let key = SymmetricKey(data: Data(repeating: 7, count: 32))
        let payload = Data((0..<100).map { UInt8($0) })
        let packet = try RAOP.sealedAudioPacket(sequence: 0x0102, timestamp: 0x0A0B0C0D, source: 0, first: true,
                                                payload: payload, key: key)
        #expect(packet.count == 12 + 100 + 16 + 8)
        #expect(Array(packet.prefix(8)) == [0x80, 0xE0, 0x01, 0x02, 0x0A, 0x0B, 0x0C, 0x0D])
        // The nonce's varying part closes the packet: the number, low byte first.
        #expect(Array(packet.suffix(8)) == [0x02, 0x01, 0, 0, 0, 0, 0, 0])
        let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: Data(count: 4) + packet.suffix(8)),
                                           ciphertext: packet[12..<112], tag: packet[112..<128])
        #expect(try ChaChaPoly.open(box, using: key, authenticating: packet[4..<12]) == payload)
    }
}

private extension Data {
    init(hex: String) {
        self.init()
        var text = Substring(hex)
        while !text.isEmpty {
            append(UInt8(text.prefix(2), radix: 16)!)
            text = text.dropFirst(2)
        }
    }
}
