# 净化设置菜单接线契约（Preferences.h + SettingsMenu.h）

给 hook 接线用的最小说明。**菜单只读写 NSUserDefaults，冷启动生效**：
只写本组件固定键（不修改账号、缓存或原生偏好），不热改 UIKit 列表/导航、
不自动杀 App、不清百度网盘任何数据。

## 1. 文件与 include 关系

| 文件 | 作用 | 谁 include |
|---|---|---|
| `Preferences.h` | 唯一规格表 + 读写原语（Foundation only） | `SettingsMenu.h`、`tests/preferences_test.mm` |
| `SettingsMenu.h` | 菜单 VC + 入口函数（UIKit） | 只给 `Tweak.xm` 一个 TU |
| `tests/preferences_test.mm` | macOS host 检查（无 UIKit） | CI（尚未接线，见第 6 节） |
| `docs/menu-contract.md` | 本文件 | 人 |

- 两个 header 都是单 TU header（内部 `static`），`Tweak.xm` 里 include 一次即可。
- 建议放在 `Tweak.xm` 顶部现有 `#include "FeatureRemoval.h"` 附近：
  ```objc
  #include "SettingsMenu.h"      // 内部已 #import "Preferences.h"
  ```
- 不要新增 `FILES`/`Frameworks`：`UIKit` 已在 `Makefile`，两个 header 不算编译单元。

## 2. 唯一选项清单（默认值只在 `Preferences.h` 规格表里写一份）

| key | 中文标题 | 默认 | 分组 |
|---|---|---|---|
| `BDNadBlockEnabled` | 启用网盘净化 | YES | 总开关 |
| `BDRemoveRecommend` | 隐藏推荐/创意区域 | YES | 首页 |
| `BDRemoveHomePromo` | 隐藏首页年卡促销 | YES | 首页 |
| `BDRemoveAITab` | 隐藏底部库库AI | YES | 首页 |
| `BDRemoveJobNovel` | 隐藏求职/小说入口 | YES | 首页 |
| `BDRemoveSearchPromo` | 隐藏搜索推广词 | YES | 首页 |
| `BDRemoveSearchAI` | 隐藏搜索框AI按钮 | YES | 首页 |
| `BDRemoveGameCenter` | 隐藏游戏中心 | YES | 我的 |
| `BDRemovePersonalPromotions` | 隐藏推广入口整排 | YES | 我的 |
| `BDRemovePersonalBanner` | 隐藏活动轮播 | YES | 我的 |
| `BDRemoveTaskCard` | 隐藏任务系统卡片 | YES | 我的 |
| `BDRemoveRenewButton` | 隐藏续费按钮 | **NO** | 我的 |
| `BDNadBlockNetwork` | 广告网络拦截·旧规则 | YES | 广告 |
| `BDNadBlockAdMethods` | 广告展示拦截·实验 | YES | 广告 |
| `BDNadBlockDumpOnly` | 仅诊断，不执行净化 | **NO** | 诊断 |

开关 **ON = 去除/拦截**。`BDNadBlockEnabled` / `BDNadBlockNetwork` /
`BDRemoveRecommend` / `BDRemoveGameCenter` / `BDNadBlockDumpOnly` 是旧版已有键，
默认值与 `Tweak.xm` 里 `BDDefault` 的 fallback 一致，老用户值继续被尊重。

## 3. 函数名（主会话按这些接线）

```objc
const BDNadPrefsSpec *BDNadPrefsSpecForKey(NSString *key);        // 未知 -> NULL
NSString *BDNadPrefsGroupTitle(BDNadPrefsGroup group);
BOOL BDNadPrefsDesired(NSUserDefaults *defaults, NSString *key);   // saved/期望值
BOOL BDNadPrefsSetDesired(NSUserDefaults *defaults, NSString *key, BOOL value);  // 只写 known key
NSDictionary<NSString *, NSNumber *> *BDNadPrefsSnapshot(NSUserDefaults *defaults);  // 纯函数，可多次调用
void BDNadPrefsInit(void);                                        // 启动时建快照（组件装完/页面组装前）
BOOL BDNadPrefsActive(NSString *key);                             // 本进程生效值（快照）
BOOL BDNadPrefsHasPendingChanges(void);                           // 有改动待冷启动
```

规则（组件 hook 必须按此接线）：

- **运行期判断一律用 `BDNadPrefsActive(key)`**，不要读 live defaults：
  总开关 OFF 或 `BDNadPrefsActive(@"BDNadBlockDumpOnly")` 为 YES 时**不净化**
  （`BDNadBlockEnabled && !BDNadBlockDumpOnly` 是所有去除/拦截开关的前置条件）。
- 未知 key：`BDNadPrefsActive` / `BDNadPrefsDesired` 返回 **NO**（fail-closed），
  `BDNadPrefsSetDesired` 返回 **NO** 且不落值；无反射调用。
- 建议把 `BDNadPrefsInit()` 放在构造器早期（`BDFRInstallAll()` 之前），
  这样 hook 读到的就是启动那一刻用户保存的值。
- 旧的 `BDEnabled/BDDumpOnly/BDRemoveRecommend/BDRemoveGameCenter` 可以改成
  `BDNadPrefsActive(...)` 的薄封装；本组件没改 `Tweak.xm`，由接线方决定。

## 4. 菜单入口

```objc
static inline void BDPresentPurificationSettings(UIViewController *host, NSURL *logURL);
```

- `host.presentedViewController` 非空（host 正在展示任何模态）-> 直接返回：不 push、不 present、
  不碰导航栈；接线方自己的按钮点不到就算了，不做强制 dismiss / 遍历窗口。
- 否则 `host.navigationController` 存在 -> `push`；否则 `present` 一层
  `UINavigationController` + 右上“完成”。
- 同一菜单已在导航栈里 -> `popToViewController` 回到它，不堆叠。
- 分享行点击时若本菜单自己已有 `presentedViewController`（分享/提示面板）-> 直接返回，不叠第二个面板。
- 只在主线程、由 UIKit 按钮触发时调用（内部 `[NSThread isMainThread]` 保护）。
- `logURL` 传现有日志文件 `Documents/BDNadBlock-dump.txt` 的 URL；
  文件不存在/不可读 -> `UIAlertController` 明确提示；可读 -> `UIActivityViewController`
  （iPad 已设 `sourceView`/`sourceRect`）。分享**不上传、不复制整份文件、不删除原日志**。
- 菜单自身文案已含：“保存后请彻底退出后台并重开百度网盘生效，不会自动退出；当前页面不热更新。”
  有待生效改动时 footer 前会加“有改动待生效。”。

示例（由接线方选一个真实入口，例如“我的-设置”某个按钮）：

```objc
NSURL *log = [NSURL fileURLWithPath:BDResolveLogPath()];   // Tweak.xm 里已有该函数
BDPresentPurificationSettings(self, log);
```

## 5. 不做的事（设计要求，别在接线时加回来）

- 不写 `BHSettings` 原生开关、不删 unknown 键、不修改账号/缓存/原生偏好。
  唯一写入面就是 App 的 `NSUserDefaults` 里本组件那 15 个固定键。
- 不 `synchronize`、不直接改 plist 文件、不新增配置服务类/依赖。
- 不热更新（改完不 reload 网盘的列表/导航）、不自动杀 App、不加延时/锁/重试。
- 不新增日志系统、不复制整份日志、不上传、不收集账号信息。

## 6. 验证状态

- 本组件只新增 4 个文件，未改 `Tweak.xm` / `Makefile` / CI，`FeatureRemoval` 3 个 hook 与其测试未动。
- CI 需要新增一步（接线方加，本次不加）：
  ```
  clang++ -std=c++17 -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -framework Foundation -o "$RUNNER_TEMP/preferences_test" tests/preferences_test.mm
  "$RUNNER_TEMP/preferences_test"
  ```
- 真机 UI（菜单显示、开关、分享面板、冷启动后是否真的生效）**尚未验证**，
  需要装包后人工确认；host 测试只覆盖 `Preferences.h` 的读写/快照/规格表语义。
- host 测试里“新 defaults 实例读到已保存值”只是**同进程 suite 可见性**，
  不等同于已验证真实进程重启 / 落盘恢复；`BDNadPrefsGlobalSnapshot` 的
  “建一次就不再变”也只能在真机（或模拟器）上确认。
