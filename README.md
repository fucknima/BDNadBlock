# BDNadBlock

百度网盘 (com.baidu.netdisk) **13.35.5**（build `13.35.5.6`）的净化 tweak：
一个设置菜单 + **21 个配置键、21 个可切换项**，不再显示重复的「年卡待定位」说明行。
菜单之下挂两层广告拦截（网络规则 / 展示方法）和若干「原生组装或纯显示谓词」处的精准 hook。
**13.32.2 的既有净化功能保留**，升级边界见下文；删除的是没有实现逻辑的重复说明行，不是顶部横幅功能。

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
**用户已提供可进入菜单的真机截图**；其它系统与设置页变体未独立验证。入口按钮不受总开关/诊断开关影响（关掉净化也仍能进菜单）。
按钮只在 `-viewDidLoad` 追加一次，之后不再补挂：若原生之后重建或重置这条导航栏，入口可能就不在了
（未验证，也不加定时器去补）。

菜单最底部“关于”包含“免责声明”和“Telegram 交流群”（https://t.me/fuckAd1024）。
首次进入净化设置时展示本版免责声明，点“我已阅读并知悉”后记录阅读版本；再次进入不重复，正文版本变化后重新提示，“关于”仍可随时查看。
弹窗标题统一为“使用须知”，去掉正文中重复的“免责声明：”；五段声明保持原文。此为展示调整，阅读版本仍为 `2026-10-18-v3`，已确认v3的用户不会因此再次被要求确认。
阅读记录只是风险提示的本地状态，不是有效免责、平台授权或停用既有hook的保证；正式分发建议由执业律师审阅。
群组仅在点击后交给系统打开，不强制加群。每次请求临时观察当前场景失活，已离开前台的请求不在返回后补失败框；确实未交接且仍在前台的失败可手动复制链接。

## 开关

**唯一默认值表在 `Preferences.h`**（21 个配置键），菜单标题/分组也从那张表取，代码里不再抄第二份。
**所有21个开关默认关闭（NO）**，包括总开关、各项净化、网络/广告展示拦截、实验与诊断。仅对未保存值或错误类型的默认回退生效；已有明确保存的YES/NO保留，不做迁移、清理或强制关闭。
要启用净化，请自行打开总开关及需要的具体功能，再彻底退出重开；默认关闭不妨碍进入设置和查看使用须知。
偏好接口只写本组件这21个开关键；另有独立元数据 `BDNadBlockDisclaimerAcknowledgedVersion` 记录用户确认阅读的正文版本，不进入开关表或启动快照，不修改账号、缓存或原生偏好。

**保存后必须彻底退出 App 再冷启动才生效**：运行期所有 hook 读的是**进程启动快照**，
菜单改值不改当前进程、不热改 UIKit、不自动退出、不清网盘数据。

| key | 菜单标题 | 默认 | 状态 |
|---|---|---|---|
| `BDNadBlockEnabled` | 启用网盘净化 | NO | 总开关 |
| `BDRemoveRecommend` | 隐藏推荐/创意区域 | NO | 已实现 |
| `BDRemoveAITab` | 隐藏底部库库AI | NO | 已实现（索引换算需真机验证） |
| `BDRemoveJobNovel` | 隐藏求职/小说入口 | NO | 已实现 |
| `BDRemoveSearchPromo` | 隐藏搜索推广词 | NO | 已实现 |
| `BDRemoveSearchAI` | 隐藏搜索框AI按钮 | NO | 已实现 |
| `BDExperimentHideHomeBanner` | 隐藏顶部横幅容器·实验 | **NO** | 用户已反馈开启后年卡促销消失；仍保留实验开关和旧保存值 |
| `BDRemoveGameCenter` | 隐藏游戏中心 | NO | 已实现 |
| `BDRemovePersonalPromotions` | 隐藏推广入口整排 | NO | 已接线（基线 CI 通过） |
| `BDRemovePersonalBanner` | 隐藏活动轮播 | NO | 已实现 |
| `BDRemoveTaskCard` | 隐藏任务系统卡片 | NO | 已接线（基线 CI 通过） |
| `BDRemovePersonalSpaceCard` | 隐藏容量管理卡片 | NO | 用户指定的已用容量/百分比/管理空间小卡，独立开关 |
| `BDRemoveRenewButton` | 隐藏续费按钮 | **NO** | 已实现 |
| `BDNadBlockNetwork` | 广告网络拦截·旧规则 | NO | 实验 |
| `BDNadBlockAdMethods` | 广告展示拦截·实验 | NO | 实验 |
| `BDRemoveTransferYikePromo` | 隐藏传输页一刻相册 | NO | 已接线（传输页推广） |
| `BDRemoveTransferGamePromo` | 隐藏下载小游戏引导 | NO | 已接线（传输页推广） |
| `BDRemoveTransferCardPromo` | 隐藏免流办卡推广 | NO | 已接线（免流办卡 widget gate） |
| `BDRemoveTransferDataPromo` | 隐藏流量包付费引导 | NO | 独立开关，不禁用已购买流量 |
| `BDRemoveTransferTrialPromo` | 隐藏加速试用促销 | NO | 只过滤明确促销态，保留进行中与未知态 |
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
| 首页顶部横幅容器·**实验** | 只对 `BDPanNewMSHTopOperationView` **自己的候选 `_bannerView`** 定点 `setHidden:YES`（原 `setup` 先调一次） | **默认关闭**；用户已反馈开启后年卡促销消失，跨设备/异步布局仍待验；不写死任何地址/坐标/尺寸，不全局 hook `UIView`，不隐藏整个 TopOperation，不改父容器/约束/数据/网络 |
| 底部 AI tab | `-[BDPanTabBarController setTabBarItemModels:]` 过滤**只有 `itemTabName == @"shenji_page"`** 的那条 + `customTabBar` 上下文 + 四个索引 getter 换算（`friendsIndex`/`magicTrickIndex`/`findSourceIndex`/`settingIndex`） | 六条 hook + 两个只读依赖全部校验通过才整组 attach；数组会被滤空时整次不滤。**可见模型过滤并同步索引，需真机测试登录 / 退出 / 企业空间切换** |
| 我的·游戏中心 | `+[BDPanPersonalConfig gameCenterSwitch]` → NO | 组装闸门：只阻止新建区块，不负责删除已显示区块 |
| 我的·活动轮播 | `+[BDPanPersonalConfig bannerSwitch]` → NO | 该开关为 NO 时原生就不建整个 banner section |
| 我的·推广整排 | `-[BDPanPersonalWalletSection heightForView]` → `-6.0`；`-[BDPanPersonalCenterWalletSection heightForView]` → `-3.0`（各 class 自己的原生收起值） | 只影响读这两个 `heightForView` 的路径；不清数据、不拦接口，该区域请求是否仍发生未验证 |
| 我的·运营位 | `-[BDPanOperationSpaceSection heightForView]`（`d16@0:8`）先调原实现一次，再按 `BDRemovePersonalPromotions` 改为 `-6.0` | 同时隐藏该段活动卡与广告/贷款卡。两版已核宿主固定加 `6.0` 合成零行高，**不是本类原生收起分支**；动态/跨镜像调用未穷尽，真机布局未验，不改其它 section |
| 我的·任务/容量小卡 | 复用两种 `SpaceSection` 的 `layoutViews` post-hook，任务开关隐藏 `pointsCard`，容量开关隐藏 `spaceCard` | 原布局先调一次，两依赖独立校验；仅一张隐藏时保留原高度。两张都隐藏、依赖与布局已接线且主线程时，已核原高度80/84改为0，保留宿主6pt段间距；未知高度/后台原值透传。不改上方SVIP权益卡、真实配额或正常容量功能 |
| 我的·续费按钮 | 三处 `-vipButton` getter（`BDPanPersonNewVipCardHeaderView` / `BDPanPersonVipHeaderView` / `BDPanPersonAdvanceVIPHeaderView`）各自独立隐藏按钮 | **默认 NO**；只藏按钮，**整卡既有会员点击行为保留**；三条互不依赖 |
| 传输页·一刻相册推广 | 两条 `-canShowYikeBanner`（`-[BDPanTransViewController …]` 与 `-[BDPanTransferFileTransListViewController …]`，各自 `B16@0:8`、类自有实例方法）**先调原实现取原 bool**，仅「原 true 且总开关开、非诊断、`BDRemoveTransferYikePromo` 开」时改判 false | 第一条宿主已证：gate 为 NO 时走原生行高入口的共同返回（**行高 0、无空行**），与「用户手动关闭」同一条布局；**不改索引/高度/section**。第二条 Yike 的运行期展示影响**尚未验证**，保留它只为「原方法先调一次 + 精确透传」 |
| 传输页·下载小游戏引导 | `-[BDPanTransIdleGameManager canTransIdleGameWidgetShow]`（`B16@0:8`）同样先调原实现，仅在开关生效且原为 true 时改判 false | 原生消费点本就有「gate 为 NO → 直接返回、不存 block、不建 widget」的分支；**不改 AB gate、任务、速度、暂停、并发** |
| 免流办卡推广 | `-[BDPanFreeWidgetManage chechFreeUnicomWidget]`（`Q16@0:8`，方法名拼写以产品为准）**先调原实现一次**，仅在开关生效且原结果为 **3** 时改判为 **0** | `0/1/2` 与其它 unsigned 值原样透传，保留已生效免流与激活提示。原生仍继续判断其它 widget；本轮新增流量包/试用促销独立开关，**不代表底部全空**，不改备份/容量等正常提醒，真机效果待验 |
| 流量包付费引导 | `-[BDPanTransWidgetController showDataPkgWigdet]`（`B16@0:8`）原实现先调一次，仅按独立开关否决原 true | 原生 false 分支自行判断可用流量及后续 widget；不修改已购买流量、查询/付款、下载任务与速度。共享 controller 也被备份详情等宿主使用，不能宣称仅影响传输页 |
| 加速试用促销 | `-[BDNCSpeedUpTrialManager getSpeedUpTrialWidget]`（`@16@0:8`）先取原对象；只对已校验的精确 `BDNCSpeedUpTrialView`，在主线程且 `isProductGuideView` 真、`isInUseView` 假时返回原生合法值 nil | 原生宿主自行走无内容收尾。不更改状态枚举/计时器/加速权益；进行中、未知类型/子类/状态、非主线程一律原对象透传。分类只针对取视图当时，后续异步变更可能漏过；共用 manager 的企业侧同款促销亦在范围内 |
| 冷启动＋热启动开屏闸门 | `-[BDNCUIAdvertisesManage needToShowSplashWithLaunchType:launchUrl:launchOptions:]`（`B40@0:8q16@24@32`，自有实例方法，argc 5）**先调原实现取原 bool**，仅当 `launchType` 是 **0（冷启动）或 2 / 3（热启动）** 且原结果为真时改判为假 | 受 `BDNadBlockAdMethods` 控制（总开关开且非诊断）。**原策略、状态消费与埋点全部照跑**，只改返回值；`launchType` 1 / 负值 / 未知正值仍精确透传；**不碰 window / timer / 系统前台恢复 / 时长 / 竞价**。详见下文 |
| App Open 冷热策略 | `-[BDPanAdvertisementStrategy isEnableShowAdForAppColdOpenWithLaunchoptions:]`（`B24@0:8@16`）与 `-isEnableShowAdForAppHotOpenWithFrom:`（`B24@0:8q16`），均先调原实现一次，再按 `BDNadBlockAdMethods` 否决原 true | 不展示分支在创建广告回调对象、注册 handler 之前返回 NO，不补任何回调。热策略仅过滤已核 `from` 1/2/3/4，未知值透传；这是该方法自己的枚举，不与 BDNC 的 0/2/3 混用。不声称覆盖所有 ADX/MAX 信息流或其它 scene |

各组件都复用 `FeatureRemoval.h` 的同一套安装原语（`BDFRSpec` / `BDFRResolve` /
`BDFRCanAttach` / `BDFRAttach` / `BDFRInstallSpec` / `BDFRSuppressed`），不另抄一份。
传输页各项独立开关**不依赖** `BDNadBlockAdMethods`（后者控制旧18条广告展示与两套开屏闸门）。
生效条件是总开关开、非诊断、且各自开关开，改完**下次冷启动**才生效，不热更新。
本包已接线非企业 manager 的免流办卡 gate（`BDRemoveTransferCardPromo`）。同款 widget controller
还被备份详情页引用，因此不声称只影响传输页；备份详情页实际是否走到办卡分支尚未验证。
企业免流 manager 自有同名实现未改动，企业版 Yike 仍未处理；新增试用促销过滤则覆盖共用 manager 的企业侧同款展示。
备份/无空间试用的其它取视图实现不在该过滤范围；正常容量、备份、已激活加速及文件 / AI 推荐等功能保留。
用户在 2026-10-16 反馈：开启顶部横幅实验后，首页年卡促销已消失。因此删除重复的
「隐藏首页年卡促销·待定位」说明行及未接线的 `BDRemoveHomePromo` 规格项。
不清理设备上的旧键、不迁移或重置 `BDExperimentHideHomeBanner`，用户已保存的开启状态继续保留。

### 实验：隐藏顶部横幅容器（`BDExperimentHideHomeBanner`，默认关闭）

这一项继续保留为**独立、可回退的实验开关**，不另建第二套年卡移除实现：

- **怎么开**：网盘「我的 → 设置 → 网盘净化」里打开 **「隐藏顶部横幅容器·实验」**，
  然后**彻底退出后台再重开**网盘（运行期只读进程启动快照，不热改本进程）。
- **怎么回退**：把开关关掉后冷启动即可；或者直接装回上一版库（本组件不自动杀 App、不做热恢复）。
- **范围**：只对 `BDPanNewMSHTopOperationView` 自己的**候选 `_bannerView`** 定点 `setHidden:YES`，
  原 `setup` 先调一次；**不是**全局 `UIView` hook，也**不隐藏整个 TopOperation**，
  不动父容器 / 约束 / 数据 / 网络。
- **状态：已实现并通过机制测试与 SDK 编译，用户已反馈单设备年卡促销移除有效。**
  不据此宣称所有设备/内容/布局稳定性均已验证。初始化完成后才尝试隐藏；检查时若候选包含
  搜索框 / 上传加号 / 传输 / 签到 / 状态动画等9个已知正常控件，就保留。
  这些守卫已通过机制测试，但**不等于真机上任何异步加入的内容都已验证**。
- 无需再开启另一条年卡开关；旧待定位行已移除，默认值仍为 NO，原有保存值不变。

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

## 冷启动＋热启动开屏闸门（受 `BDNadBlockAdMethods` 控制）

症状：热启动时**广告素材已经没有了，但空白开屏仍然出现几秒才消失**；冷启动时**全屏开屏**（含内容）
仍会展示。本项让原生自己在「该不该展示」那一步判定为「不展示」，于是原生走它自带的收尾路径，不进入建窗。

- 落点：`-[BDNCUIAdvertisesManage needToShowSplashWithLaunchType:launchUrl:launchOptions:]`
  （`B40@0:8q16@24@32`，自有实例方法，argc 5）。
- 生效条件：总开关开 **且** 非诊断 **且** `BDNadBlockAdMethods` 开（沿用现有开关，未新增设置键）。
- 顺序：**先调一次原实现**拿到原 bool，原方法对内部状态的消费、策略检查与埋点全部照跑；
  只有当 `launchType` 是 **0（冷启动）或 2 / 3（热启动）** 且原结果为真时，才把返回值改成假并记一次 hit 日志
  （日志名沿用 `resume-splash-gate`，现在也覆盖冷启动）。
- 不改动：`launchType` **1 / 负值 / 未知正值**，以及任一开关关闭、原结果本来就为假 —— 一律精确透传原 bool。
- 不碰：窗口的创建或关闭、任何定时器与超时、时长统计、竞价任务、系统前台恢复链路，也不读也不写被 hook 类的私有状态。
- 闸门位置在建窗之前（冷、热两条都验过）：原生的 not-show 分支自己会
  `setIsNotSplashWindow`（iPhone 分支）/ `setDecidedNotShow` 并返回 NO，不进入
  `dynamicAdvertiseTaskWithLaunchType:` → `setupSplashAdvertiseWindowWithLaunchType:`；
  冷启动的上游还会自己 `notifyIsShowSplashWindow:0` / `reportSplashShouldLoad:0` 并继续走完
  `didFinishLaunching`，**本组件不补任何 callback、不伪造通知、不加延时**。

**历史基线（不要读成当时的实现已覆盖冷启动）**：本项最初只否决 `launchType` 2/3（热启动），
首次落地在提交 `e91f4e6`，其 9 组 Foundation 机制测试（含本项）、UIKit strict syntax 编译与
arm64 / arm64e 双架构构建通过：
<https://github.com/fucknima/BDNadBlock/actions/runs/38863989849>。
**那次通过的是「只覆盖热启动」的版本，冷启动覆盖是后来扩的**，不在那个 run 里。
此前扩到 0/2/3 的代码提交 `3989739` 已通过
[CI 38916406687](https://github.com/fucknima/BDNadBlock/actions/runs/38916406687)：
11 组机制测试（含开屏 96 组组合回归）、真实 UIKit 严格编译及 arm64 / arm64e 构建；验证分支未上传产物。
真机上「空白开屏 / 全屏开屏是否消失」仍未验证。
机制测试只覆盖开关组合、参数透传、原实现调用次数与安装失败路径，不代表设备上的开屏已不再出现。

## 目标版本与升级边界

- **静态适配目标是 13.35.5（build `13.35.5.6`）**；已有冷/热启动开屏修复保留，本轮删除重复年卡说明行，
  本轮继续处理新发现的推广入口。用户已明确暂停搜索页「试试这样问」，**本轮不移除该模块、不改搜索逻辑**。
- 对13.35.5与13.32.2分别跑仓库既有校验器：**18个广告 selector + 38个精准 hook + 18个依赖全部 encoding 匹配、0问题**。
  这只说明**签名元数据兼容**，**不宣称**所有旧 feature 在 13.35.5 上的实际 UI 效果都已适配或安全 ——
  页面结构、展示时机、布局都要真机看。
- 新包 `MinimumOS 18.0` 是 App 自己的 `Info.plist` 要求，**不是**本插件的要求；插件自身部署目标保持
  build 15 不变，本轮**不盲改 `Makefile`/签名**。
- 新 IPA 自身**未见** `BDNadBlock` 成员或 `LC_LOAD` 项 —— 只说明**这个包本身没有注入本组件**，
  **不能**据此推断用户手机上没装、也不能断言它没注入任何库。
- 安装新 dylib 时**必须替换旧的、不要叠加**，并确认：总开关开、广告展示拦截开、诊断关，
  然后**冷启动**一次让它生效。
- **设备日志尚未收到**，以下仍需真机校验：全屏开屏是否消失；root / 首页 / 登录 / 分享 deeplink 是否正常进入；
  热启动（warm）不回归。

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
**办卡修复历史基线**是 `main` 的 `664a722`（CI run `38891349121`）：含 10 组 Foundation 机制测试、
UIKit strict syntax 与 arm64 / arm64e 双架构构建；此前 `7e4d8e92`（run `38888673604`）
只含一刻相册 + 下载小游戏两项，免流办卡补丁在 `1e869d5` 的
[CI 38890609380](https://github.com/fucknima/BDNadBlock/actions/runs/38890609380) 中通过
10 组机制测试（含 48 组 bool 与 64 组办卡数值组合）、UIKit 严格编译及双架构构建。
首页顶部横幅容器实验的提交 `d080dad` 已通过
[CI 38905984074](https://github.com/fucknima/BDNadBlock/actions/runs/38905984074)：11组host机制测试、
真实UIKit严格编译及arm64 / arm64e双架构构建。验证分支没有可下载artifact，等 `main` 成功才发布；
**该实验的真机效果仍未验证**。
**顶部实验历史发布基线**是 `main` 的 `b6a2c42`（CI run `38906342452`）：11 组 host 机制测试、
真实 UIKit 严格编译与 arm64 / arm64e 双架构构建全部通过。
**开屏闸门扩到 0/2/3** 的代码提交 `3989739` 的验证 CI `38916406687` 已通过；
已合入 `main 77d0621`，发布 [CI 38916663734](https://github.com/fucknima/BDNadBlock/actions/runs/38916663734) 通过。
菜单删除提交 `97481d2` 已通过 [CI 38924448154](https://github.com/fucknima/BDNadBlock/actions/runs/38924448154)。
本轮完整推广代码 `5bb57b9` 已通过 [CI 38939593185](https://github.com/fucknima/BDNadBlock/actions/runs/38939593185)：
11组机制测试（含运营位24组合、流量包16组合、试用身份/依赖/非主线程与App Open 144组合回归）、真实UIKit严格编译及arm64/arm64e构建；验证分支未上传产物，仅 `main` 发布 CI 成功后提供新下载。

容量管理小卡独立隐藏提交 `56d331c` 已通过 [CI 38996332916](https://github.com/fucknima/BDNadBlock/actions/runs/38996332916)：
11组机制测试、真实UIKit严格编译及arm64/arm64e构建全通过，包含21键、两种样式各16组双卡门控与依赖失败隔离；验证分支未上传产物。
本轮只新增容量小卡隐藏及双卡占位压缩；SVIP权益卡保留，搜索未改，启动图深色取消。真机效果、间距与稳定性仍待验证。
`BDExperimentHideHomeBanner` 仍默认关闭，既有净化项一个都没有删除。
这些都只是**编译与机制**层面的证据：**真机效果未验，编译与机制测试都不等于真机生效。**

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
3. 首页年卡促销已有用户单设备反馈移除有效；顶部横幅实验在其它设备、内容变化和异步布局下仍可能误伤或留白。
4. 推荐/创意的 hook 只保证「渲染 + 组装 + 已有解析/分页路径」；共享 manager 的冷启动预取、
   socket / VoIP / remotePush 入口没有被证明被挡住。游戏中心那条是组装闸门。
5. 容量小卡按用户单独授权隐藏，不把正常容量服务视作广告。只隐藏任务/容量其中一张时允许留空；两张都隐藏时压缩卡片高度，保留6pt段间距，真机布局未验证。
6. 底部 tab 的索引换算**需真机测试登录 / 退出 / 企业空间切换**等根视图切换场景。
7. 网络层覆盖有限（抓包仍有未覆盖请求）；除「不改已创建 session」外，具体原因未确定。
8. 展示方法层的超时与回调行为未验证。
9. `h2tcbox.baidu.com/ztbox`（抓包 35 次/30s）没抓到响应体，定性不了，暂不处理；它属于未知流量，不是「广告请求未覆盖」。
