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

## 安装

```bash
# 越狱设备：把 dylib 放到
/var/jb/Library/MobileSubstrate/DynamicLibraries/BDNadBlock.dylib

# 侧载 IPA：用 ElleKit / Substrate 注入，或用 AppSync 配合该 dylib
```

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
make package FINALPACKAGE=1
```