import Foundation

/// This catalog ranks running applications; it never adds installed but inactive apps.
/// Exact aliases avoid promoting unrelated apps such as meeting notes or helper tools.
enum PreferredApplicationCatalog {
    private struct Entry {
        var bundles: Set<String> = []
        let names: Set<String>
    }

    // Preserve the user's first five choices, followed by other common meeting clients.
    // Some vendors have multiple packages; localized names cover unlisted bundle variants.
    private static let entries: [Entry] = [
        Entry(bundles: ["com.tencent.meeting"], names: ["腾讯会议", "tencent meeting", "tencentmeeting", "voov meeting"]),
        Entry(bundles: ["com.google.chrome"], names: ["google chrome", "google chrome beta", "google chrome dev", "google chrome canary"]),
        Entry(bundles: ["com.bytedance.lark", "com.electron.lark", "com.bytedance.macos.feishu"], names: ["飞书", "feishu", "lark"]),
        Entry(bundles: ["com.tencent.xinwechat"], names: ["微信", "wechat"]),
        Entry(names: ["meeting"]),
        Entry(bundles: ["us.zoom.xos"], names: ["zoom", "zoom.us", "zoom workplace"]),
        Entry(bundles: ["com.alibaba.dingtalkmac"], names: ["钉钉", "dingtalk"]),
        Entry(bundles: ["com.tencent.weworkmac"], names: ["企业微信", "wecom", "wework"]),
        Entry(bundles: ["com.microsoft.teams", "com.microsoft.teams2"], names: ["microsoft teams", "microsoft teams classic", "teams"]),
        Entry(bundles: ["com.cisco.webexmeetingsapp", "com.cisco.webexteams"], names: ["webex", "webex meetings", "cisco webex", "cisco webex meetings"]),
        Entry(bundles: ["com.tinyspeck.slackmacgap"], names: ["slack"]),
        Entry(bundles: ["com.apple.facetime"], names: ["facetime", "face time", "facetime 通话"]),
        Entry(names: ["华为云会议", "华为会议", "huawei cloud meeting", "huawei meeting"]),
        Entry(names: ["welink", "华为云welink", "华为云 welink", "huawei welink"]),
        Entry(names: ["瞩目", "zhumu"]),
        Entry(names: ["小鱼易连", "xylink"]),
        Entry(names: ["好视通", "好视通云会议", "fastmeeting"]),
        Entry(names: ["全时云会议", "全时会议", "gomeet", "gnet meeting"]),
        Entry(names: ["会畅通讯", "会畅云会议", "bizconf", "bizconf video"]),
        Entry(names: ["gotomeeting", "goto meeting", "goto"]),
        Entry(names: ["amazon chime", "chime"]),
        Entry(names: ["bluejeans"]),
        Entry(names: ["jitsi meet", "jitsi meet electron"]),
        Entry(names: ["google meet"])
    ]

    static func order(bundleIdentifier: String, name: String) -> Int? {
        let bundle = bundleIdentifier.lowercased()
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Prefer bundle identity if a running app has a renamed/localized display name.
        if let index = entries.firstIndex(where: { $0.bundles.contains(bundle) }) { return index }
        if bundle.hasPrefix("com.google.chrome.") { return 1 }
        return entries.firstIndex(where: { $0.names.contains(name) })
    }
}
