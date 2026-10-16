// BDNadBlock — 广告拦截 + 移除推荐内容/游戏中心
//
// 证据范围（命中规则/安装 hook 不等于功能已移除）：
//   A. 2026-10-15 Loon 抓包（632 条请求 / 30s），逐条看响应体定性
//   B. __objc_classlist 34952 项 -> class_ro_t.baseMethodList 解析出的真实方法名
//      scripts/verify_selectors.py 会核对每个 selector 是否存在、返回类型是否安全。
//      App 升级后重跑一次：python3 scripts/verify_selectors.py /path/to/netdisk_iPhone
//
// ---------------------------------------------------------------------------
// 抓包中被否掉的规则（曾误判为广告，实测是功能）：
//
//   pan.baidu.com/feed/kingkongdistrict
//       不是推荐流，是首页金刚区。15 个条目全是真实功能：
//       相册/视频/求职/小说/扫描/听记/文档/学习/音频/笔记/打印/备份/星盘/同步/全网搜
//
//   amis 路径 (staticsns.cdn.bcebos.com 等)
//       不是广告素材。里面是首页天气特效包 rain/snow/fog/sunny_v5.zip、
//       音效 mp3、以及首页 banner 图。拦掉 = 首页特效和图标全没。
//
//   *.jomoxc.com / *.antpcdn.com / *.yingt.asia
//       不是广告域名，是上面那批静态资源的 P2P 加速镜像
//       （如 antpcdn.com:19001/e/s0-ant.baidu.com/staticsns/amis/…）。
//
//   bcebos 的 cmpkg 目录
//       不只装游戏，还有 1_swan-core —— 小程序运行时。只能精确拦 1_swan-game_。
// ---------------------------------------------------------------------------
//
// 注意：本文件里不要出现连续的 斜杠星号 或 星号斜杠 序列，
// 哪怕在 // 行注释里也不行 —— Theos 的 Logos 预处理器会把它当块注释，吞掉后面的代码。
//
// 方法层（18 个 selector，11 个类，全部经二进制核对）：
//   只 hook「把广告显示出来」这一步，不碰 bidding/task/timeout。
//   理由：task 管理器持有 splash 超时计时器（handleAdvertiseFetchTimeOutEvent /
//   startAdvertiseFetchTimer）。显示层 no-op 的回调与超时行为仍需真机验证。
//   元数据确认返回 v(void) 或 B(BOOL)，这不证明业务状态与布局安全。
//
// 精准 feature hook（3 个，实现见 FeatureRemoval.h，构造器里同步安装）：
//   首页「推荐/创意」整块 = +[BHSettings isMSHSwitchTypeHomeRecommend] 与
//   -[BDPanNewMSHContentViewController tableView:numberOfRowsInSection:] 一对；
//   我的页游戏中心 = +[BDPanPersonalConfig gameCenterSwitch]。
//   先存原 IMP 再换，调用时按开关透传；签名不符/方法不在本类自己的表里就 skip。
//
// 防崩：
//   - 不交换 IMP，用 method_setImplementation + 保存原 IMP 直调（交换写反 = 无限递归，
//     上一版就是栽在这里：depth 12353 打穿 Stack Guard）
//   - 返回结构体/浮点的方法一律不碰（no-op 只保证 x0 有效，s0/x1 是垃圾）
//   - 跳过 init/dealloc/copy/load/setter 等生命周期方法
//   - 网络 hook 目前延迟 1.5 秒；定时器不代表 app ready，已有 session 也不会被改写
//
// 日志：syslog + 沙盒 Documents/BDNadBlock-dump.txt（可取出）

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <string.h>
#import <stdarg.h>
#import "Preferences.h"   // 唯一默认值来源 + 启动快照读原语（不在这里抄默认值）

#pragma mark - 日志

static NSMutableString *BDLogBuffer;
static NSString *BDLogPath;
static dispatch_queue_t BDLogQueue;
static BOOL BDLogFileEnabled = NO;   // 延迟启动阶段（BDLogPathReport）才开，不在构造器里解析路径

static NSString *BDResolveLogPath(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!docs) docs = NSTemporaryDirectory();
    return [docs stringByAppendingPathComponent:@"BDNadBlock-dump.txt"];
}

static void BDLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSLog(@"%@", msg);

    // 只建缓冲区和队列。**不在这里解析沙盒路径**：BDLog 会在构造器阶段
    // （dyld 镜像初始化）就被调用；目录解析沿用延迟启动阶段（BDLogPathReport）。
    // 未证明它是历史崩溃原因 —— 已有的崩溃根因是 IMP 交换递归，不是目录服务。
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        BDLogBuffer = [NSMutableString string];
        BDLogQueue = dispatch_queue_create("com.bdnadblock.log", DISPATCH_QUEUE_SERIAL);
    });

    dispatch_async(BDLogQueue, ^{
        [BDLogBuffer appendString:msg];
        [BDLogBuffer appendString:@"\n"];
        if (BDLogFileEnabled) {
            [BDLogBuffer writeToFile:BDLogPath atomically:YES
                             encoding:NSUTF8StringEncoding error:NULL];
        }
    });
}

// 在延迟启动阶段调用：此时解析路径并打开落盘开关。
// 缓冲区从进程启动就在累积，所以第一次落盘会把之前的日志一起写下去。
static void BDLogPathReport(void) {
    dispatch_async(BDLogQueue, ^{
        BDLogPath = BDResolveLogPath();
        BDLogFileEnabled = YES;
        BDLog(@"[BDNadBlock] log file: %@", BDLogPath);
    });
}

#pragma mark - 开关（读启动快照，不是读实时 defaults）

// 语义（与 Preferences.h 议定）：BDNadPrefsActive 读本进程启动时建的唯一快照，
// 默认值只在 Preferences.h 的规格表里有一份，这里一律用原键、不再抄默认值。
// 于是：设置菜单改开关 = 只影响**下次冷启动**，不热改当前进程、不重启 App；
// 进程起来之后这里的返回值不再变化，所以"启动期判一次"的写法（BDSetupNetwork）是安全的。
static BOOL BDEnabled(void)           { return BDNadPrefsActive(@"BDNadBlockEnabled"); }
static BOOL BDDumpOnly(void)          { return BDNadPrefsActive(@"BDNadBlockDumpOnly"); }
static BOOL BDRemoveRecommend(void)   { return BDNadPrefsActive(@"BDRemoveRecommend"); }
static BOOL BDRemoveGameCenter(void)  { return BDNadPrefsActive(@"BDRemoveGameCenter"); }
static BOOL BDRemoveJobNovel(void)    { return BDNadPrefsActive(@"BDRemoveJobNovel"); }
static BOOL BDRemoveSearchPromo(void) { return BDNadPrefsActive(@"BDRemoveSearchPromo"); }
static BOOL BDRemoveSearchAI(void)    { return BDNadPrefsActive(@"BDRemoveSearchAI"); }
static BOOL BDRemoveAITab(void)       { return BDNadPrefsActive(@"BDRemoveAITab"); }
static BOOL BDRemovePersonalBanner(void) { return BDNadPrefsActive(@"BDRemovePersonalBanner"); }
static BOOL BDRemoveRenewButton(void)   { return BDNadPrefsActive(@"BDRemoveRenewButton"); }
static BOOL BDRemovePersonalPromotions(void) { return BDNadPrefsActive(@"BDRemovePersonalPromotions"); }
static BOOL BDRemoveTaskCard(void)      { return BDNadPrefsActive(@"BDRemoveTaskCard"); }

// 网络拦截总门：总开关 + 诊断 + 网络开关的组合，任一不满足就整层不拦。
// matcher 最前查一次即可，不需要在里面重复判断总开关。
static BOOL BDBlockNetwork(void) {
    return BDEnabled() && !BDDumpOnly() && BDNadPrefsActive(@"BDNadBlockNetwork");
}

// 组件 include 顺序（依赖是单向的，别调换）：
//   FeatureRemoval.h  提供 BDFRSpec / BDFRResolve / BDFRInstallSpec / BDFRSuppressed
//   TabRemoval.h      底部 AI tab 过滤 + 索引映射（复用 FeatureRemoval 的安装器）
//   PersonalRemoval.h「我的」活动轮播 + 推广整排（同样复用安装器；后续 promo 往这里追加）
//   PersonalViewRemoval.h「我的」任务卡 / 金币卡（布局 post-hook + 只读 getter 依赖）
//   RenewButtonRemoval.h「去续费」按钮可隐藏（不 import UIKit，靠调用方先引入的 UIKit）
//   SettingsMenu.h    提供 BDPresentPurificationSettings（MenuEntry 的依赖）
//   SearchDataRemoval.h / SearchViewRemoval.h  搜索框数据层与 UI 层清理
//   MenuEntry.h       设置页入口按钮，依赖上面的菜单入口 + FeatureRemoval 的安装器
// 全部只读同一份 active 快照，不各写各的默认值。
#include "FeatureRemoval.h"
#include "TabRemoval.h"
#include "PersonalRemoval.h"
#include "PersonalViewRemoval.h"
#include "RenewButtonRemoval.h"
#include "SettingsMenu.h"
#include "SearchDataRemoval.h"
#include "SearchViewRemoval.h"
#include "MenuEntry.h"

#pragma mark - 网络拦截规则

// 规则表与 matcher 全在 Foundation-only 的 NetworkRules.h 里：同一份实现也被
// tests/network_rules_test.mm include，跑的是真实 matcher，不在测试里抄算法。
// 上面那批开关是它的依赖，所以必须放在本 include 之前。
#include "NetworkRules.h"

#pragma mark - NSURLProtocol

@interface BDNadProtocol : NSURLProtocol
@end

static NSURLSessionConfiguration *BDInjectProtocol(NSURLSessionConfiguration *c) {
    if (!c) return c;
    NSMutableArray *arr = [c.protocolClasses mutableCopy] ?: [NSMutableArray array];
    if (![arr containsObject:[BDNadProtocol class]])
        [arr insertObject:[BDNadProtocol class] atIndex:0];
    c.protocolClasses = arr;
    return c;
}

// 不交换 IMP。交换会把 SEL 指向彼此，写反一次就是无限递归
// ——上一版正是这么崩的（depth 12353 打穿 Stack Guard）。
// 保存原 IMP 后直调，避免通过被替换的 selector 再次进入自身。
static IMP BDOrigDefaultCfg;
static IMP BDOrigEphemeralCfg;

static NSURLSessionConfiguration *BDCallConfigIMP(IMP imp, Class cls, SEL sel) {
    // 原实现返回 +0（autorelease）对象。经函数指针调用的默认约定就是不持有，
    // ARC 会在赋值时自动 retain —— 不需要（也不允许）手写生命周期限定符。
    id r = ((id (*)(id, SEL))imp)((id)cls, sel);
    return BDInjectProtocol((NSURLSessionConfiguration *)r);
}

static id BDDefaultCfgHooked(id self, SEL _cmd) {
    return BDCallConfigIMP(BDOrigDefaultCfg, (Class)self, @selector(defaultSessionConfiguration));
}
static id BDEphemeralCfgHooked(id self, SEL _cmd) {
    return BDCallConfigIMP(BDOrigEphemeralCfg, (Class)self, @selector(ephemeralSessionConfiguration));
}

@implementation BDNadProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    NSString *tag = BDMatchNetwork(request.URL.host, request.URL.path);
    if (!tag) return NO;
    BDLog(@"[BDNadBlock] blocked[%@] %@%@", tag, request.URL.host, request.URL.path);
    return YES;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }

- (void)startLoading {
    NSData *body = [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *h = @{ @"Content-Type": @"application/json",
                         @"Content-Length": [@(body.length) stringValue] };
    NSHTTPURLResponse *r = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                                       statusCode:200
                                                      HTTPVersion:@"HTTP/1.1"
                                                     headerFields:h];
    [self.client URLProtocol:self didReceiveResponse:r cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:body];
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)stopLoading {}

@end

static void BDSetupNetwork(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 网络拦截总门不通过（总开关关 / 诊断开 / 网络开关关）：整层不进进程 ——
        // 不换 NSURLSessionConfiguration 工厂、不注册 NSURLProtocol，连拦截实现都不挂上。
        // 这里读的 active 快照在进程启动后就固定了，所以判一次即可（不热改当前会话）。
        // 日志打三个**原始快照值**，不要把复合返回值当成网络键的值来读。
        if (!BDBlockNetwork()) {
            BDLog(@"[BDNadBlock] network layer NOT installed "
                   "(master=%d dumpOnly=%d networkKey=%d)：未换工厂、未注册 NSURLProtocol",
                  BDEnabled(), BDDumpOnly(), BDNadPrefsActive(@"BDNadBlockNetwork"));
            return;
        }

        // 保留旧版 1.5 秒延迟。已确认的崩溃根因是递归；
        // 崩溃栈本身不能证明 Foundation 未初始化，也不能证明延迟能防崩。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            Class c = [NSURLSessionConfiguration class];
            struct { SEL sel; IMP *slot; IMP hook; const char *name; } items[] = {
                {@selector(defaultSessionConfiguration),   &BDOrigDefaultCfg,
                 (IMP)BDDefaultCfgHooked,   "defaultSessionConfiguration"},
                {@selector(ephemeralSessionConfiguration), &BDOrigEphemeralCfg,
                 (IMP)BDEphemeralCfgHooked, "ephemeralSessionConfiguration"},
            };
            for (unsigned i = 0; i < sizeof(items)/sizeof(items[0]); i++) {
                Method m = class_getClassMethod(c, items[i].sel);
                if (!m) {
                    BDLog(@"[BDNadBlock] +[NSURLSessionConfiguration %s] not found, skipped",
                          items[i].name);
                    continue;
                }
                // 先存原 IMP 再换，避免换完到存完之间被别的线程调到
                *items[i].slot = method_getImplementation(m);
                method_setImplementation(m, items[i].hook);
                BDLog(@"[BDNadBlock] hooked +[NSURLSessionConfiguration %s]", items[i].name);
            }

            [NSURLProtocol registerClass:[BDNadProtocol class]];

            // 自检：确认两个工厂都挂上了协议。
            // 说明：这不是崩溃保护 —— 栈溢出杀的是整个进程而不是这条线程，
            // @try 也抓不住信号。它只用来验证 hook 生效。
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                NSURLSessionConfiguration *d = [NSURLSessionConfiguration defaultSessionConfiguration];
                NSURLSessionConfiguration *e = [NSURLSessionConfiguration ephemeralSessionConfiguration];
                BDLog(@"[BDNadBlock] selftest: default=%d ephemeral=%d (want 1/1)",
                      [d.protocolClasses containsObject:[BDNadProtocol class]],
                      [e.protocolClasses containsObject:[BDNadProtocol class]]);
            });

            BDLog(@"[BDNadBlock] network layer on (hosts=%zu paths=%zu anypath=%zu)",
                  sizeof(BDHostRules)/sizeof(BDHostRules[0]),
                  sizeof(BDPathRules)/sizeof(BDPathRules[0]),
                  sizeof(BDAnyPathRules)/sizeof(BDAnyPathRules[0]));
        });
    });
}

#pragma mark - 方法 hook

// 类 -> 要掐掉的 selector。
// 全部来自 class_ro_t.baseMethodList 的实测结果，且返回类型已核对为 v / B。
static NSDictionary<NSString *, NSArray<NSString *> *> *BDHookMap(void) {
    return @{
        // 开屏：百度自研
        @"BDNCSplashAdvertiseWindow": @[
            @"showSplashWithActivityModel:",
            @"showSplashWithImageURL:protocol:showAdWarn:",
        ],
        @"BDNCSplashAdvertiseViewController": @[
            @"addSplashAdvertiseWithAdvertiseModel:",
            @"addSplashWithActivityModel:",
            @"addSplashWithImageURL:protocol:showAdWarn:",
            @"showDetailSplashAdvertise",
        ],
        // 开屏：穿山甲 / 联盟
        @"BDNCBUAdsSplashAD": @[@"showAdWithViewController:"],
        @"BDNCBrandSplashAd": @[@"showSplashViewInRootViewController:"],
        // 激励视频
        @"BDNCBuAdsRewardVideoAD": @[@"showAd:"],
        @"BDNCRewardVideoAdBaseTask": @[@"showAdvertise"],
        // 原生 / 信息流
        @"BDNCNativeAdBaseTask": @[@"handleShow:"],
        // TopOn 聚合层（返回 BOOL，no-op 返回 NO = 未展示，调用方本就有失败分支）
        @"ABUSplashAd": @[@"showInWindow:", @"showInWindowWithBlock:"],
        @"ABUInterstitialAd": @[@"showAdFromRootViewController:"],
        @"ABUInterstitialProAd": @[@"showAdFromRootViewController:extraInfos:"],
        @"ABURewardedVideoAd": @[
            @"showAdFromRootViewController:",
            @"showAdFromRootViewController:extraInfos:",
            @"showAdFromRootViewController:extroInfos:",
        ],
    };
}

static BOOL BDIsProtectedSelector(NSString *sel) {
    static NSArray *protect = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        protect = @[@"init", @"dealloc", @"new", @"copy", @"mutableCopy",
                    @"retain", @"release", @"autorelease", @"load", @"initialize",
                    @"description", @"debugDescription", @"hash", @"isEqual:"];
    });
    for (NSString *p in protect)
        if ([sel isEqualToString:p] || [sel hasPrefix:p]) return YES;
    return NO;
}

// no-op 实现只保证 x0 有效（返回 nil / NO / 0）。
// 返回结构体、浮点、复数的方法调用方会去读 s0/x1/v0，那是垃圾 —— 一律不碰。
static BOOL BDReturnTypeIsHookSafe(char t) {
    switch (t) {
        case 'v': case '@': case '#': case ':':
        case 'B': case 'c': case 'C': case 's': case 'S':
        case 'i': case 'I': case 'l': case 'L': case 'q': case 'Q':
        case '^': case '*':
            return YES;
        default:
            return NO;   // { ( [ f d D ? b 等
    }
}

static char BDReturnTypeChar(Method m) {
    char buf[32] = {0};
    method_getReturnType(m, buf, sizeof(buf));
    return buf[0];
}

// imp_implementationWithBlock 的 block 第一个参数是 self，**没有 _cmd**。
// 复用同一个 IMP：每次调用都会生成一个新 trampoline 且永不释放。
static id (^BDNoopBlock)(id) = ^id(id self_) { return nil; };
static IMP BDNoopIMP;

static void BDDumpClass(Class cls) {
    unsigned n = 0;
    Method *ms = class_copyMethodList(cls, &n);
    if (!ms) return;
    NSMutableString *line = [NSMutableString string];
    for (unsigned i = 0; i < n; i++) {
        SEL s = method_getName(ms[i]);
        if (s) [line appendFormat:@"%s,", sel_getName(s)];
    }
    BDLog(@"[BDNadDump] %@ (%u) :: %@", NSStringFromClass(cls), n, line);
    free(ms);
}

static void BDWalkMethods(Class cls, NSString *clsName, NSArray *wanted) {
    unsigned n = 0;
    Method *ms = class_copyMethodList(cls, &n);
    if (!ms) return;
    for (unsigned i = 0; i < n; i++) {
        SEL sel = method_getName(ms[i]);
        if (!sel) continue;
        NSString *s = NSStringFromSelector(sel);
        if (![wanted containsObject:s]) continue;
        if (BDIsProtectedSelector(s)) {
            BDLog(@"[BDNadBlock] skip -[%@ %@] (protected)", clsName, s);
            continue;
        }
        char rt = BDReturnTypeChar(ms[i]);
        if (!BDReturnTypeIsHookSafe(rt)) {
            BDLog(@"[BDNadBlock] skip -[%@ %@] (returns '%c', not register-safe)",
                  clsName, s, rt);
            continue;
        }
        if (!BDNoopIMP) BDNoopIMP = imp_implementationWithBlock(BDNoopBlock);
        method_setImplementation(ms[i], BDNoopIMP);
        BDLog(@"[BDNadBlock] hooked -[%@ %@] (returns '%c')", clsName, s, rt);
    }
    free(ms);
}

static void BDBoot(void) {
    BDLogPathReport();
    // 这里打印的是**本进程启动快照**（active），不是 defaults 里的当前值：
    // 设置菜单改开关只影响下次冷启动，本进程不会变。
    BDLog(@"[BDNadBlock] active snapshot (启动快照，菜单改动只影响下次冷启动): "
           "master=%d dumpOnly=%d network=%d adMethods=%d recommend=%d searchPromo=%d gameCenter=%d",
          BDEnabled(), BDDumpOnly(), BDBlockNetwork(), BDNadPrefsActive(@"BDNadBlockAdMethods"),
          BDRemoveRecommend(), BDRemoveSearchPromo(), BDRemoveGameCenter());
    // 规格表里每个键的启动快照值：默认值只从 Preferences.h 的表里取，这里不重抄；
    // 只打本组件的 fixed key，不碰账号/缓存/其它偏好。
    for (NSUInteger i = 0; i < BDNadPrefsSpecCount; i++)
        BDLog(@"[BDNadBlock] active %s = %d", BDNadPrefsSpecs[i].key,
              BDNadPrefsActive(@(BDNadPrefsSpecs[i].key)));
    BDLog(@"[BDNadBlock] 下面各组件的 installed / hit 只表示本进程装上并命中过，"
           "不等于真机效果已验证（效果要看抓包与页面）");
    NSDictionary *map = BDHookMap();
    unsigned dumped = 0, missing = 0;

    for (NSString *n in map) {
        Class c = objc_getClass(n.UTF8String);
        if (!c) { BDLog(@"[BDNadBlock] class missing: %@", n); missing++; continue; }
        BDDumpClass(c);
        dumped++;
    }
    BDLog(@"[BDNadBlock] dumped %u classes, %u missing", dumped, missing);

    // 这个早退只管旧 18 个广告 selector；精准 feature hook（Recommend/GameCenter）
    // 和网络层各自判断，不受这里影响。
    if (!BDEnabled() || BDDumpOnly() || !BDNadPrefsActive(@"BDNadBlockAdMethods")) {
        BDLog(@"[BDNadBlock] ad-method hooks skipped (master=%d dumpOnly=%d adMethods=%d)",
              BDEnabled(), BDDumpOnly(), BDNadPrefsActive(@"BDNadBlockAdMethods"));
        return;
    }

    unsigned walked = 0;
    for (NSString *n in map) {
        Class c = objc_getClass(n.UTF8String);
        if (!c) continue;
        BDWalkMethods(c, n, map[n]);
        walked++;
    }
    BDLog(@"[BDNadBlock] method hooks done, walked %u classes", walked);
}

__attribute__((constructor))
static void BDNadBlockInit(void) {
    // 第一件事：同步建启动快照（dispatch_once）。之后所有 active 读取都走它，
    // 所以后面 BDFRInstallAll / BDSetupNetwork 看到的开关值与日志一致。
    BDNadPrefsInit();
    BDLog(@"[BDNadBlock] loaded (purification-menu: feature hooks + search + menu entry + network); "
           "启动快照已建立，菜单改动只影响下次冷启动");
    // 精准 feature hook 与搜索/入口 hook 都在这里同步装完（不走下面的 1.5s / 3s 定时器）。
    // 只有冷启动、且这里发生在页面组装之前才生效；真机以 [BDNadFeature] installed 日志为准。
    BDFRInstallAll();
    BDPRInstallData();   // 「我的」活动轮播 + 推广整排（bannerSwitch -> NO，钱包行高折叠）
    BDPVInstallAll();    // 「我的」任务卡：两条 -layoutViews post-hook（先布局后隐藏，installer 不做 UI 操作）
    BDRBInstallAll();    // 「去续费」按钮：三条 -vipButton 各自独立安装（默认保留该按钮）
    BDTRInstallAll();     // 底部「库库AI」tab：过滤可见数组 + 四个索引 getter 换算（整组校验）
    BDSRInstallData();   // -[BDPanSearchManager setStaticWordList:] 清搜索框轮播词
    BDSRInstallView();    // BDPanNewMSHSearchView 三条 post-hook（整组校验，不过就三条都不装）
    BDMEInstallAll();     // 设置页导航条「网盘净化」按钮：入口照装，不受总开关/诊断影响
    BDSetupNetwork();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ BDBoot(); });
}
