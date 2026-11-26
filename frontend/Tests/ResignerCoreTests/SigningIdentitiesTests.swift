import XCTest
@testable import NXCore
@testable import ResignerCore

final class SigningIdentitiesTests: XCTestCase {
    func testEveryIdentityOnceWithItsProblem() {
        let ids = SigningIdentities.parseIdentities(Fixture.text("find-identity.txt"))
        XCTAssertEqual(ids.count, 3, "the 'Valid identities only' part repeats the first one and is not read")
        XCTAssertEqual(ids[0], IdentityRecord(sha1: "0123456789ABCDEF0123456789ABCDEF01234567", name: "Apple Development: Jane Appleseed (ABCDE12345)"))
        XCTAssertTrue(ids[0].valid)
        XCTAssertEqual(ids[1].problem, "CSSMERR_TP_CERT_EXPIRED")
        XCTAssertEqual(ids[2].problem, "CSSMERR_TP_NOT_TRUSTED")
        XCTAssertEqual(ids[2].kind, .distribution)
        XCTAssertEqual(SigningIdentities.parseIdentities("Policy: Code Signing\n  Matching identities\n     0 identities found\n"), [])
    }

    func testPEMsGetTheFingerprintOfTheirDER() {
        let der = Data("certificate bytes".utf8)
        let text = "SHA-256 hash: 00\nSHA-1 hash: WRONG\n" + TestMac.pem(der) + "keychain: \"x\"\n" + TestMac.pem(Data("second".utf8))
        let pems = SigningIdentities.parsePEMs(text)
        XCTAssertEqual(pems.map(\.sha1), [SHA1.hex(der), SHA1.hex(Data("second".utf8))], "the fingerprint is computed, not copied from the text")
    }

    func testCertificateTextInBothOpenSSLForms() {
        let old = SigningIdentities.parseCertificateText("""
        subject= /UID=ABCDE12345/CN=Apple Development: Jane Appleseed (ABCDE12345)/OU=TEAM123456/O=Jane Appleseed/C=US
        notBefore=Nov  6 10:00:00 2026 GMT
        notAfter=Nov  6 10:00:00 2027 GMT
        """)
        XCTAssertEqual(old.commonName, "Apple Development: Jane Appleseed (ABCDE12345)")
        XCTAssertEqual(old.team, "TEAM123456")
        XCTAssertNotNil(old.notBefore)
        let new = SigningIdentities.parseCertificateText("""
        subject=UID = ABCDE12345, CN = Apple Development: Jane Appleseed (ABCDE12345), OU = TEAM123456, O = Jane Appleseed, C = US
        notAfter=Jan 31 23:59:59 2027 GMT
        """)
        XCTAssertEqual(new.commonName, "Apple Development: Jane Appleseed (ABCDE12345)")
        XCTAssertEqual(new.team, "TEAM123456")
        let calendar = Calendar(identifier: .gregorian)
        XCTAssertEqual(calendar.dateComponents(in: TimeZone(identifier: "GMT")!, from: new.notAfter!).year, 2027)
    }

    func testACertificateWithoutItsIdentityHasNoPrivateKey() {
        let with = CertificateRecord(sha1: "AA", commonName: "Apple Development: A (X)", team: "TEAM123456")
        let without = CertificateRecord(sha1: "BB", commonName: "Apple Development: B (Y)", team: "TEAM123456")
        let joined = SigningIdentities.join(certificates: [with, without], identities: [IdentityRecord(sha1: "aa", name: with.commonName)])
        XCTAssertTrue(joined[0].hasPrivateKey)
        XCTAssertFalse(joined[1].hasPrivateKey)
        XCTAssertEqual(SigningIdentities.teams(joined).map(\.id), ["TEAM123456"])
    }

    func testCodesignWordsAreSorted() {
        XCTAssertEqual(TestSignResult.classify(status: 0, output: ""), .signed)
        XCTAssertEqual(TestSignResult.classify(status: 1, output: "probe: errSecInternalComponent"), .keyAccessDenied("probe: errSecInternalComponent"))
        XCTAssertEqual(TestSignResult.classify(status: 1, output: "error: The specified item could not be found in the keychain."),
                       .noPrivateKey("error: The specified item could not be found in the keychain."))
        if case .notTrusted = TestSignResult.classify(status: 1, output: "unable to build chain to self-signed root for signer") {} else { XCTFail() }
        if case .failed = TestSignResult.classify(status: 1, output: "something else") {} else { XCTFail() }
    }

    func testTrialSignatureSignsAScratchFileAndRemovesIt() {
        let mac = TestMac()
        let inspector = IdentityInspector(runner: mac.runner, tools: mac.tools)
        let tmp = mac.base + "/trial"
        try! FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        XCTAssertEqual(inspector.testSign(sha1: TestMac.certificateSHA1, temporaryFolder: tmp), .signed)
        XCTAssertTrue(mac.runner.commands.contains { $0.contains("--force --sign \(TestMac.certificateSHA1) --timestamp=none") })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tmp), [], "the scratch folder is gone")
        mac.runner.on("--force --sign", status: 1, out: "probe: errSecInternalComponent")
        XCTAssertEqual(inspector.testSign(sha1: TestMac.certificateSHA1, temporaryFolder: tmp), .keyAccessDenied("probe: errSecInternalComponent"))
    }
}
