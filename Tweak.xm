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

#pragma mark - 日志

static NSMutableString *BDLogBuffer;
static NSString *BDLogPath;
static dispatch_queue_t BDLogQueue;
static BOOL BDLogFileEnabled = NO;   // app ready 之后才开

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
    // （dyld 镜像初始化）就被调用，那时碰 Foundation 的目录服务是自找麻烦。
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

#pragma mark - 开关

static BOOL BDDefault(NSString *key, BOOL fallback) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    return v ? [v boolValue] : fallback;
}

static BOOL BDEnabled(void)       { return BDDefault(@"BDNadBlockEnabled", YES); }
static BOOL BDDumpOnly(void)      { return BDDefault(@"BDNadBlockDumpOnly", NO); }
static BOOL BDBlockNetwork(void)  { return BDDefault(@"BDNadBlockNetwork", YES); }
static BOOL BDRemoveRecommend(void)  { return BDDefault(@"BDRemoveRecommend", YES); }
static BOOL BDRemoveGameCenter(void) { return BDDefault(@"BDRemoveGameCenter", YES); }

// 精准 feature hook（3 个：首页推荐/创意整块 + 我的页游戏中心）。
// 放在开关之后 include：它依赖上面的 BDLog / BDEnabled / BDDumpOnly / BDRemove*。
#include "FeatureRemoval.h"

#pragma mark - 网络拦截规则（全部经抓包响应体证实）

// 整个 host 都是广告链路
static const char *BDHostRules[] = {
    // 趣盟广告 SDK
    "cpc-service-square.yunxish.com",
    "cpc-service-square.iggrowth.cn",
    "logrcv.yunxish.com",
    "show-api.yunxish.com",
    "usr-api.yunxish.com",
    "service.yunxish.com",
    "tracelog-debug.yunxish.com",
    // 百度自有：广告开关 / 点击归因 / 营销云
    "afdconf.baidu.com",
    "nsclick.baidu.com",
    "sofire.baidu.com",
    "huiduapi.nuomi.com",
    // 第三方联盟
    "ef-dongfeng.tanx.com",
    "tnc3-alisc1.zijieapi.com",
    "mssdk.volces.com",
    // 当贝 / 酷开 广告 SDK（logu.hpplay.cn:8856 的 host 相同，一条覆盖）
    "conf.hpplay.cn",
    "vfa.hpplay.cn",
    "ssdkauth.hpplay.cn",
    "logu.hpplay.cn",
};

// host + 路径前缀
typedef struct { const char *host; const char *path; const char *tag; } BDPathRule;
static const BDPathRule BDPathRules[] = {
    // 首页 banner 广告。响应实测：adList[0].title="双十一上淘宝"，
    // actionUrl=https://ulk.alimama.com/tb?...（淘宝联盟）
    {"pan.baidu.com", "/buy/ad/",          "ad-banner"},
    // 激励任务广告。响应实测：scene_list[].task_list[].complete_notice
    // ="恭喜获得1次音频倍速播放机会"
    {"pan.baidu.com", "/rest/2.0/pcs/adv", "ad-task"},
};

// 只看路径、不看 host：这批素材会走 P2P 加速镜像，
// host 每台设备都不一样（antpcdn.com:19001 / jomoxc.com:9082 / yingt.asia:9549），
// 拦 host 会连静态资源一起打死，所以只能按路径判。
static const char *BDAnyPathRules[] = {
    "/gamecenter/",    // ndstatic.cdn.bcebos.com 的 gameCenter 目录
    "_swan-game_",     // spcsz.cdn.bcebos.com 的 cmpkg 里的 swan 游戏包
    // 注意不要拦 cmpkg 整目录或 1_swan-core —— 那是小程序运行时
};

static NSString *BDMatchNetwork(NSString *host, NSString *path) {
    if (!host.length || !BDBlockNetwork()) return nil;
    host = host.lowercaseString;
    NSString *lp = path.lowercaseString ?: @"";

    for (unsigned i = 0; i < sizeof(BDHostRules)/sizeof(BDHostRules[0]); i++)
        if ([host isEqualToString:@(BDHostRules[i])]) return @"ad-host";

    for (unsigned i = 0; i < sizeof(BDPathRules)/sizeof(BDPathRules[0]); i++)
        if ([host isEqualToString:@(BDPathRules[i].host)] &&
            [lp hasPrefix:@(BDPathRules[i].path)])
            return @(BDPathRules[i].tag);

    if ([host isEqualToString:@"pan.baidu.com"] &&
        [lp hasPrefix:@"/act/v2/gamecenter"])
        return BDRemoveGameCenter() ? @"game-center-api" : nil;

    if (BDRemoveGameCenter())
        for (unsigned i = 0; i < sizeof(BDAnyPathRules)/sizeof(BDAnyPathRules[0]); i++)
            if ([lp containsString:@(BDAnyPathRules[i])]) return @"game-center-asset";

    // 搜索框底部推荐词（实测返回 6 条 show_query）+ 记忆中心推荐卡片
    if (BDRemoveRecommend() && [host isEqualToString:@"pan.baidu.com"] &&
        ([lp hasPrefix:@"/recommend/"] ||
         [lp hasPrefix:@"/aisearch/agent/memorycenter/getrecommendcards"]))
        return @"recommend-api";

    return nil;
}

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
    BDLog(@"[BDNadBlock] switches enabled=%d dumpOnly=%d network=%d recommend=%d gameCenter=%d",
          BDEnabled(), BDDumpOnly(), BDBlockNetwork(), BDRemoveRecommend(), BDRemoveGameCenter());
    NSDictionary *map = BDHookMap();
    unsigned dumped = 0, missing = 0;

    for (NSString *n in map) {
        Class c = objc_getClass(n.UTF8String);
        if (!c) { BDLog(@"[BDNadBlock] class missing: %@", n); missing++; continue; }
        BDDumpClass(c);
        dumped++;
    }
    BDLog(@"[BDNadBlock] dumped %u classes, %u missing", dumped, missing);

    if (BDDumpOnly() || !BDEnabled()) {
        BDLog(@"[BDNadBlock] dump-only, no method hooks applied");
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
    BDLog(@"[BDNadBlock] loaded (network + recommend/game-center removal)");
    // 精准 feature hook 在这里同步装完（不走下面的 1.5s / 3s 定时器）。
    // 只有冷启动、且这里发生在页面组装之前才生效；真机以 [BDNadFeature] installed 日志为准。
    BDFRInstallAll();
    BDSetupNetwork();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ BDBoot(); });
}
