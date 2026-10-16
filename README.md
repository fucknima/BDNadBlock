# BDNadBlock

百度网盘 (com.baidu.netdisk) **13.32.2** 的净化 tweak：一个设置菜单 + **17 个保留配置键**
（16 个可切换项 + 1 个「年卡待定位」的说明行）。菜单之下挂两层广告拦截
（网络规则 / 展示方法）和若干「原生组装或纯显示谓词」处的精准 hook。

**实验版本。** 编译通过、selector 存在、hook 装上，都**不等于**真机生效。日志里两条也不同：
`installed` = 替换实现装上了，`hit` = 本组件的抑制分支执行过一次；**两者都不是页面效果验证**。
本项目**不保证所有相关请求都停止**：仅隐藏视图的规则下数据请求可能照旧发生；
原生 gate（如游戏中心开关）可能在创建/请求之前就阻断；网络 matcher 命中的请求本来就不发出。
根因与抓包证据见 [docs/capture-387.md](docs/capture-387.md)，菜单接线契约见 [docs/menu-contract.md](docs/menu-contract.md)。

前提：iOS 15（`Makefile` TARGET 15.0），`ARCHS = arm64 arm64e`。

## 设置入口

「我的 → 设置」页右上角追加一个 **「网盘净化」** 按钮，点开是 `UITableViewStyleInsetGrouped`
的菜单页。实现方式是给两个候选设置页各自的 `-viewDidLoad` 装 post-hook
（`SettingConfigViewController` / `SettingViewController`），先调原实现，再把按钮
**追加**到 `navigationItem.rightBarButtonItems` 末尾（保留原按钮与顺序）。
两个类各自独立校验，一个不过只 skip 它自己。
**真机上到底哪一页会出现这个按钮未验证。** 入口按钮不受总开关/诊断开关影响（关掉净化也仍能进菜单）。
按钮只在 `-viewDidLoad` 追加一次，之后不再补挂：若原生之后重建或重置这条导航栏，入口可能就不在了
（未验证，也不加定时器去补）。

## 开关

**唯一默认值表在 `Preferences.h`**（17 个保留配置键），菜单标题/分组也从那张表取，代码里不再抄第二份。
只写本组件这 17 个键到 `NSUserDefaults`，不写账号、缓存或原生偏好。

**保存后必须彻底退出 App 再冷启动才生效**：运行期所有 hook 读的是**进程启动快照**，
菜单改值不改当前进程、不热改 UIKit、不自动退出、不清网盘数据。

| key | 菜单标题 | 默认 | 状态 |
|---|---|---|---|
| `BDNadBlockEnabled` | 启用网盘净化 | YES | 总开关 |
| `BDRemoveRecommend` | 隐藏推荐/创意区域 | YES | 已实现 |
| `BDRemoveHomePromo` | 隐藏首页年卡促销 | YES（仅保留配置） | **未实施**，菜单显示「待定位，本版本暂时保留」 |
| `BDRemoveAITab` | 隐藏底部库库AI | YES | 已实现（索引换算需真机验证） |
| `BDRemoveJobNovel` | 隐藏求职/小说入口 | YES | 已实现 |
| `BDRemoveSearchPromo` | 隐藏搜索推广词 | YES | 已实现 |
| `BDRemoveSearchAI` | 隐藏搜索框AI按钮 | YES | 已实现 |
| `BDRemoveGameCenter` | 隐藏游戏中心 | YES | 已实现 |
| `BDRemovePersonalPromotions` | 隐藏推广入口整排 | YES | 已接线（基线 CI 通过） |
| `BDRemovePersonalBanner` | 隐藏活动轮播 | YES | 已实现 |
| `BDRemoveTaskCard` | 隐藏任务系统卡片 | YES | 已接线（基线 CI 通过） |
| `BDRemoveRenewButton` | 隐藏续费按钮 | **NO** | 已实现 |
| `BDNadBlockNetwork` | 广告网络拦截·旧规则 | YES | 实验 |
| `BDNadBlockAdMethods` | 广告展示拦截·实验 | YES | 实验 |
| `BDRemoveTransferYikePromo` | 隐藏传输页一刻相册 | YES | 已接线（传输页推广） |
| `BDRemoveTransferGamePromo` | 隐藏下载小游戏引导 | YES | 已接线（传输页推广） |
| `BDNadBlockDumpOnly` | 仅诊断，不执行净化 | **NO** | 诊断 |

开关 **ON = 去除/拦截**。所有去除类开关的前置条件都是
`BDNadBlockEnabled && !BDNadBlockDumpOnly`。总门不通过时，网络层整层不进进程
（不换 `NSURLSessionConfiguration` 工厂、不注册 `NSURLProtocol`）。

## 净化功能表

每项都只动「原生组装 / 纯显示谓词 / 数据写入口」，不改账号与缓存，不拦整条接口。

| 开关 | 落点（类 / selector） | 保留什么 / 注意 |
|---|---|---|
| 推荐/创意 | `+[BHSettings isMSHSwitchTypeHomeRecommend]` → NO **成对** `-[BDPanNewMSHContentViewController tableView:numberOfRowsInSection:]` → 0 | 关推荐后 tab 头会被换成「开启推荐」条，第二条把它也去掉，所以创意社区在本容器内的入口一并消失；**本容器之外是否还有独立入口未验证** |
| 求职/小说 | `+[BDPanFeedHomeConfig cacheKingKongsConfigArray]` → 只从**最终模型数组**里去掉 `kingKongId` 13（求职）/ 6（小说） | 其余元素保序、同对象原样透传，**不拦 `/feed/kingkongdistrict` 这个接口**；相册/视频/扫描/备份/容量/最近等**全部保留** |
| 搜索推广词 | 数据层 `-[BDPanSearchManager setStaticWordList:]`（`_staticWordList` 唯一写入口）传空数组；UI 层 `BDPanNewMSHSearchView` 三条 post-hook（`setupView` / `searchPlaceholderUpdated:` / `updateConstraintsWithProgress:`）走原实现的清空路径，并用 `SearchPlaceholder` 本地化 key 恢复普通占位文案 | **全部轮播词都去掉**（用户选定），不做分类/文本匹配；不清用户输入、不动搜索历史、不碰轮播词落盘 |
| 搜索框 AI | 隐藏 `genflowButton` / `genflowAnimationView` / `cameraButton` / `cameraButtonAnimateBackground` 四个真实视图，并把 `searchButton.contentEdgeInsets` 收回 `(0, 8, 0, 12)` | 不改任何约束/frame，无延时重试；留白视觉效果待真机确认 |
| 底部 AI tab | `-[BDPanTabBarController setTabBarItemModels:]` 过滤**只有 `itemTabName == @"shenji_page"`** 的那条 + `customTabBar` 上下文 + 四个索引 getter 换算（`friendsIndex`/`magicTrickIndex`/`findSourceIndex`/`settingIndex`） | 六条 hook + 两个只读依赖全部校验通过才整组 attach；数组会被滤空时整次不滤。**可见模型过滤并同步索引，需真机测试登录 / 退出 / 企业空间切换** |
| 我的·游戏中心 | `+[BDPanPersonalConfig gameCenterSwitch]` → NO | 组装闸门：只阻止新建区块，不负责删除已显示区块 |
| 我的·活动轮播 | `+[BDPanPersonalConfig bannerSwitch]` → NO | 该开关为 NO 时原生就不建整个 banner section |
| 我的·推广整排 | `-[BDPanPersonalWalletSection heightForView]` → `-6.0`；`-[BDPanPersonalCenterWalletSection heightForView]` → `-3.0`（各 class 自己的原生收起值） | 只影响读这两个 `heightForView` 的路径；不清数据、不拦接口，该区域请求是否仍发生未验证 |
| 我的·任务卡 | `-[BDPanPersonalSpaceSection layoutViews]` / `-[BDPanPersonalSpaceAndPointSection layoutViews]` post-hook → 隐藏各自 `pointsCard` | 先布局后隐藏；**容量卡与行高常量（80.0 / 96.0）一点没碰**，任务卡位置允许留空 |
| 我的·续费按钮 | 三处 `-vipButton` getter（`BDPanPersonNewVipCardHeaderView` / `BDPanPersonVipHeaderView` / `BDPanPersonAdvanceVIPHeaderView`）各自独立隐藏按钮 | **默认 NO**；只藏按钮，**整卡既有会员点击行为保留**；三条互不依赖 |
| 传输页·一刻相册推广 | 两条 `-canShowYikeBanner`（`-[BDPanTransViewController …]` 与 `-[BDPanTransferFileTransListViewController …]`，各自 `B16@0:8`、类自有实例方法）**先调原实现取原 bool**，仅「原 true 且总开关开、非诊断、`BDRemoveTransferYikePromo` 开」时改判 false | 第一条宿主已证：gate 为 NO 时走原生行高入口的共同返回（**行高 0、无空行**），与「用户手动关闭」同一条布局；**不改索引/高度/section**。第二条 Yike 的运行期展示影响**尚未验证**，保留它只为「原方法先调一次 + 精确透传」 |
| 传输页·下载小游戏引导 | `-[BDPanTransIdleGameManager canTransIdleGameWidgetShow]`（`B16@0:8`）同样先调原实现，仅在开关生效且原为 true 时改判 false | 原生消费点本就有「gate 为 NO → 直接返回、不存 block、不建 widget」的分支；**不改 AB gate、任务、速度、暂停、并发** |
| 热启动空白开屏 | `-[BDNCUIAdvertisesManage needToShowSplashWithLaunchType:launchUrl:launchOptions:]`（`B40@0:8q16@24@32`，自有实例方法）先调原实现取原 bool，仅当 `launchType` 是 2 或 3 且原结果为真时改判为假 | 受 `BDNadBlockAdMethods` 控制（总开关开且非诊断）。**原策略、状态消费与埋点全部照跑**，只改返回值；`launchType` 0/1/负值/未知正值与冷启动一律不变；**不碰 window / timer / 系统前台恢复 / 时长 / 竞价**。详见下文 |

各组件都复用 `FeatureRemoval.h` 的同一套安装原语（`BDFRSpec` / `BDFRResolve` /
`BDFRCanAttach` / `BDFRAttach` / `BDFRInstallSpec` / `BDFRSuppressed`），不另抄一份。
传输页这两个开关**不依赖** `BDNadBlockAdMethods`（那条只管旧 18 个广告 selector 与热启动开屏）：
生效条件是总开关开、非诊断、且各自开关开，改完**下次冷启动**才生效。
本包**未移除**：传输页底部办卡推广条（native 归属仍在定位，本包不提供该开关）、
企业版传输页的 Yike 消费者；文件 / AI 推荐等正常功能一律保留。
首页年卡促销（`BDRemoveHomePromo`）**本版未实施**：静态定位未收束，用户选择先做其它项；
菜单里那一行只有说明文案、没有开关，也不读写它的 saved 值，避免显示成「默认 YES 已生效」。
规格表里那个默认 YES 只是**保留配置**，启动日志里的 `active BDRemoveHomePromo = 1`
同样只是快照值，**不是该功能已接线的证据**。

## 网络层（`BDNadBlockNetwork`，实验）

注册 `BDNadProtocol`（`NSURLProtocol` 子类）并挂到 `defaultSessionConfiguration` /
`ephemeralSessionConfiguration` 两个工厂上，命中即本地返回 `200 {}`，不出网。
规则与 matcher 全在 `NetworkRules.h`（同一份实现也被 host 测试 include）。

| 判据 | 目标 |
|---|---|
| 整个 host（**精确相等**，不是通配子域） | 趣盟 SDK 逐个列出的 host（`show-api.yunxish.com` / `logrcv.yunxish.com` / `cpc-service-square.yunxish.com` 等，另加 `cpc-service-square.iggrowth.cn`）、百度广告开关与点击归因（`afdconf.baidu.com` / `nsclick.baidu.com` / `sofire.baidu.com` / `huiduapi.nuomi.com`）、三方联盟（`ef-dongfeng.tanx.com` / `tnc3-alisc1.zijieapi.com` / `mssdk.volces.com`）、当贝酷开（`conf` / `vfa` / `ssdkauth` / `logu` 四个 `.hpplay.cn`） |
| host + 路径前缀 | `pan.baidu.com/buy/ad/`（首页 banner 广告）、`pan.baidu.com/rest/2.0/pcs/adv`（激励任务广告） |
| host + 路径前缀（游戏接口） | `pan.baidu.com` 且路径以 `/act/v2/gamecenter` 开头 —— 受 `BDRemoveGameCenter` 控制 |
| 任意 host，路径**包含**（不是前缀） | 路径含 `/gamecenter/` 或 `_swan-game_`（游戏素材；走 P2P 镜像，host 每台设备不同，只能按路径判）—— 受 `BDRemoveGameCenter` 控制 |
| 精确路径（值或末尾多一个斜杠） | `pan.baidu.com/recommend/searchbox/bottom` —— 搜索框底部推广词，受 `BDRemoveSearchPromo` 控制，**与首页推荐分开** |
| 路径前缀 | `pan.baidu.com/aisearch/agent/memorycenter/getrecommendcards` —— 记忆中心推荐卡片，受 `BDRemoveRecommend` 控制 |

**不拦**（曾经的误判，实测是功能）：`/feed/kingkongdistrict`（金刚区是相册/视频/求职/小说/备份等真实入口）、
`/api/getsyscfg`（服务端配置下发）、`*/amis/` 静态资源域（首页天气特效包/音效/banner 图）、
`*.jomoxc.com` / `*.antpcdn.com` / `*.yingt.asia`（上面那批资源的 P2P 镜像）、
bcebos 的 `cmpkg` 整目录（里面还有 `1_swan-core` 小程序运行时）。

**覆盖范围有限，原因未确定。** 有据可查的一点来自 [docs/capture-387.md](docs/capture-387.md)：
那批抓包里，**旧版游戏中心匹配规则下的请求仍然收到了非空的服务端响应**
（例如 `/act/v2/gamecenter/recommend`）；推荐接口 `/feed/cardinfos` 是旧规则**未覆盖**的，不算漏拦。
抓包没有调用栈，所以**协议族、调用栈、启动时序这些具体原因都未确定**，不写成结论。
已确知的只有一条：**本层只改 `NSURLSessionConfiguration` 工厂，已经创建好的 session 不会被改写**。
因此本层是实验项，不宣称「全部拦到」。

## 展示方法层（`BDNadBlockAdMethods`，实验）

18 个 selector / 11 个类（开屏、激励视频、原生信息流、TopOn 聚合层），
只 hook「把广告显示出来」这一步，**不碰 bidding / task / timeout 管理器**
（`BDNCSplashBiddingTaskManager` 持有开屏超时计时器，动它可能让开屏卡死）。
返回类型已核对为 11 个 `v` / 7 个 `B`；**这一层**的通用 no-op 只保证 `x0` 有效，
所以返回结构体/浮点/复数的方法在这一层一律跳过。**超时与回调行为真机未验证。**
与网络层是两个独立开关，可单独关掉定位是哪一层。

## 热启动空白开屏修复（受 `BDNadBlockAdMethods` 控制）

症状：从后台放一段时间回到前台，广告素材已经没有了，但**空白开屏仍然出现几秒才消失**。
本项让原生自己在「该不该展示」那一步判定为「不展示」，于是原生走它自带的收尾路径，不进入建窗。

- 落点：`-[BDNCUIAdvertisesManage needToShowSplashWithLaunchType:launchUrl:launchOptions:]`
  （`B40@0:8q16@24@32`，自有实例方法，argc 5）。
- 生效条件：总开关开 **且** 非诊断 **且** `BDNadBlockAdMethods` 开（沿用现有开关，未新增设置键）。
- 顺序：**先调一次原实现**拿到原 bool，原方法对内部状态的消费、策略检查与埋点全部照跑；
  只有当 `launchType` 是 **2 或 3**（热启动）且原结果为真时，才把返回值改成假并记一次 hit 日志。
- 不改动：`launchType` 0（冷启动）/ 1 / 负值 / 未知正值，以及任一开关关闭、原结果本来就为假 —— 一律精确透传原 bool。
- 不碰：窗口的创建或关闭、任何定时器与超时、时长统计、竞价任务、系统前台恢复链路，也不读也不写被 hook 类的私有状态。
- 闸门位置在建窗之前：原生的 not-show 分支自己会 `setIsNotSplashWindow` / `setDecidedNotShow` 并返回 NO，
  不进入 `dynamicAdvertiseTaskWithLaunchType:`，本组件不补任何收尾。

**该提交（`e91f4e6`）的 9 组 Foundation 机制测试（含本项）、UIKit strict syntax 编译与
arm64 / arm64e 双架构构建均已通过：
<https://github.com/fucknima/BDNadBlock/actions/runs/38863989849>；
真机上「空白开屏是否消失」仍未验证。**
机制测试只覆盖开关组合、参数透传、原实现调用次数与安装失败路径，不代表设备上的空白开屏已不再出现。

## 怎么复核

```bash
# 二进制核对：广告 selector + feature hook + 只读依赖（类自有方法表 + encoding 逐字节一致）
python3 scripts/verify_selectors.py --selftest          # 解析器自检
python3 scripts/verify_selectors.py /path/to/Payload/netdisk_iPhone.app/netdisk_iPhone
# 末行汇总形如：N 个广告 selector + M 个 feature hook + K 个依赖，X 个有问题

# macOS host 机制测试（不启 UIKit、不装 hook 到真 App）；set -e 保证任一失败即非 0
set -e
for t in tests/*_test.mm; do
  bin="/tmp/$(basename "$t" .mm)"
  clang++ -std=c++17 -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -framework Foundation -o "$bin" "$t"
  "$bin"
done

# tests/ui_compile.mm 不在上面那串里：它需要 iOS SDK，不由 Foundation 循环编译。
# 本机 macOS 装了 Xcode（iOS 15+ 目标）也能照 workflow 跑，只是不产出/不运行 app：
#   sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
#   xcrun --sdk iphoneos clang++ -std=c++17 -fobjc-arc -fblocks -Wall -Wextra -Werror \
#     -target arm64-apple-ios15.0 -isysroot "$sdk" -I . -x objective-c++ -fsyntax-only tests/ui_compile.mm
```

App 升级后必须重跑 `verify_selectors.py`：selector 失效会直接报出来。

**CI**：`gh workflow run Build --ref <branch>`（或 Actions 页手动 dispatch）。它跑上面那些
host 测试、UIKit `-fsyntax-only` 编译、再用 Theos 出 dylib；只有 `main` 分支产出可下载 artifact。
传输页这两项（一刻相册 + 下载小游戏引导）的功能代码**已接线**；**收尾提交 `90ff662` 的
10 组 Foundation 机制测试（含传输页真值表矩阵）、UIKit strict syntax 与 arm64 / arm64e 双架构构建已通过**：
<https://github.com/fucknima/BDNadBlock/actions/runs/38888485278>。
该提交已移除未接线的办卡键；验证分支**没有可下载 artifact**，
等 `main` 成功才发布。这些都只是**编译与机制**层面的证据：**真机效果未验，编译与机制测试都不等于真机生效。**

## 防崩

1. **不交换 IMP**。用 `method_setImplementation` + 保存原 IMP 直调。
   上一版用 `method_exchangeImplementations` 方向写反 → 无限递归 → `depth 12353`
   打穿 Stack Guard 闪退。**这是已确认的历史崩溃根因**；它与日志目录解析无关。
2. **返回类型闸门（只针对旧广告通用 no-op 安装器）**：那种 no-op 只保证 `x0` 有效，
   返回结构体/浮点/复数的方法在这一层一律不碰。各精准组件用的是已核验的 typed 替换实现
   （例如推广整排是 `double (*)(id, SEL)`），不受这条限制。
3. **跳过生命周期方法（同上，只针对旧 no-op 层）**：`init` / `dealloc` / `copy` / `load` /
   setter 等。精准组件会 hook 已核验过的 setter / getter（搜索词数据层、底部 tab 可见数组写入口），
   不按这条跳过。
4. **IMP 复用**：旧广告 no-op 层把 `imp_implementationWithBlock` 的结果缓存进一个
   `BDNoopIMP` 全局复用，第一次创建之后不再为每个方法重复生成 trampoline。
5. **按类下刀**：hook 表是「类 → selector」，不会把同名方法误伤到别的类。
6. 保留网络层的 1.5 秒延迟：它不代表 app ready，也改不到**已经创建好的 session**；保留只是因为没有证据说它有害。

## 日志

同时写 syslog 与沙盒 `Documents/BDNadBlock-dump.txt`（缓冲区从进程启动就在累积）。

```bash
find /var/mobile/Containers/Data/Application -name BDNadBlock-dump.txt
log stream --predicate 'eventMessage CONTAINS "BDNadBlock"'
```

关键行（`installed` / `hit` 是两回事，`installed` 不代表功能生效）：

```
[BDNadBlock] loaded (purification-menu: ...)；active snapshot ...
[BDNadBlock] active <key> = 0|1                     每个键的本进程启动快照
[BDNadBlock] network layer on (hosts=.. paths=.. anypath=..)   或   network layer NOT installed (...)
[BDNadFeature] installed <token>: -[Class sel] enc=...          装上了
[BDNadFeature] hit <token>（首次真正抑制）                        真的抑制过一次（每 token 只一行）
[BDNadFeature] skip <token>: ...                                 校验没过，什么都没装
[BDNadSearch] / [BDNadTab] / [BDNadMenuEntry] skip ...           对应组件的跳过原因
[BDNadBlock] blocked[tag] host/path                              网络层命中
[BDNadMenuEntry] menu-open-request: 首次请求打开净化菜单          只表示「请求过打开」，不等于菜单已展示
```

菜单「诊断」分组里可**分享诊断日志**：本组件**不自动上传**，目的地由用户在系统分享面板里选；
不复制整份日志、不删除源文件。iPad 已设 popover 锚点；文件不存在或不可读时弹窗明确提示。

## 已知限制

1. **一切都要真机确认**：菜单入口可达性、每个开关对应的页面效果、留白/空位、网络层真实拦截率。
2. **不保证所有相关请求都停止**：仅隐藏视图的规则下请求可能照旧发生；原生 gate 可能在
   创建/请求之前就阻断；网络 matcher 命中的请求本来就不发出。哪种情况适用要看具体规则。
3. 首页年卡促销（`BDRemoveHomePromo`）**本版未实施**，菜单里是说明行；
   规格表里的默认 YES 只是保留配置，日志里的快照值也不是接线证据。
4. 推荐/创意的 hook 只保证「渲染 + 组装 + 已有解析/分页路径」；共享 manager 的冷启动预取、
   socket / VoIP / remotePush 入口没有被证明被挡住。游戏中心那条是组装闸门。
5. 任务卡隐藏后**容量区域与 section 原行高都保留**（80.0 / 96.0 未动），只是任务卡原占位可能留白；
   真机布局未验证。
6. 底部 tab 的索引换算**需真机测试登录 / 退出 / 企业空间切换**等根视图切换场景。
7. 网络层覆盖有限（抓包仍有未覆盖请求）；除「不改已创建 session」外，具体原因未确定。
8. 展示方法层的超时与回调行为未验证。
9. `h2tcbox.baidu.com/ztbox`（抓包 35 次/30s）没抓到响应体，定性不了，暂不处理；它属于未知流量，不是「广告请求未覆盖」。
