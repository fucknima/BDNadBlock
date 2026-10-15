# 抓包 387：推荐内容与游戏中心仍显示

用户确认范围：**首页推荐区块 + “我的”页游戏中心卡片**。不把相册、最近文件、备份等正常入口一并移除。

## 已核对的证据

- 输入：`387_1792074913952.zip`，SHA-256 `ebcb00f1e09efe5d2166158394e12c7c61839c3a6e7b49ad19b06e378a0c0465`。
- 对照二进制：13.32.2 的 `netdisk_iPhone`，SHA-256 `e12d60a78b9c82048e1e692005ddb0d3139be607c3aac2620426d089e58c3ed2`。
- Loon raw 导出，不是 HAR：3,948 个成员，1,296 个请求头记录，586 个可解析 JSON 响应，记录时间跨度约 46 秒。
- HTTP/2 请求头使用 `:authority` / `:path`，不能只按 HTTP/1 的首行解析。
- REA 归档清单证据：`ev_e3ca5b89ba2ccce2629a4f00a1c18307d2c86459406d012b8651ed27b76d5b43`。
  REA 只完成了归档清单；下列业务字段由本地脚本离线读取原始成员验证，未请求任何捕获 URL。

| 原始成员目录 | 路径 | 核对结果 |
|---|---|---|
| `4293_4871_1792074944501` | `/feed/cardinfos` | `data.cards` 有 16 张推荐卡片，包括元气圈视频、小说、运营推广；旧规则缺少这个接口 |
| `4467_5093_1792074949415`、`4580_5296_1792074957838` | `/act/v2/gamecenter/recommend` | 均收到实际游戏列表，不是插件的空响应 |
| `4468_5094_1792074949421`、`4578_5294_1792074957836` | `/act/v2/gamecenter/gametaskinfo` | 均返回七阶段游戏时长任务 |
| `4469_5095_1792074949421`、`4579_5295_1792074957837` | `/act/v2/gamecenter/historyplay` | 均返回三个历史游戏 |
| `3805_3982_1792074916684` | `/api/getsyscfg` | `bdnc_commerce_config_area.cfg_list` 中 `node_key=gamecenter` 包含“我的页面-游戏中心配置”、`hot_gamelist`、`guess_gamelist` 和入口 URL |

游戏资源响应 `3839_4066_1792074917218/response_body_raw` 自身是 ZIP。
其 `manifest.json` 把 `/operation/activitys/gamecenter` 映射到页面，
`gameCenter/js/nsr.bundle.js` 含上述三个游戏接口与任务/推荐列表逻辑。
因此还存在独立的混合页面入口，不能把它和“我的”原生区块混为一谈。
REA 的 JS 分析在 120 秒超时后保留了部分静态证据
`ev_bbff85fe889b2a67762618a69adfb1482b71da3e67af05e15bd10d5d38a92224`；
未执行 JS，未证明运行时路由覆盖。

## 旧版本为什么不足

1. 推荐内容被错误缩小为搜索框推荐词和记忆中心卡片，没有覆盖真正的 `/feed/cardinfos`。
2. 游戏接口即使被拦，配置仍可以提供入口与默认游戏列表；旧版本没有改变区块组装逻辑。
3. 用户日志的 `selftest=1/1` 只检查**新建**配置对象，不能证明已有网络会话或其他网络栈被拦。
   此 ZIP 中有 9 个请求在默认开关下会匹配旧版推荐/游戏规则，但仍收到非空服务端 JSON。
   旧日志未记录设备上的开关值，因此也不能排除开关被关闭；新日志会打印开关快照。

Apple 文档确认，`NSURLSession` 初始化后持有配置的副本，后续改变配置不影响已有会话：
https://developer.apple.com/documentation/foundation/urlsession/configuration

**未验证**：这台设备具体是哪条网络调用链绕过了协议类。抓包与日志没有调用栈，也没有同一时间轴，不能仅凭它们断言是 QUIC 或启动前创建的会话。

## 安全边界

- 不整拦 `/api/getsyscfg`、`/api/getconfig`：其中同时包含文件、备份、预览等正常功能配置。
- 不清空 App 数据或配置缓存，不改用户的文件和登录态。
- 不把“方法名与返回类型存在”当成“业务安全”或“真机移除成功”。
- 不上传原始抓包、Cookie、完整请求头或账号数据到仓库。

## 已核对的原生 hook（只读静态证据）

对照二进制 SHA-256 `e12d60a7…`（13.32.2）。地址是未滑移 VM，只用于复核，安装时用真实类/selector，不硬编码地址。

| 位置 | 类型 | encoding | IMP | 静态依据 |
|---|---|---|---|---|
| `+[BHSettings isMSHSwitchTypeHomeRecommend]` | 类方法 | `B16@0:8` | `0x10561c6f0` | 读 `BHSettingMSHSwitchTypeHomeRecommend`，无值默认 YES；推荐链路 21 处已观测读点 |
| `-[BDPanNewMSHContentViewController tableView:numberOfRowsInSection:]` | 实例方法 | `q32@0:8@16q24` | `0x1061942a4` | 返回 `1 + 推荐开关`；行 0 头部、行 1 内容 cell |
| `+[BDPanPersonalConfig gameCenterSwitch]` | 类方法 | `B16@0:8` | `0x106e18b44` | `setupSections`（`0x106e39eb4`）与 `updateGameSection`（`0x106e39b04`）两处闸门 |

- 首页容器是 `BDPanNewMultiSectionsHomeViewController` 里的 `BDPanNewMSHContentViewController`：
  表头是固定区块（最近文件/相册等），表体只有「推荐/创意」两行；原生关闭态头部仍是 44pt 的
  「开启推荐」条，所以要让整块（含创意 tab）消失，这两条要一起用。
- 游戏的新旧 section 由 `showNewGameSectionABTest`（AB key `main_NA_gamepart_1224`）在
  `BDPanOperationGameCenterSection` / `BDPanGameCenterSection` 间二选一；`gameCenterSwitch` 为 false
  时两条路径都不创建。只把 `fetchSectionData` 做 no-op 不够——新 section 高度恒为 232pt。
- 静态边界：证据只覆盖 `__text` 里的 B/BL、递归 B 跳板与 ≤64 字节非 ObjC 短包装；不含动态
  SEL/NSInvocation、运行时 swizzle、跨映像 UIKit delegate 调用与所有间接 BLR。`gameCenterSwitch` 为 false
  也**不负责删除已经显示的区块**（删除是 `personalHiddenGameSwitch` 的路径，本轮未采用）。
- `verify_selectors.py` 只读 `class_ro_t` 的基础方法表，不扫 `__objc_catlist`；而运行时
  `class_copyMethodList` 会把 category 方法算作本类自己的方法。当前三处都在基础方法表里（脚本已核对一致）；
  若哪天只剩 category 实现，脚本会报「不在本类自己的方法表」（假警报），安装器仍会装。
- 未验证：真机布局与滚动联动、是否会停掉所有后台推荐请求（不宣称零请求）、
  `bdnc_commerce_config_area` 里 `node_key=gamecenter` 到该 getter 的逐字段映射。
- 复核：`python3 scripts/verify_selectors.py <netdisk_iPhone>`（同时核对上面 3 条与 18 个广告 selector）。
