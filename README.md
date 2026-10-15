# BDNadBlock

百度网盘 (com.baidu.netdisk) 广告拦截 tweak —— **网络层**版本。

## 原理

注册 `BDNadProtocol`（`NSURLProtocol` 子类）+ swizzle `NSURLSessionConfiguration` 的两个工厂方法。
请求发出前按 host/path 判定，命中则直接返回 `200 {}`，不真正出网。

拦截清单来自 2026-10-15 的 Loon 抓包（`381_1792041072312.har`，632 条请求，30 秒窗口）：

| 目标 | 域名 | 说明 |
|---|---|---|
| 趣盟 CPC 配置 | `cpc-service-square.yunxish.com` | `qumeng_config`，SDK 1.3.8 |
| 趣盟备用域 | `cpc-service-square.iggrowth.cn` | `qumeng_host_config` |
| 趣盟上报 | `*.yunxish.com`（report/logrcv/trace） | 曝光与点击 |
| 开屏 NAD 开关 | `afdconf.baidu.com` | `nad_*` 全局开关下发 |
| 广告素材 | `*.jomoxc.com:9082`、`*.antpcdn.com` | 天气/美食/主题等个性化 zip |
| 广告素材路径 | `*.bcebos.com` + `/amis/` | 只拦该路径，不整域 |
| 归因监测 | `nsclick.baidu.com`、`ef-dongfeng.tanx.com` | 点击追踪 |
| 穿山甲 | `tnc3-alisc1.zijieapi.com` | HTTP DNS 配置 |
| 火山上报 | `mssdk.volces.com` | 穿山甲/头条系埋点 |
| 投屏穿山甲 | `conf.hpplay.cn` 等 | `csj_ad_switch:{enabled:1}` |

## 已知限制（重要）

**能拦**：`NSURLSession` + `AFNetworking` + `NSURLConnection`。抓包里 524 条 HTTP/1.1 + 104 条 HTTP/2 基本都走这条栈，覆盖面够。

**拦不到**：

1. **QUIC / Tquic**。`Tquic.framework` 直连 socket，不经过 `NSURLProtocol`。
2. **自研 HTTP 栈**。`mssdk.volces.com`、`jomoxc.com:9082` 用非 80/443 端口，可能是裸 socket。
3. **加载时被绕过的 session**。若 SDK 自建 `NSURLSession` 并显式指定 `protocolClasses`，swizzle 的默认工厂不生效。
4. **加固壳**。若 App 有壳且 hook runtime，这套基于 `NSURLProtocol` 的注册也可能被拦。

## 验证有没有生效

```bash
log stream --predicate 'eventMessage CONTAINS "BDNadBlock"'
```

看到 `[BDNadBlock] blocked [tag] host/path` 说明命中；一条都没有说明 dylib 没注入或 App 绕过了。

## 下载

Actions → Build → Artifacts → `BDNadBlock.dylib`

| 文件 | 架构 |
|---|---|
| `BDNadBlock.dylib` | FAT (arm64 + arm64e)，**用这个** |
| `BDNadBlock-arm64.dylib` | arm64 |
| `BDNadBlock-arm64e.dylib` | arm64e (PAC) |

## 安装

```bash
scp BDNadBlock.dylib <device>:/var/jb/Library/MobileSubstrate/DynamicLibraries/
ssh <device> chmod 755 /var/jb/Library/MobileSubstrate/DynamicLibraries/BDNadBlock.dylib
ssh <device> killall -9 SpringBoard
```

## 开关

在 App 的 `NSUserDefaults` 里设 `BDNadBlockEnabled = NO` 可临时放行全部请求。

## 编译

Actions 自动编译。或本地：

```bash
export THEOS=~/theos
make
```

CI 踩过的坑（已修）：

- `install-theos` 会打 `api.github.com`，Actions 限流 exit 8 → 改直接 clone
- 浅克隆不带 ldid → CI 里 `brew install ldid`
- `make | tail` 会吞掉失败退出码 → 加 `set -o pipefail`
- 默认输出在 `.theos/obj/debug/`，且是 FAT 合并产物