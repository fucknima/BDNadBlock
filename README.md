# BDNadBlock

百度网盘 (com.baidu.netdisk) 13.32.2 的广告拦截 + 推荐内容/游戏中心移除 tweak。

## 规则从哪来

两条证据链，没有猜的：

**A. 抓包** —— 2026-10-15 Loon，632 条请求 / 30 秒窗口，**逐条看响应体定性**。

**B. 二进制** —— `__objc_classlist` 34952 项 → `class_ro_t.baseMethodList`，
拿到真实方法名和 type encoding。用 `scripts/verify_selectors.py` 复核：

```bash
python3 scripts/verify_selectors.py /path/to/Payload/netdisk_iPhone.app/netdisk_iPhone
# 18 个 selector，0 个有问题
```

App 升级后必须重跑，selector 失效会直接报出来。

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
动了它可能让开屏卡死。掐显示层最坏的结果是「没有广告」。

返回类型全部核对过：13 个 `v`(void)，5 个 `B`(BOOL)，
no-op 返回 nil/NO 落在 `x0`，调用方读不到垃圾。

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

## 防崩措施

1. **不交换 IMP**。用 `method_setImplementation` + 保存原 IMP 直调。
   上一版用 `method_exchangeImplementations` 写反了方向 → 无限递归 → `depth 12353`
   打穿 Stack Guard 闪退。现在结构上不可能递归。
2. **返回类型闸门**。返回结构体/浮点/复数的方法一律跳过 —— no-op 只保证 `x0` 有效。
3. **延迟到 app ready**。崩溃栈显示 Foundation 在 `notifyObjCInit` 阶段就会调用
   `ephemeralSessionConfiguration`，那时介入会撞上未初始化的状态。推迟 1.5s。
4. **日志落盘也延迟**。启动期 `writeToFile` 和 Foundation 初始化竞争过。
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
| `BDRemoveRecommend` | YES | 推荐内容 |
| `BDRemoveGameCenter` | YES | 游戏中心 |

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
[BDNadBlock] hooked -[BDNCBUAdsSplashAD showAdWithViewController:] (returns 'v')
[BDNadBlock] method hooks done, walked 11 classes
[BDNadBlock] blocked[ad-banner] pan.baidu.com/buy/ad/get
```

`跳过 -[类 selector] (returns '{...}')` 这种行说明返回类型闸门挡下了不安全的 hook，属正常。

## 已知限制

**拦不到**：

1. **QUIC / Tquic**。`Tquic.framework` 直连 socket，不过 `NSURLProtocol`。
2. **非标端口的裸 socket**。`jomoxc.com:9082`、`antpcdn.com:19001`、`yingt.asia:9549`。
   （不过这些实测是静态资源镜像，本来也不该拦。）
3. **延迟生效的 session**。1.5s 之前创建的 `NSURLSession` 不在拦截范围内。
4. **服务端下发的开关**。`afdconf.baidu.com` 的 `nad_*` 是服务端数据，改二进制无效 —— 所以走网络层拦。
5. **`h2tcbox.baidu.com/ztbox`（35 次/30s）** 没抓到响应体，定性不了，暂不处理。
