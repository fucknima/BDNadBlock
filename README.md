# BDNadBlock

百度网盘 (com.baidu.netdisk) 13.32.2 的广告拦截 + 推荐内容/游戏中心移除 tweak。

**实验版本，不代表已去除全部广告或全部入口。** 抓包 387 证明旧版推荐/游戏移除无效；
新版改为在**原生组装/纯显示谓词**处移除：首页「推荐/创意」整块 + 「我的」页游戏中心区块，
共 3 个精准 typed hook（见下）。根因与证据见 [本次研究记录](docs/capture-387.md)。
构建成功、selector 存在、hook 安装成功都不等于真机功能验证；换上新版后**必须彻底退出 App 再重启**。

## 规则从哪来

两条证据链（需要区分静态观测与真机行为）：

**A. 抓包** —— 2026-10-15 Loon，632 条请求 / 30 秒窗口，**逐条看响应体定性**。

**B. 二进制** —— `__objc_classlist` 34952 项 → `class_ro_t.baseMethodList`，
拿到真实方法名和 type encoding。用 `scripts/verify_selectors.py` 复核：

```bash
python3 scripts/verify_selectors.py /path/to/Payload/netdisk_iPhone.app/netdisk_iPhone
# 18 个广告 selector + 3 个 feature hook，0 个有问题
```

App 升级后必须重跑，selector 失效会直接报出来。feature hook 这一组核对得更严：
类/selector 必须存在，且方法要在**该类自己的方法表**里（类方法看 metaclass），
完整 type encoding 逐字节一致，否则运行时安装器会 skip。

## 网络层

注册 `BDNadProtocol`（`NSURLProtocol` 子类），把两个工厂方法
（`defaultSessionConfiguration` / `ephemeralSessionConfiguration`）挂上这个协议类。
请求发出前按 host/path 判定，命中直接返回 `200 {}`，不真正出网。

### 拦什么（响应体证实）

| 目标 | 位置 | 证据 |
|---|---|---|
| 首页 banner 广告 | `pan.baidu.com/buy/ad/*` | `adList[0].title="双十一上淘宝"`，`actionUrl=ulk.alimama.com/tb?...` |
| 激励任务广告 | `pan.baidu.com/rest/2.0/pcs/adv` | `scene_list[].task_list[].complete_notice="恭喜获得1次音频倍速播放机会"` |
| 广告开关 | `afdconf.baidu.com/afd/platform` | `nad_*` 明文开关下发 |
| 广告点击归因 | `nsclick.baidu.com` | `/v.gif` 打点 |
| 百度营销云 | `sofire.baidu.com` | 返回加密 `exkey`（广告密钥） |
| 趣盟 SDK | `*.yunxish.com`、`cpc-service-square.iggrowth.cn` | `qumeng_*` 配置，SDK 1.3.8 |
| 三方联盟 | `ef-dongfeng.tanx.com`、`tnc3-alisc1.zijieapi.com`、`mssdk.volces.com`、`huiduapi.nuomi.com` | 阿里妈妈 / 穿山甲 / 火山 |
| 投屏广告 | `conf.hpplay.cn`、`vfa.hpplay.cn`、`ssdkauth.hpplay.cn`、`logu.hpplay.cn` | `csj_ad_switch:{enabled:1}` |
| 游戏中心接口 | `pan.baidu.com/act/v2/gamecenter/*` | `historyplay` / `gametaskinfo` / `recommend` |
| 游戏中心素材 | 路径含 `/gameCenter/` 或 `_swan-game_` | 走 P2P 镜像，host 不固定，只能按路径判 |
| 推荐内容 | `pan.baidu.com/recommend/searchbox/bottom`、`aisearch/agent/memorycenter/getrecommendcards` | 搜索框底部推荐词 |

### 不拦什么（**曾经的误判，实测是功能**）

| 曾经想拦 | 实际是什么 |
|---|---|
| `pan.baidu.com/feed/kingkongdistrict` | 首页**金刚区快捷入口**。15 个条目全是真功能：相册/视频/求职/小说/扫描/听记/文档/学习/音频/笔记/打印/备份/星盘/同步/全网搜 |
| `*/amis/` | 首页**天气特效包**（rain/snow/fog/sunny_v5.zip）、音效 mp3、**首页 banner 图**。拦掉首页特效和图标全没 |
| `*.jomoxc.com`、`*.antpcdn.com`、`*.yingt.asia` | 上面那批静态资源的 **P2P 加速镜像**（`antpcdn.com:19001/e/s0-ant.baidu.com/staticsns/amis/...`） |
| `*.cdn.bcebos.com/cmpkg/` | 不只是游戏，还有 **`1_swan-core` —— 小程序运行时**。只能精确拦 `1_swan-game_` |

## 方法层

18 个 selector / 11 个类，**只 hook「把广告显示出来」这一步**，
不碰 bidding / task / timeout 管理器。

理由：`BDNCSplashBiddingTaskManager` 持有开屏超时计时器
（`handleAdvertiseFetchTimeOutEvent` / `startAdvertiseFetchTimer`），
动了它可能让开屏卡死；显示层 no-op 也可能影响回调与等待状态，仍需真机验证。

返回类型已核对：11 个 `v`(void)，7 个 `B`(BOOL)。
这只说明返回类型，不证明业务状态、回调、布局或所有 ABI 细节安全。

| 类 | selector |
|---|---|
| `BDNCSplashAdvertiseWindow` | `showSplashWithActivityModel:`、`showSplashWithImageURL:protocol:showAdWarn:` |
| `BDNCSplashAdvertiseViewController` | `addSplashAdvertiseWithAdvertiseModel:`、`addSplashWithActivityModel:`、`addSplashWithImageURL:protocol:showAdWarn:`、`showDetailSplashAdvertise` |
| `BDNCBUAdsSplashAD` | `showAdWithViewController:` |
| `BDNCBrandSplashAd` | `showSplashViewInRootViewController:` |
| `BDNCBuAdsRewardVideoAD` | `showAd:` |
| `BDNCRewardVideoAdBaseTask` | `showAdvertise` |
| `BDNCNativeAdBaseTask` | `handleShow:` |
| `ABUSplashAd` | `showInWindow:`、`showInWindowWithBlock:` |
| `ABUInterstitialAd` | `showAdFromRootViewController:` |
| `ABUInterstitialProAd` | `showAdFromRootViewController:extraInfos:` |
| `ABURewardedVideoAd` | `showAdFromRootViewController:`、`:extraInfos:`、`:extroInfos:`（原代码拼错，两个都在） |

## 精准 feature hook（3 个，`FeatureRemoval.h`）

不是 no-op 整类，而是三个**typed** 替换实现，在启动构造器（`__attribute__((constructor))`）
里同步安装，不走那两条 1.5s / 3s 定时器。先保存原 IMP 再 `method_setImplementation`，
调用时按开关决定抑制还是透传，不对回调与布局做任何猜测。

只有冷启动、且安装发生在页面组装之前才会生效（同一构造器先装 hook、后由 UI 组装页面）。
**这是静态推断，不是已观测的运行事实**：真机先看日志里有没有三行 `[BDNadFeature] installed`。

| 目标 | 类 / 方法（类型） | encoding | 抑制时返回 |
|---|---|---|---|
| 首页「推荐/创意」整块 | `+[BHSettings isMSHSwitchTypeHomeRecommend]` | `B16@0:8` | `false`（B 编码用内建 bool） |
| 同上，去掉残留的容器行（含「开启推荐」条） | `-[BDPanNewMSHContentViewController tableView:numberOfRowsInSection:]` | `q32@0:8@16q24` | `0` |
| 「我的」页游戏中心区块 | `+[BDPanPersonalConfig gameCenterSwitch]` | `B16@0:8` | `false`（同上） |

- **创意入口会一起隐藏**：原生关闭态的 tab 头本来就被替换成「开启推荐」条，
  第二条把这一行也去掉，所以创意社区在这个容器里的入口一并消失。
  本轮**没有验证**创意社区是否还有本模块之外的独立入口。
- 首页那两条是**一对**：先一起校验（含「槽里已经就是本 hook」这种冲突），两个都可装才装，
  任一条不通过（类缺失、方法只有继承实现、encoding 或参数个数不符）就**两条都不装**。游戏那条独立校验。
- 安装器幂等：重复安装不会把自己的替换实现存成「原实现」，也不会多包一层。
- 静态实现里固定区块（最近文件、相册、备份等）在 `tableHeaderView` 上，这三个方法不改它的实现；
  **真机布局仍待验证**。
- **替换后必须彻底退出 App 再重启**（后台杀不干净）：只有冷启动才会重新读这些 hook。
- `tests/feature_removal_test.mm` 是 **macOS host 机制测试，不是真机测试**，
  只证明匹配/跳过/透传/幂等这些机制。本地跑（与 CI 同一条命令）：

```bash
clang++ -std=c++17 -fobjc-arc -fblocks -Wall -Wextra -Werror \
  -framework Foundation -o /tmp/frt tests/feature_removal_test.mm && /tmp/frt
```

## 防崩措施

1. **不交换 IMP**。用 `method_setImplementation` + 保存原 IMP 直调。
   上一版用 `method_exchangeImplementations` 写反了方向 → 无限递归 → `depth 12353`
   打穿 Stack Guard 闪退。现在不通过被替换的同名 selector 调回自身。
2. **返回类型闸门**。返回结构体/浮点/复数的方法一律跳过 —— no-op 只保证 `x0` 有效。
3. **保留 1.5 秒延迟**。这不代表 app ready，且不能覆盖已创建的网络会话；
   旧崩溃栈只证明递归，不证明 Foundation 初始化异常。
4. **日志落盘也延迟**。没有证据表明日志写盘是此前崩溃的原因。
5. **跳过生命周期方法**。`init` / `dealloc` / `copy` / `load` / `initialize` / setter 等。
6. **IMP 全局复用**。`imp_implementationWithBlock` 每次调用生成一个永不释放的
   trampoline，共用一个。
7. **按类下刀**。`BDHookMap` 是「类 → selector」的映射，不会把同名方法误伤到别的类。

## 开关

`NSUserDefaults`：

| key | 默认 | 作用 |
|---|---|---|
| `BDNadBlockEnabled` | YES | 方法层总开关 |
| `BDNadBlockDumpOnly` | NO | YES = 只 dump 不下刀 |
| `BDNadBlockNetwork` | YES | 网络层总开关 |
| `BDRemoveRecommend` | YES | 首页「推荐/创意」整块（H1+H2 一对） |
| `BDRemoveGameCenter` | YES | 「我的」页游戏中心区块 |

出问题时把 `BDNadBlockNetwork` 或 `BDNadBlockEnabled` 设 NO 即可定位是哪一层。

## 日志

同时写 syslog 和沙盒 `Documents/BDNadBlock-dump.txt`（缓冲区从进程启动就在累积）。

```bash
# 取文件
find /var/mobile/Containers/Data/Application -name BDNadBlock-dump.txt

# 或实时看
log stream --predicate 'eventMessage CONTAINS "BDNadBlock"'
```

期望输出：

```
[BDNadBlock] hooked +[NSURLSessionConfiguration defaultSessionConfiguration]
[BDNadBlock] hooked +[NSURLSessionConfiguration ephemeralSessionConfiguration]
[BDNadBlock] selftest: default=1 ephemeral=1 (want 1/1)
[BDNadFeature] installed home-recommend: +[BHSettings isMSHSwitchTypeHomeRecommend] enc=B16@0:8
[BDNadFeature] installed home-recommend-rows: -[BDPanNewMSHContentViewController tableView:numberOfRowsInSection:] enc=q32@0:8@16q24
[BDNadFeature] installed game-center: +[BDPanPersonalConfig gameCenterSwitch] enc=B16@0:8
[BDNadFeature] hit home-recommend（首次真正抑制）
[BDNadBlock] hooked -[BDNCBUAdsSplashAD showAdWithViewController:] (returns 'v')
[BDNadBlock] method hooks done, walked 11 classes
[BDNadBlock] blocked[ad-banner] pan.baidu.com/buy/ad/get
```

`[BDNadFeature] skip ...` 说明校验没过（类缺失 / 只有继承实现 / encoding 或参数个数
不符）：**什么都没装**，不是崩了。首页那两条是成对的，skip pair 意味着两条都没装。
`hit` 只在首次真正抑制时打一行，不是每帧。

`跳过 -[类 selector] (returns '{...}')` 这种行说明返回类型闸门挡下了不安全的 hook，属正常。

## 已知限制

**拦不到**：

1. **QUIC / Tquic**。`Tquic.framework` 直连 socket，不过 `NSURLProtocol`。
2. **非标端口的裸 socket**。`jomoxc.com:9082`、`antpcdn.com:19001`、`yingt.asia:9549`。
   （不过这些实测是静态资源镜像，本来也不该拦。）
3. **延迟生效的 session**。1.5s 之前创建的 `NSURLSession` 不在拦截范围内。
4. **服务端下发的开关**。`afdconf.baidu.com` 的 `nad_*` 是服务端数据，改二进制无效 —— 所以走网络层拦。
5. **`h2tcbox.baidu.com/ztbox`（35 次/30s）** 没抓到响应体，定性不了，暂不处理。
6. **推荐/游戏的其它入口**。这 3 个 hook 只挡「渲染 + 组装 + 已有解析/分页路径」；
   共享 manager 的冷启动预取、socket / VoIP / remotePush 入口**没有被证明**被挡住，
   所以不宣称「零请求」。游戏那条是**组装闸门**：只阻止新建区块，不负责删除已经显示的区块。
7. **创意社区是否有本容器之外的独立入口**没验证；若有，第 2 条 hook 不影响它。
