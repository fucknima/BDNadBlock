"""关于菜单 / 免责声明 / 群链接守卫的源码契约回归；不执行 UIKit，不验证外链可达或真机 UI。"""

from pathlib import Path
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
assert "非官方" in source and "备份" in source and "依法不可免除" in source
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
assert "BDNadAboutDisclaimerText" in presenter and "免责声明与使用须知" in presenter
assert presenter.index("我已阅读并知悉") < presenter.index("BDNadPrefsAcknowledgeDisclaimer")
assert source.count("message:BDNadAboutDisclaimerText") == 1   # 只有这一个展示点
assert [m for m in methods if "BDNadPrefsAcknowledgeDisclaimer" in m] == [presenter]
manual = method("bdShowDisclaimer")
assert "bdPresentDisclaimerFirstUse:NO" in manual
assert "BDNadPrefsAcknowledgeDisclaimer" not in manual

# 元数据 key 与版本常量：独立于 21 个净化键，只写这一个固定 key。
specs = prefs.split("BDNadPrefsSpecs[] = {", 1)[1].split("};", 1)[0]
assert len(re.findall(r'^\s*\{"', specs, re.M)) == 21
assert "BDNadBlockDisclaimerAcknowledgedVersion" not in specs
assert re.search(r'BDNadBlockDisclaimerVersion\s*=\s*@"\d{4}-\d{2}-\d{2}-v\d+"', prefs)
assert re.search(r'BDNadBlockDisclaimerAcknowledgedKey\s*=\s*@"BDNadBlockDisclaimerAcknowledgedVersion"', prefs)
reader = prefs.split("BDNadPrefsDisclaimerAcknowledged(NSUserDefaults *defaults) {", 1)[1].split("}", 1)[0]
assert "isKindOfClass:[NSString class]" in reader and "isEqualToString:BDNadBlockDisclaimerVersion" in reader
writer = prefs.split("BDNadPrefsAcknowledgeDisclaimer(NSUserDefaults *defaults) {", 1)[1].split("}", 1)[0]
assert "setObject:BDNadBlockDisclaimerVersion forKey:BDNadBlockDisclaimerAcknowledgedKey" in writer
assert "synchronize" not in writer and "removeObjectForKey" not in writer
print("PASS：关于分组/双行路由/群链接守卫/首次免责声明与元数据的源码契约；非 UIKit 运行验证")
