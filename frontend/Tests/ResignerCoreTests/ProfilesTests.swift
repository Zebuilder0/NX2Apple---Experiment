import XCTest
@testable import NXCore
@testable import ResignerCore

final class ProvisioningProfileTests: XCTestCase {
    let mac = TestMac()

    func parsed(_ dict: [String: Any]) -> ProvisioningProfile {
        ProvisioningProfiles.parse(plist: Data(mac.plist(dict).utf8), path: "/p")!
    }

    func testParseReadsWhatTheMatcherNeeds() {
        let p = parsed(mac.profile())
        XCTAssertEqual(p.uuid, TestMac.profileUUID)
        XCTAssertEqual(p.teamID, TestMac.team)
        XCTAssertEqual(p.applicationIdentifier, TestMac.team + "." + TestMac.bundleID)
        XCTAssertEqual(p.bundlePattern, TestMac.bundleID)
        XCTAssertEqual(p.devices, [TestMac.udid])
        XCTAssertEqual(p.certificates, [TestMac.certificateSHA1])
        XCTAssertEqual(p.kind, .development)
        XCTAssertEqual(p.entitlements[EntitlementPlanner.memoryLimit], .bool(true))
        XCTAssertEqual(p.entitlements["keychain-access-groups"], .strings([TestMac.team + ".*"]))
        XCTAssertNil(ProvisioningProfiles.parse(plist: Data("not a plist".utf8)))
    }

    func testKinds() {
        var adHoc = mac.profile()
        adHoc["Entitlements"] = ["application-identifier": "TEAM123456.org.nxnative.shell", "get-task-allow": false]
        XCTAssertEqual(parsed(adHoc).kind, .adHoc)
        var store = mac.profile(devices: [])
        store["Entitlements"] = ["application-identifier": "TEAM123456.org.nxnative.shell"]
        XCTAssertEqual(parsed(store).kind, .appStore)
        var enterprise = mac.profile(devices: [])
        enterprise["ProvisionsAllDevices"] = true
        XCTAssertEqual(parsed(enterprise).kind, .enterprise)
    }

    func testWildcards() {
        XCTAssertTrue(parsed(mac.profile(appID: "TEAM123456.*")).allows(bundleID: "org.nxnative.shell"))
        XCTAssertTrue(parsed(mac.profile(appID: "TEAM123456.org.nxnative.*")).allows(bundleID: "org.nxnative.shell.TEAM123456"))
        XCTAssertFalse(parsed(mac.profile(appID: "TEAM123456.org.other.*")).allows(bundleID: "org.nxnative.shell"))
        XCTAssertFalse(parsed(mac.profile(appID: "TEAM123456.org.nxnative.shell2")).allows(bundleID: "org.nxnative.shell"))
    }

    var need: ProfileRequirement {
        ProfileRequirement(bundleID: TestMac.bundleID, teamID: TestMac.team, certificateSHA1: TestMac.certificateSHA1, deviceUDID: TestMac.udid,
                           deviceName: "Jane's iPad", entitlements: [EntitlementPlanner.memoryLimit], now: mac.now)
    }

    func testAValidProfileHasNoIssue() {
        XCTAssertEqual(ProfileMatcher.issues(parsed(mac.profile()), need), [])
    }

    func testEachMismatchIsNamed() {
        let expired = Date(timeIntervalSince1970: (mac.now.timeIntervalSince1970 - 3600).rounded(.down))
        XCTAssertEqual(ProfileMatcher.issues(parsed(mac.profile(expires: expired)), need), [.expired(expired)])
        XCTAssertEqual(ProfileMatcher.issues(parsed(mac.profile(expires: mac.now.addingTimeInterval(86400 + 60))), need).first.map { $0.blocking }, false)
        XCTAssertEqual(ProfileMatcher.issues(parsed(mac.profile(appID: "OTHER12345.org.nxnative.shell", team: "OTHER12345")), need),
                       [.wrongTeam(profile: "OTHER12345", expected: TestMac.team)])
        XCTAssertEqual(ProfileMatcher.issues(parsed(mac.profile(appID: "TEAM123456.com.example.app")), need),
                       [.wrongBundle(pattern: "com.example.app", bundleID: TestMac.bundleID)])
        XCTAssertEqual(ProfileMatcher.issues(parsed(mac.profile(certificates: [Data("another".utf8)])), need), [.certificateMissing])
        XCTAssertEqual(ProfileMatcher.issues(parsed(mac.profile(devices: ["00008000-0000000000000000"])), need), [.deviceMissing("Jane's iPad")])
        XCTAssertEqual(ProfileMatcher.issues(parsed(mac.profile(memory: false)), need), [.entitlementMissing(EntitlementPlanner.memoryLimit)])
        var mac2 = mac.profile(); mac2["Platform"] = ["OSX"]
        XCTAssertEqual(ProfileMatcher.issues(parsed(mac2), need), [.notIOS])
    }

    func testCandidatesPreferAnExplicitLongLivedProfile() {
        let wildcard = parsed(mac.profile(expires: mac.now.addingTimeInterval(300 * 86400), appID: "TEAM123456.*", uuid: "W"))
        let short = parsed(mac.profile(expires: mac.now.addingTimeInterval(3 * 86400), uuid: "S"))
        let long = parsed(mac.profile(expires: mac.now.addingTimeInterval(6 * 86400), uuid: "L"))
        let expired = parsed(mac.profile(expires: mac.now.addingTimeInterval(-60), uuid: "E"))
        XCTAssertEqual(ProfileMatcher.candidates([wildcard, short, expired, long], need).map(\.uuid), ["L", "S", "W"])
    }

    func testEveryIssueHasItsText() {
        let issues: [ProfileIssue] = [.expired(mac.now), .expiresSoon(days: 1), .wrongTeam(profile: "A", expected: "B"), .wrongBundle(pattern: "a", bundleID: "b"),
                                      .certificateMissing, .deviceMissing("d"), .entitlementMissing("e"), .notIOS, .appStoreProfile]
        issues.forEach { Texts.check($0.text) }
    }

    func testLoadReadsXcodesFoldersOnce() {
        mac.installProfile(mac.profile(uuid: "OTHER"), at: mac.home + "/Library/MobileDevice/Provisioning Profiles/other.mobileprovision")
        mac.installProfile(mac.profile(), at: mac.home + "/Library/MobileDevice/Provisioning Profiles/copy.mobileprovision")
        let loaded = ProvisioningProfiles.load(home: mac.home, runner: mac.runner, tools: mac.tools)
        XCTAssertEqual(Set(loaded.map(\.uuid)), [TestMac.profileUUID, "OTHER"], "the same UUID in both folders counts once")
    }
}

final class EntitlementPlannerTests: XCTestCase {
    let mac = TestMac()
    var current: [String: EntitlementValue] {
        ["application-identifier": .string("OLDTEAM123.org.nxnative.shell"), "com.apple.developer.team-identifier": .string("OLDTEAM123"),
         "get-task-allow": .bool(true), "keychain-access-groups": .strings(["OLDTEAM123.org.nxnative.shell"]), EntitlementPlanner.memoryLimit: .bool(true)]
    }

    func testTheAppKeepsItsEntitlementsUnderTheProfilesTeam() throws {
        let profile = ProvisioningProfiles.parse(plist: Data(mac.plist(mac.profile()).utf8))!
        let plan = try EntitlementPlanner.plan(current: current, profile: profile, bundleID: TestMac.bundleID).get()
        XCTAssertEqual(plan.entitlements["application-identifier"], .string("TEAM123456.org.nxnative.shell"))
        XCTAssertEqual(plan.entitlements["com.apple.developer.team-identifier"], .string("TEAM123456"))
        XCTAssertEqual(plan.entitlements["keychain-access-groups"], .strings(["TEAM123456.org.nxnative.shell"]))
        XCTAssertEqual(plan.entitlements[EntitlementPlanner.memoryLimit], .bool(true))
        XCTAssertEqual(plan.entitlements["get-task-allow"], .bool(true))
        XCTAssertEqual(plan.dropped, [])
        let data = try EntitlementPlanner.plistData(plan.entitlements)
        let back = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        XCTAssertEqual(back?["application-identifier"] as? String, "TEAM123456.org.nxnative.shell")
    }

    func testAnEntitlementTheProfileLacksStopsUnlessTheUserChoseToDropIt() throws {
        let profile = ProvisioningProfiles.parse(plist: Data(mac.plist(mac.profile(memory: false)).utf8))!
        XCTAssertEqual(EntitlementPlanner.plan(current: current, profile: profile, bundleID: TestMac.bundleID),
                       .failure(.notGranted(EntitlementPlanner.memoryLimit)))
        let plan = try EntitlementPlanner.plan(current: current, profile: profile, bundleID: TestMac.bundleID,
                                               allowDropping: [EntitlementPlanner.memoryLimit]).get()
        XCTAssertNil(plan.entitlements[EntitlementPlanner.memoryLimit])
        XCTAssertEqual(plan.dropped, [EntitlementPlanner.memoryLimit])
    }

    func testOtherMissingAndUnsupportedEntitlementsStop() {
        let profile = ProvisioningProfiles.parse(plist: Data(mac.plist(mac.profile()).utf8))!
        var withPush = current; withPush["aps-environment"] = .string("development")
        XCTAssertEqual(EntitlementPlanner.plan(current: withPush, profile: profile, bundleID: TestMac.bundleID, allowDropping: [EntitlementPlanner.memoryLimit]),
                       .failure(.notGranted("aps-environment")), "only the memory limit may be left out")
        var odd = current; odd["com.example.dict"] = .unsupported
        XCTAssertEqual(EntitlementPlanner.plan(current: odd, profile: profile, bundleID: TestMac.bundleID), .failure(.unsupported("com.example.dict")))
    }

    func testBooleansAreNotNumbers() {
        let dict = try! PropertyListSerialization.propertyList(from: Data(mac.plist(["b": true, "n": 3, "s": "x", "a": ["y"]]).utf8), options: [], format: nil)
        let values = EntitlementValue.dictionary(dict)
        XCTAssertEqual(values["b"], .bool(true))
        XCTAssertEqual(values["n"], .number(3))
        XCTAssertEqual(values["s"], .string("x"))
        XCTAssertEqual(values["a"], .strings(["y"]))
    }
}
