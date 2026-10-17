"""关于菜单的源码契约回归；不执行UIKit，不验证外链可达或真机UI。"""

from pathlib import Path
import re

source = (Path(__file__).resolve().parents[1] / "SettingsMenu.h").read_text()
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
assert "viewIfLoaded" in opener and "window" in opener
assert "无法打开群组链接" in source
assert "非官方" in source and "备份" in source and "依法不可免除" in source
assert "tg://" not in source and "canOpenURL:" not in source
print("PASS：末尾关于分组、双行路由、唯一HTTPS链接与失败提示的源码契约；非UIKit运行验证")
