# 净化设置菜单接线契约（Preferences.h + SettingsMenu.h + MenuEntry.h）

本组件的最小说明。**菜单只读写 NSUserDefaults，冷启动生效**：
只写本组件固定键（不修改账号、缓存或原生偏好），不热改 UIKit 列表/导航、
不自动杀 App、不清百度网盘任何数据。功能全貌见 [README.md](../README.md)。

## 1. 文件与 include 关系

| 文件 | 作用 | 谁 include |
|---|---|---|
| `Preferences.h` | 唯一规格表 + 读写原语（Foundation only） | `SettingsMenu.h`、`tests/preferences_test.mm` |
| `SettingsMenu.h` | 菜单 VC + 入口函数 `BDPresentPurificationSettings`（UIKit） | 只给 `Tweak.xm` 一个 TU |
| `MenuEntry.h` | 设置页导航条上的「网盘净化」按钮（UIKit） | `Tweak.xm`（在 `FeatureRemoval.h` 之后） |
| `tests/preferences_test.mm` | macOS host 检查（无 UIKit） | CI（已接线，见第 6 节） |
| `docs/menu-contract.md` | 本文件 | 人 |

- 这些 header 都是单 TU header（内部 `static`），`Tweak.xm` 里各 include 一次即可。
- 当前 `Tweak.xm` 的实际 include 顺序（依赖单向，别调换）：
  `Preferences.h` → `FeatureRemoval.h` → `TabRemoval.h` → `PersonalRemoval.h` →
  `PersonalViewRemoval.h` → `RenewButtonRemoval.h` → `TransferPromoRemoval.h` → `HomeBannerExperiment.h` → **`SettingsMenu.h`** →
  `SearchDataRemoval.h` → `SearchViewRemoval.h` → **`MenuEntry.h`** → `ResumeSplashRemoval.h` → `NetworkRules.h`。
- 不要新增 `FILES`/`Frameworks`：`UIKit` 已在 `Makefile`，这些 header 不算编译单元。

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
| `BDExperimentHideHomeBanner` | 隐藏顶部横幅容器·实验 | **NO** | 首页 |
| `BDRemoveGameCenter` | 隐藏游戏中心 | YES | 我的 |
| `BDRemovePersonalPromotions` | 隐藏推广入口整排 | YES | 我的 |
| `BDRemovePersonalBanner` | 隐藏活动轮播 | YES | 我的 |
| `BDRemoveTaskCard` | 隐藏任务系统卡片 | YES | 我的 |
| `BDRemoveRenewButton` | 隐藏续费按钮 | **NO** | 我的 |
| `BDNadBlockNetwork` | 广告网络拦截·旧规则 | YES | 广告 |
| `BDNadBlockAdMethods` | 广告展示拦截·实验 | YES | 广告 |
| `BDRemoveTransferYikePromo` | 隐藏传输页一刻相册 | YES | 广告 |
| `BDRemoveTransferGamePromo` | 隐藏下载小游戏引导 | YES | 广告 |
| `BDRemoveTransferCardPromo` | 隐藏免流办卡推广 | YES | 广告 |
| `BDNadBlockDumpOnly` | 仅诊断，不执行净化 | **NO** | 诊断 |

开关 **ON = 去除/拦截**。`BDNadBlockEnabled` / `BDNadBlockNetwork` /
`BDRemoveRecommend` / `BDRemoveGameCenter` / `BDNadBlockDumpOnly` 是旧版已有键，
默认值与老版本 fallback 一致，老用户值继续被尊重。

`BDRemoveHomePromo`（首页年卡促销）**功能本版未实施**：静态定位未收束，用户选择先做其它项。
菜单里那一行只呈现副标题「待定位，本版本暂时保留」，没有 `UISwitch`、不读也不写该键的
saved 值 —— 免得显示成「默认 YES 已生效」。规格表现有 19 个键，旧 18 个键与默认值不变，
其中这一个的默认 YES **只是保留配置**；启动日志里 `active BDRemoveHomePromo = 1`
也只是快照值，**不是该功能已接线的证据**。等定位收束后再接上真实开关。

传输页新增三项各自独立，均受总开关与非诊断条件控制，**不依赖** `BDNadBlockAdMethods`，改完冷启动生效：
一刻相册（两条 `-canShowYikeBanner`）、下载小游戏引导、以及免流办卡的 widget gate
（`-[BDPanFreeWidgetManage chechFreeUnicomWidget]`，`Q16@0:8`：只有原值 3 → 0，`0/1/2` 与其它
unsigned 值原样透传）。该 widget gate 只覆盖这一处判定：`refreshWidget` 里被否决后仍会继续判断
其它 widget（数据包/备份/试用等），**不代表底部从此全空**。同款 controller 还被备份详情页引用，
该页实际是否进入办卡分支未验证，不能断言只影响传输页。企业 manager 自有同名实现未被替换；企业版孪生 widget 与企业版一刻相册
都不在本版范围内（企业 Yike 的 base gate 实测直接 `mov 0` 返回，这条边界保留未处理）。
截图与运行实例之间**没有真机证据**：文案与分支只做到静态对应，设备效果未验。

开屏闸门（`ResumeSplashRemoval.h`）**受 `BDNadBlockAdMethods` 控制，不新增键**：
`-[BDNCUIAdvertisesManage needToShowSplashWithLaunchType:launchUrl:launchOptions:]`
（`B40@0:8q16@24@32`，自有实例方法，argc 5）**先调原实现一次**取原 bool，
仅当 `launchType` 是 **0（冷启动）/ 2 / 3（热启动）** 且原为 true 时改判 false；
`1` / 负值 / 未知正值，以及总开关关、诊断开、`BDNadBlockAdMethods` 关，一律精确透传。
日志名沿用 `resume-splash-gate`（现在也覆盖冷启动）。原生 not-show 分支自己设置
`isNotSplashWindow`（仅已核的 iPhone 分支）/ `decidedNotShow`（冷启动上游还会自己发 `notifyIsShowSplashWindow:0`）
并继续启动，本组件**不补 callback、不伪造通知、不碰 window / timer / timeout / 竞价**。
**范围边界**：静态已核的是当前 manager 这条路径；冷启动侧另有一条经
`serviceWithProtocol:`（`oversea_splash`）取得的动态 provider，热启动侧另见 `BDPanAdvertisementManager`；它们是否也执行这条 predicate **未证**，
本轮**不**据此扩大 hook 面。**真机是否不再出现开屏仍未验证。**

首页顶部横幅容器是**独立实验项**（`BDExperimentHideHomeBanner`，默认 **NO**，首页分组）：
它**不是** `BDRemoveHomePromo` 的开关，也不改那行的说明文案。用户自行开启（我的 → 设置 → 网盘净化，
「隐藏顶部横幅容器·实验」）后彻底退出重开才生效；回退就是关掉后冷启动，或装回旧库。
只对 `BDPanNewMSHTopOperationView` 自己的候选 `_bannerView` 定点 `setHidden:YES`（原 `setup` 先调一次），
不全局 hook `UIView`、不隐藏整个 TopOperation、不改父容器/约束/数据/网络，也不写死地址/坐标/尺寸。
**状态：已实现，机制与SDK编译通过，真机效果未验证**；候选identity未证实，可能无效或留白。
初始化完成后才尝试隐藏，并在检查时保护9个已知正常控件；守卫通过机制测试不代表已验证所有异步UI变化。

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
- **建议把 `BDNadPrefsInit()` 放在构造器早期（`BDFRInstallAll()` 之前）**，
  这样 hook 读到的就是启动那一刻用户保存的值。
  现状：`Tweak.xm` 的 `__attribute__((constructor))` 第一件事就是 `BDNadPrefsInit()`，
  随后才依次装各组件的 hook 与网络层。
- 旧的 `BDEnabled / BDDumpOnly / BDRemoveRecommend / BDRemoveGameCenter` 等已改成
  `BDNadPrefsActive(...)` 的薄封装（仍定义在 `Tweak.xm`），各组件 header 只调这些同名
  静态函数，不再自己读 defaults、不另建默认值表。

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
  （iPad 已设 `sourceView`/`sourceRect`）。本组件**不自动上传**，目的地由用户在系统分享面板里选；
  **不复制整份日志、不删除源文件**。
- 菜单自身文案已含：“保存后请彻底退出后台并重开百度网盘生效，不会自动退出；当前页面不热更新。”
  有待生效改动时 footer 前会加“有改动待生效。”。

菜单自身的按钮在 `MenuEntry.h`：给两个候选设置页（`SettingConfigViewController` /
`SettingViewController`，各一条 `-viewDidLoad` post-hook）**追加**「网盘净化」到
`navigationItem.rightBarButtonItems` 末尾，两类各自独立校验。点击时：

```objc
NSURL *log = [NSURL fileURLWithPath:BDResolveLogPath()];   // Tweak.xm 里已有该函数
BDPresentPurificationSettings(self.host, log);              // host 是 weak，不给宿主加 selector
```

**真机上哪一页会出现这个按钮未验证。** `menu-open-request` 日志只表示“请求过打开”，
present 之前还有主线程/modal 守卫，守卫拒绝时菜单不会出现。

## 5. 不做的事（设计要求，别在接线时加回来）

- 不写 `BHSettings` 原生开关、不删 unknown 键、不修改账号/缓存/原生偏好。
  唯一写入面就是 App 的 `NSUserDefaults` 里本组件规格表内的固定键。
- 不 `synchronize`、不直接改 plist 文件、不新增配置服务类/依赖。
- 不热更新（改完不 reload 网盘的列表/导航）、不自动杀 App、不加延时/锁/重试。
- 不新增日志系统、不复制整份日志、不自动上传（分享目的地由用户自己选）、不收集账号信息。
- 不为了隐藏某一项而删掉正常功能入口（容量卡 / 最近 / 相册 / 备份 / 金刚区其它条目 /
  整卡既有会员点击等一律保留）。

## 6. 验证状态

- **已接线**：菜单组件与 `Tweak.xm` / `MenuEntry.h` / CI 都已接上（`BDNadPrefsInit()` 在构造器
  最前，随后装各组件 hook，`BDMEInstallAll()` 装入口按钮）。CI 里已包含本组件那一步：
  ```
  clang++ -std=c++17 -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -framework Foundation -o "$RUNNER_TEMP/preferences_test" tests/preferences_test.mm
  "$RUNNER_TEMP/preferences_test"
  ```
  以及 `tests/ui_compile.mm` 的 iOS SDK `-fsyntax-only` 编译（覆盖 UIKit 声明）。
  跑法与最新结果见 README「怎么复核」。
- **CI 通过 ≠ 真机生效**：办卡修复历史基线是 `main` 的 `664a722`（CI run `38891349121`）：
  10 组 Foundation 机制测试 + UIKit strict syntax + arm64/arm64e 双架构构建全部通过，
  验证分支**没有可下载 artifact**，等 `main` 成功才发布。免流办卡 gate 的提交 `1e869d5` 已通过
  [CI 38890609380](https://github.com/fucknima/BDNadBlock/actions/runs/38890609380) 的10组机制测试、
  UIKit严格编译及双架构构建；**办卡条真机效果仍未验证**。
  首页横幅容器实验提交 `d080dad` 的[CI 38905984074](https://github.com/fucknima/BDNadBlock/actions/runs/38905984074)
  已通过11组host机制测试、真实UIKit严格编译及双架构构建，真机效果仍未验证 ——
  本轮开屏闸门扩到 0/2/3 的代码提交 `3989739` 已通过
  [CI 38916406687](https://github.com/fucknima/BDNadBlock/actions/runs/38916406687)：11 组机制测试（含开屏96组组合）、
  真实 UIKit 严格编译及双架构构建；验证分支没有下载产物。以上都只是**编译与机制**层面的证据。
- **真机 UI 仍未验证**：菜单是否出现在真实设置页、开关是否可切、分享面板、
  冷启动后是否真的生效，都要装包后人工确认。
- **持久化未跨进程验证**：host 测试里“新 defaults 实例读到已保存值”只是**同进程 suite
  可见性**，不等于已验证真实进程重启后的落盘恢复；`BDNadPrefsGlobalSnapshot`
  的“建一次就不再变”也只能在真机（或模拟器）上确认。
