import Testing
@testable import MeetingCore

private func app(_ id: String, _ name: String, pid: Int32 = 100) -> TargetApplication {
    TargetApplication(bundleIdentifier: id, name: name, path: "/Applications/\(name).app", processID: pid)
}

@Test func commonApplicationsKeepRequestedOrderWhileSilent() {
    let apps = [app("other", "Music"), app("meeting", "Meeting"), app("com.tencent.xinWeChat", "微信"),
                app("com.bytedance.Lark", "飞书"), app("com.google.Chrome", "Google Chrome"),
                app("com.tencent.meeting", "腾讯会议")]
    let choices = TargetApplication.choices(from: apps, outputActiveIDs: ["other"], selectedID: "", showAll: false)
    #expect(choices.map(\.name) == ["腾讯会议", "Google Chrome", "飞书", "微信", "Meeting", "Music"])
}

@Test func inactiveAppsAreHiddenButSelectionAndActiveSourcesRemain() {
    let apps = [app("editor", "Editor"), app("music", "Music"), app("selected", "Selected")]
    let choices = TargetApplication.choices(from: apps, outputActiveIDs: ["music"], selectedID: "selected", showAll: false)
    #expect(choices.map(\.id) == ["music", "selected"])
    #expect(TargetApplication.choices(from: apps, outputActiveIDs: [], selectedID: "gone", showAll: false).isEmpty)
}

@Test func installedFeishuIsPreferredEvenWithoutAudioOutput() {
    let feishu = app("com.bytedance.macos.feishu", "Feishu")
    let choices = TargetApplication.choices(
        from: [app("com.tencent.xinWeChat", "WeChat"), feishu, app("com.google.Chrome", "Google Chrome")],
        outputActiveIDs: [], selectedID: "", showAll: false)
    #expect(choices.map(\.id) == ["com.google.Chrome", "com.bytedance.macos.feishu", "com.tencent.xinWeChat"])
    // Bundle identity and localized display names should each work independently.
    #expect(app("com.bytedance.macos.feishu", "Localized name").preferredOrder == 2)
    #expect(app("unknown", "Feishu").preferredOrder == 2)
}

@Test func allAppsRemainAccessibleWhenDetectionFailsOrUserExpandsList() {
    let apps = [app("editor", "Editor"), app("music", "Music")]
    #expect(TargetApplication.choices(from: apps, outputActiveIDs: nil, selectedID: "", showAll: false) == apps)
    #expect(TargetApplication.choices(from: apps, outputActiveIDs: [], selectedID: "", showAll: true) == apps)
}

@Test(arguments: ["Zoom Workplace", "钉钉", "DingTalk", "企业微信", "WeCom", "Microsoft Teams", "Teams",
                  "Webex", "Cisco Webex Meetings", "Slack", "FaceTime", "华为云会议", "HUAWEI CLOUD Meeting",
                  "WeLink", "瞩目", "Zhumu", "小鱼易连", "XYLink", "好视通云会议", "全时云会议",
                  "会畅云会议", "GoToMeeting", "Amazon Chime", "BlueJeans", "Jitsi Meet", "Google Meet"])
func commonMeetingClientsRemainVisibleWhileSilent(name: String) {
    let client = app("fixture.vendor", name)
    #expect(client.preferredOrder != nil)
    #expect(TargetApplication.choices(from: [client], outputActiveIDs: [], selectedID: "", showAll: false) == [client])
}

@Test(arguments: ["us.zoom.xos", "com.alibaba.DingTalkMac", "com.tencent.WeWorkMac", "com.microsoft.teams",
                  "com.microsoft.teams2", "com.cisco.webexmeetingsapp", "com.cisco.webexteams",
                  "com.tinyspeck.slackmacgap", "com.apple.FaceTime"])
func meetingBundleIdentitySurvivesDisplayNameChanges(bundle: String) {
    #expect(app(bundle, "Localized application").preferredOrder != nil)
}

@Test func expandedCatalogPreservesPriorityAndDoesNotMatchUnrelatedNames() {
    let original = [app("tencent", "腾讯会议"), app("chrome", "Google Chrome"), app("feishu", "Feishu"),
                    app("wechat", "WeChat"), app("meeting", "Meeting")]
    let more = [app("zoom", "Zoom Workplace"), app("teams", "Microsoft Teams")]
    let choices = TargetApplication.choices(from: (original + more).reversed(), outputActiveIDs: [], selectedID: "", showAll: false)
    #expect(Array(choices.prefix(5)) == original)
    #expect(choices.count == 7)
    for name in ["Meeting Notes", "Zoom Helper", "Teams Updater", "Slack Notes"] {
        #expect(app("unrelated", name).preferredOrder == nil)
    }
    #expect(TargetApplication.choices(from: [], outputActiveIDs: [], selectedID: "", showAll: false).isEmpty)
}

@Test func helperProcessesBelongOnlyToTheirContainingApp() {
    let chrome = app("com.google.Chrome", "Google Chrome", pid: 42)
    #expect(chrome.ownsAudioProcess(pid: 42, executablePath: nil))
    #expect(chrome.ownsAudioProcess(pid: 43, executablePath: "/Applications/Google Chrome.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"))
    #expect(!chrome.ownsAudioProcess(pid: 43, executablePath: "/Applications/Google Chrome.app.backup/Contents/MacOS/Chrome"))
    #expect(!chrome.ownsAudioProcess(pid: 43, executablePath: nil))
}
