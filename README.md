# BDNadBlock

百度网盘 (com.baidu.netdisk) 广告拦截 tweak，针对 13.32.2 分析编写。

## 它做什么

运行时遍历 ObjC runtime，匹配到广告相关类后短路其展示方法：

- 类名匹配片段：`SplashAdvertise` / `PrologueAd` / `InterstitialAd` / `RewardVideoAd` /
  `NativeAd` / `BannerAd` / `AdvertiseWindow` / `AdBaseTask` / `ADXAd` / `AppOpenAd` …
- 方法名匹配前缀：`show` / `present` / `startShow` / `play` / `display` / `loadAndShow` …

另有一层兜底：每秒扫描 key window，移除类名含 `Ad`/`Splash`/`Banner` 的视图。

设计成不硬编码类名，是因为该 IPA 的 ObjC 元数据疑似被加固壳剥离，
`objc_getClass("BDNCSplashAdvertiseWindow")` 这类直接取类可能取不到。
运行时遍历在壳没清空 `__objc_classlist` 的前提下才有效。

## 下载

Actions → Build → Artifacts，下载 `BDNadBlock.dylib`：

```
https://github.com/fucknima/BDNadBlock/actions
```

Artifact 内含三个文件：

| 文件 | 架构 | 用途 |
|---|---|---|
| `BDNadBlock.dylib` | FAT (arm64 + arm64e) | **用这个**，通用 |
| `BDNadBlock-arm64.dylib` | arm64 | A12 及以后 |
| `BDNadBlock-arm64e.dylib` | arm64e (PAC) | A12 及以后带 PAC |

验证过的产物信息：`Mach-O universal binary, 2 architectures`，依赖
`libobjc.A.dylib` / `UIKit` / `Foundation`，已 ldid 签名。

## 安装

```bash
# 越狱设备（rootless）
scp BDNadBlock.dylib <device>:/var/jb/Library/MobileSubstrate/DynamicLibraries/
ssh <device> chmod 755 /var/jb/Library/MobileSubstrate/DynamicLibraries/BDNadBlock.dylib
ssh <device> killall -9 SpringBoard

# 侧载 IPA：用 ElleKit / Substrate 注入，或 AppSync 装 dylib
```

装完重启网盘 App 生效。

## 怎么确认有没有生效

注入后查 syslog：

```bash
# 设备上
log stream --predicate 'eventMessage CONTAINS "BDNadBlock"'
```

- 看到 `[BDNadBlock] total hooked: N` 且 N > 0 → hook 挂上了，按打到的类判断覆盖面
- N = 0 或根本没这行 → 壳把 classlist 挡了，hook 无效，改用抓包关服务端开关

## 已知限制

- 未做越狱检测，纯注入用途
- 不处理服务端下发的广告位开关（`bdnc_feed_ad_switch_*`），那些改二进制没用，得抓包
- 无 iOS 设备实测，仅在 GitHub Actions 完成编译验证

## 编译

Actions 自动编译，产物在 Artifacts 里。或者本地：

```bash
export THEOS=~/theos
make            # 只出 dylib 到 .theos/obj/debug/
```

CI 踩过的坑（已修，供参考）：

- `install-theos` 脚本会打 `api.github.com`，Actions 上被限流返回 exit 8 → 改为直接 clone
- 浅克隆不带 ldid，签名步骤 `ldid: command not found` → CI 里 `brew install ldid`
- 管道后 `make` 失败会被吞掉 → 加 `set -o pipefail`，否则绿灯假成功
- 默认输出在 `.theos/obj/debug/`，且是 FAT 合并产物，不是 `.theos/obj/arm64/`