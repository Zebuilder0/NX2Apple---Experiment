import XCTest
@testable import ResignerCore

final class LocalTextTests: XCTestCase {
    func testArgumentsFillInOrderAndByPosition() {
        XCTAssertEqual(LocalText.format("%@ on %@", ["NX2Apple", "iPad"]), "NX2Apple on iPad")
        XCTAssertEqual(LocalText.format("%2$@ before %1$@", ["one", "two"]), "two before one")
        XCTAssertEqual(LocalText.format("100%% of %@", ["it"]), "100% of it")
        XCTAssertEqual(LocalText.format("no arguments", ["ignored"]), "no arguments")
        XCTAssertEqual(LocalText.format("%@ and %@", ["only one"]), "only one and ", "a missing argument is empty, not a crash")
        XCTAssertEqual(LocalText("k", "a").resolve { $0 == "k" ? "[%@]" : $0 }, "[a]")
    }
}

final class SHA1Tests: XCTestCase {
    func testKnownVectors() {
        XCTAssertEqual(SHA1.hex(Data()), "DA39A3EE5E6B4B0D3255BFEF95601890AFD80709")
        XCTAssertEqual(SHA1.hex(Data("abc".utf8)), "A9993E364706816ABA3E25717850C26C9CD0D89D")
        XCTAssertEqual(SHA1.hex(Data("The quick brown fox jumps over the lazy dog".utf8)), "2FD4E1C67A2D28FCED849EE1BB76E7391B93EB12")
        // 56 bytes: the padding needs a second block
        XCTAssertEqual(SHA1.hex(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)), "84983E441C3BD26EBAAE4AA1F95129E5E54670F1")
    }
}

final class VersionNumberTests: XCTestCase {
    func testComparesPartByPart() {
        XCTAssertLessThan(VersionNumber("26.0")!, VersionNumber("26.0.1")!)
        XCTAssertLessThan(VersionNumber("9.4")!, VersionNumber("26")!)
        XCTAssertEqual(VersionNumber("26"), VersionNumber("26.0.0"))
        XCTAssertGreaterThan(VersionNumber("27.2 (17C52)")!, VersionNumber("27.1.9")!)
        XCTAssertNil(VersionNumber("beta"))
    }

    func testDeveloperFolderToApp() {
        XCTAssertEqual(ToolPaths.xcodeApp(ofDeveloperDir: "/Applications/Xcode-27.2.app/Contents/Developer"), "/Applications/Xcode-27.2.app")
        XCTAssertNil(ToolPaths.xcodeApp(ofDeveloperDir: "/Library/Developer/CommandLineTools"))
    }

    func testEnvironmentIsFixedAndCarriesTheChosenXcode() {
        let env = ToolPaths(developerDir: "/Applications/Xcode-beta.app/Contents/Developer").environment(home: "/Users/jane", user: "jane")
        XCTAssertEqual(env["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(env["DEVELOPER_DIR"], "/Applications/Xcode-beta.app/Contents/Developer")
        XCTAssertNil(ToolPaths().environment()["DEVELOPER_DIR"], "without a choice, xcode-select's Xcode is used")
    }
}

final class LogRedactorTests: XCTestCase {
    let redactor = LogRedactor(home: "/Users/janeappleseed", user: "janeappleseed", names: ["Jane Appleseed"])

    func testHomeUserAndEmailGo() {
        let out = redactor.redact("copying /Users/janeappleseed/Library/Application Support/NX2Apple/shell for janeappleseed (jane@example.com)")
        XCTAssertEqual(out, "copying ~/Library/Application Support/NX2Apple/shell for <user> (<email>)")
    }

    func testCertificateHolderGoesTeamStays() {
        let out = redactor.redact(#"Signing Identity: "Apple Development: Jane Appleseed (ABCDE12345)" DEVELOPMENT_TEAM=TEAM123456"#)
        XCTAssertEqual(out, #"Signing Identity: "Apple Development: <name> (ABCDE12345)" DEVELOPMENT_TEAM=TEAM123456"#)
    }

    func testDeviceIdentifiersKeepTheirLastFourCharacters() {
        let out = redactor.redact("--device 00008112-001A2B3C4D5E6F70 id 4A1B2C3D-1111-2222-3333-444455556666 sha 0123456789ABCDEF0123456789ABCDEF01234567")
        XCTAssertEqual(out, "--device …6F70 id …6666 sha …4567")
        XCTAssertFalse(out.contains("001A2B3C"))
    }

    func testANameLearnedAtRunTimeGoesEverywhere() {
        XCTAssertEqual(redactor.redact("Team: Jane Appleseed (Personal Team)"), "Team: <name> (Personal Team)")
    }

    func testAShortUserNameIsOnlyTakenOutOfPaths() {
        let r = LogRedactor(home: "/Users/dev", user: "dev", names: [])
        XCTAssertEqual(r.redact("/Users/dev/x and /Users/dev and dev tools"), "~/x and ~ and dev tools")
    }
}
