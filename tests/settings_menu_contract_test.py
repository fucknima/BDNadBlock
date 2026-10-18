"""关于菜单 / 使用须知弹窗（原免责声明标题去重） / 群链接守卫的源码契约回归；不执行 UIKit，不验证外链可达或真机 UI。"""

from pathlib import Path
import json
import re

root = Path(__file__).resolve().parents[1]
source = (root / "SettingsMenu.h").read_text()
prefs = (root / "Preferences.h").read_text()
implementation = source.split("@implementation BDNadBlockSettingsViewController", 1)[1].split("\n@end", 1)[0]
methods = re.split(r"(?m)^- \(", implementation)[1:]


def method(signature):
    matches = [m for m in methods if signature in m.split("{", 1)[0]]
    assert len(matches) == 1, signature
    return matches[0]


assert re.search(r"BDNadAboutSection\s*=\s*BDNadPrefsGroupDiagnostics\s*\+\s*1", source)
for name, value in (("Disclaimer", 0), ("Group", 1), ("Count", 2)):
    assert re.search(rf"BDNadAboutRow{name}\s*=\s*{value}\b", source)
assert "BDNadAboutSection + 1" in method("numberOfSectionsInTableView:")
assert "BDNadAboutRowCount" in method("numberOfRowsInSection:")
assert '@"关于"' in method("titleForHeaderInSection:")

# 关于必须先分流，不能落到原来的默认分享日志分支或开关索引路径。
for signature, existing_path in (
    ("numberOfRowsInSection:", "bdSwitchRowCountInGroup:"),
    ("cellForRowAtIndexPath:", "bdSpecAtRow:"),
    ("didSelectRowAtIndexPath:", "BDNadPrefsGroupDiagnostics"),
):
    body = method(signature)
    assert body.index("BDNadAboutSection") < body.index(existing_path), signature
selection = method("didSelectRowAtIndexPath:")
assert "BDNadAboutRowDisclaimer" in selection and "BDNadAboutRowGroup" in selection
assert "bdShareLogFromCell:" in selection and "bdSwitchRowCountInGroup:" in selection

assert source.count("https://t.me/fuckAd1024") == 1
assert source.count("openURL:") == 1
opener = next(m for m in methods if "openURL:" in m)
assert "BDNadAboutGroupURLString" in opener and "completionHandler:" in opener
assert "weakSelf" in opener and "presentedViewController" in opener
assert "viewIfLoaded" in opener
assert "无法打开群组链接" in source
assert "tg://" not in source and "canOpenURL:" not in source

# 群链接守卫：每次打开一枚临时 observer，先撤再判；只看自己那个 scene，无 scene 才退回 app state。
assert "leftForeground" in opener
assert opener.index("removeObserver") < opener.index("success || leftForeground")
assert opener.index("if (success || leftForeground) return;") < opener.index("无法打开群组链接")
assert "UISceneWillDeactivateNotification" in opener and "UIApplicationWillResignActiveNotification" in opener
assert "windowScene" in opener and opener.count("BDNadMenuActiveAndVisible") == 2
assert source.count("addObserverForName:") == 1 and opener.count("removeObserver") == 1
assert "UISceneActivationStateForegroundActive" in source and "UIApplicationStateActive" in source
assert "复制链接" in opener and "关闭" in opener
assert opener.count("UIPasteboard") == 1 and opener.index("复制链接") < opener.index("UIPasteboard")

# 首次进入本页：viewDidAppear 先 super，只读元数据；与关于条目共用唯一一份正文，确认 handler 才写。
appear = method("viewDidAppear:")
assert appear.index("super") < appear.index("BDNadPrefsDisclaimerAcknowledged")
assert "bdPresentDisclaimerFirstUse:YES" in appear
assert "[NSUserDefaults standardUserDefaults]" in appear
assert "BDNadPrefsAcknowledgeDisclaimer" not in appear
presenter = method("bdPresentDisclaimerFirstUse:")
assert "BDNadAboutDisclaimerText" in presenter
# 弹窗标题统一「使用须知」（首次与手动共用）；旧长标题不得再出现。
assert 'alertControllerWithTitle:@"使用须知"' in presenter
assert "免责声明与使用须知" not in source
assert presenter.index("我已阅读并知悉") < presenter.index("BDNadPrefsAcknowledgeDisclaimer")
assert source.count("message:BDNadAboutDisclaimerText") == 1   # 只有这一个展示点

# 正文准确性：从正文常量区提取 ObjC 拼接字面量，逐段 json.loads 解码（\n、\"、\\ 交给 stdlib）
# 后拼接，必须与用户原文逐字完全相等（含标点、段间空行；标题行已从正文去掉，不做关键词抽查）：
DISCLAIMER_TEXT = "\n\n".join([
    "本项目仅供个人学习、技术研究与交流使用，不以商业盈利或侵犯第三方合法权益为目的。",
    "本项目为非官方第三方插件，与百度及百度网盘不存在任何关联。",
    "请自觉遵守相关法律法规及软件服务条款。如不具备合法使用条件，请勿下载、安装、使用或传播；如已获取，请立即停止使用并删除相关文件。",
    "本项目按现状提供，不对其兼容性、稳定性及适用性作出任何保证。",
    "如相关权利人对本项目存在异议，可联系项目维护者沟通处理。",
])
disclaimer_region = source.split("BDNadAboutDisclaimerText =", 1)[1].split(";", 1)[0]
disclaimer_segments = re.findall(r'@("(?:\\.|[^"\\])*")', disclaimer_region)
assert disclaimer_segments, "未从正文常量提取到任何 ObjC 字符串字面量"
assert "免责声明：" not in disclaimer_region, "正文不得重复“免责声明：”标题行"
assert "".join(json.loads(segment) for segment in disclaimer_segments) == DISCLAIMER_TEXT, \
    "声明正文与用户原文不一致"
assert [m for m in methods if "BDNadPrefsAcknowledgeDisclaimer" in m] == [presenter]
manual = method("bdShowDisclaimer")
assert "bdPresentDisclaimerFirstUse:NO" in manual
assert "BDNadPrefsAcknowledgeDisclaimer" not in manual

# 元数据 key 与版本常量：独立于 21 个净化键，只写这一个固定 key。
specs = prefs.split("BDNadPrefsSpecs[] = {", 1)[1].split("};", 1)[0]
assert len(re.findall(r'^\s*\{"', specs, re.M)) == 21
# 默认值：21 条规格的 default 列必须全为 NO（所有功能默认不开启；已保存值不受影响，见 preferences_test.mm）。
default_col = re.findall(r'^\s*\{"[^"]+",\s*"[^"]*",\s*(YES|NO)\s*,\s*BDNadPrefsGroup\w+\}', specs, re.M)
assert len(default_col) == 21, default_col
assert all(v == "NO" for v in default_col), default_col
assert "BDNadBlockDisclaimerAcknowledgedVersion" not in specs
assert re.search(r'BDNadBlockDisclaimerVersion\s*=\s*@"\d{4}-\d{2}-\d{2}-v\d+"', prefs)
assert re.search(r'BDNadBlockDisclaimerVersion\s*=\s*@"2026-10-18-v3"', prefs)   # 五段正文不变，保留v3已读状态
assert re.search(r'BDNadBlockDisclaimerAcknowledgedKey\s*=\s*@"BDNadBlockDisclaimerAcknowledgedVersion"', prefs)
reader = prefs.split("BDNadPrefsDisclaimerAcknowledged(NSUserDefaults *defaults) {", 1)[1].split("}", 1)[0]
assert "isKindOfClass:[NSString class]" in reader and "isEqualToString:BDNadBlockDisclaimerVersion" in reader
writer = prefs.split("BDNadPrefsAcknowledgeDisclaimer(NSUserDefaults *defaults) {", 1)[1].split("}", 1)[0]
assert "setObject:BDNadBlockDisclaimerVersion forKey:BDNadBlockDisclaimerAcknowledgedKey" in writer
assert "synchronize" not in writer and "removeObjectForKey" not in writer
print("PASS：关于分组/双行路由/群链接守卫/使用须知弹窗与元数据/21 项默认全 NO 的源码契约；非 UIKit 运行验证")
