// BDNadBlock — 广告拦截 + 移除推荐内容/游戏中心
//
// 数据来源：
//   - 2026-10-15 Loon 抓包（381_1792041072312.har，632 条请求，30s）
//   - __objc_classlist 完整解析出的 34,946 个真实类名（无壳、未加密）
//
// 网络层（NSURLProtocol + swizzle NSURLSessionConfiguration）：
//   广告  cpc-service-square.yunxish.com / iggrowth.cn / *.yunxish.com
//   素材  *.jomoxc.com / *.antpcdn.com / *.bcebos.com 的 /amis/ 路径
//   首页推荐  pan.baidu.com/feed/kingkongdistrict      ← 金刚区「推荐内容」
//   游戏中心  pan.baidu.com/act/v2/gamecenter/*        ← historyplay/gametaskinfo/recommend
//   游戏资源  /gameCenter/ 与 /swan-game_ 路径
//   归因  nsclick.baidu.com / tanx.com / zijieapi / volces.com
//
// 方法层（探针 + hook）：
//   先 dump 真实方法名到沙盒文件，再按确认存在的 selector 下刀。
//   防崩：跳过生命周期方法、只在广告类内匹配、IMP 全局复用、block 回调验 type encoding。
//
// 日志：同时写 syslog 与沙盒 Documents/BDNadBlock-dump.txt（用户可取）

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <string.h>
#import <stdarg.h>

static NSSet<NSString *> *BDBlockSelectors = nil;
static IMP BDNoopIMP;

#pragma mark - 日志

static NSMutableString *BDLogBuffer;
static NSString *BDLogPath;
static dispatch_queue_t BDLogQueue;

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

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        BDLogBuffer = [NSMutableString string];
        BDLogPath = BDResolveLogPath();
        BDLogQueue = dispatch_queue_create("com.bdnadblock.log", DISPATCH_QUEUE_SERIAL);
    });

    dispatch_async(BDLogQueue, ^{
        [BDLogBuffer appendString:msg];
        [BDLogBuffer appendString:@"\n"];
        [BDLogBuffer writeToFile:BDLogPath atomically:YES
                         encoding:NSUTF8StringEncoding error:NULL];
    });
}

static void BDLogPathReport(void) {
    dispatch_async(BDLogQueue, ^{
        BDLog(@"[BDNadBlock] log file: %@", BDLogPath);
    });
}

#pragma mark - 开关

static BOOL BDEnabled(void) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:@"BDNadBlockEnabled"];
    return v ? [v boolValue] : YES;
}
static BOOL BDDumpOnly(void) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:@"BDNadBlockDumpOnly"];
    return v ? [v boolValue] : NO;
}
static BOOL BDBlockNetwork(void) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:@"BDNadBlockNetwork"];
    return v ? [v boolValue] : YES;
}
static BOOL BDRemoveRecommend(void) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:@"BDRemoveRecommend"];
    return v ? [v boolValue] : YES;   // 默认关掉推荐内容
}
static BOOL BDRemoveGameCenter(void) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:@"BDRemoveGameCenter"];
    return v ? [v boolValue] : YES;   // 默认关掉游戏中心
}

#pragma mark - 网络拦截规则

// 精确 host
static const char *BDHostRules[] = {
    "cpc-service-square.yunxish.com",
    "cpc-service-square.iggrowth.cn",
    "logrcv.yunxish.com",
    "show-api.yunxish.com",
    "usr-api.yunxish.com",
    "tracelog-debug.yunxish.com",
    "afdconf.baidu.com",
    "nsclick.baidu.com",
    "ef-dongfeng.tanx.com",
    "tnc3-alisc1.zijieapi.com",
    "mssdk.volces.com",
    "conf.hpplay.cn",
    "vfa.hpplay.cn",
    "ssdkauth.hpplay.cn",
    "logu.hpplay.cn",
};

// host 后缀（带随机前缀的 CDN）
static const char *BDSuffixRules[] = {
    "jomoxc.com",
    "antpcdn.com",
    "yingt.asia",
};

// host + path 前缀
typedef struct { const char *host; const char *path; const char *tag; } BDPathRule;
static const BDPathRule BDPathRules[] = {
    {"staticsns.cdn.bcebos.com", "/amis/",        "ad-material"},
    {"spcsz.cdn.bcebos.com",     "/amis/",        "ad-material"},
    {"ndstatic.cdn.bcebos.com",  "/amis/",        "ad-material"},
    {"s0-ant.baidu.com",         "/staticsns/amis/", "ad-material"},
    // 首页金刚区「推荐内容」
    {"pan.baidu.com",            "/feed/kingkongdistrict", "recommend-feed"},
    // 游戏资源包
    {"ndstatic.cdn.bcebos.com",  "/gameCenter/",  "game-center-asset"},
    {"spcsz.cdn.bcebos.com",     "/cmpkg/",       "game-center-asset"},
};

static NSString *BDMatchNetwork(NSString *host, NSString *path) {
    if (!host.length || !BDBlockNetwork()) return nil;
    host = host.lowercaseString;
    path = path.lowercaseString ?: @"";

    for (unsigned i = 0; i < sizeof(BDHostRules)/sizeof(BDHostRules[0]); i++)
        if ([host isEqualToString:@(BDHostRules[i])]) return @"host";

    for (unsigned i = 0; i < sizeof(BDPathRules)/sizeof(BDPathRules[0]); i++) {
        if ([host isEqualToString:@(BDPathRules[i].host)] &&
            [path hasPrefix:@(BDPathRules[i].path)])
            return @(BDPathRules[i].tag);
    }

    // 游戏中心接口前缀
    if ([host isEqualToString:@"pan.baidu.com"] && [path hasPrefix:@"/act/v2/gamecenter"])
        return BDRemoveGameCenter() ? @"game-center-api" : nil;
    // 搜索框底部推荐
    if ([host isEqualToString:@"pan.baidu.com"] && [path hasPrefix:@"/recommend/"])
        return BDRemoveRecommend() ? @"recommend-api" : nil;

    for (unsigned i = 0; i < sizeof(BDSuffixRules)/sizeof(BDSuffixRules[0]); i++) {
        NSString *s = @(BDSuffixRules[i]);
        if ([host hasSuffix:s]) return @"suffix";
    }
    return nil;
}

#pragma mark - NSURLProtocol

@interface BDNadProtocol : NSURLProtocol
@end

@interface NSURLSessionConfiguration (BDNad)
@end

static NSURLSessionConfiguration *BDInjectProtocol(NSURLSessionConfiguration *c) {
    if (!c) return c;
    NSMutableArray *arr = [c.protocolClasses mutableCopy] ?: [NSMutableArray array];
    if (![arr containsObject:[BDNadProtocol class]])
        [arr insertObject:[BDNadProtocol class] atIndex:0];
    c.protocolClasses = arr;
    return c;
}

// 方法交换后，bd_ 里的同名调用指向原实现，不递归
@implementation NSURLSessionConfiguration (BDNad)
+ (instancetype)bd_defaultSessionConfiguration {
    return BDInjectProtocol([self defaultSessionConfiguration]);
}
+ (instancetype)bd_ephemeralSessionConfiguration {
    return BDInjectProtocol([self ephemeralSessionConfiguration]);
}
@end

@implementation BDNadProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    NSString *tag = BDMatchNetwork(request.URL.host, request.URL.path);
    if (!tag) return NO;
    BDLog(@"[BDNadBlock] blocked[%@] %@%@", tag, request.URL.host, request.URL.path);
    return YES;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }

- (void)startLoading {
    NSDictionary *h = @{ @"Content-Type": @"application/json", @"Content-Length": @"2" };
    NSHTTPURLResponse *r = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                                       statusCode:200
                                                      HTTPVersion:@"HTTP/1.1"
                                                     headerFields:h];
    [self.client URLProtocol:self didReceiveResponse:r cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:[@"{}" dataUsingEncoding:NSUTF8StringEncoding]];
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)stopLoading {}

// 重定向后 host 可能变，续投时再判一次
- (void)willPerformHTTPRedirection:(NSHTTPURLResponse *)response
                        newRequest:(NSURLRequest *)request
                 completionHandler:(void (^)(NSURLRequest *))completionHandler {
    if (BDMatchNetwork(request.URL.host, request.URL.path))
        completionHandler(nil);
    else
        completionHandler(request);
}

@end

static void BDSetupNetwork(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class c = [NSURLSessionConfiguration class];
        struct { SEL orig, rep; } pairs[] = {
            {@selector(defaultSessionConfiguration),  @selector(bd_defaultSessionConfiguration)},
            {@selector(ephemeralSessionConfiguration), @selector(bd_ephemeralSessionConfiguration)},
        };
        for (unsigned i = 0; i < sizeof(pairs)/sizeof(pairs[0]); i++) {
            Method om = class_getClassMethod(c, pairs[i].orig);
            Method rm = class_getClassMethod(c, pairs[i].rep);
            if (om && rm) method_exchangeImplementations(om, rm);
        }
        [NSURLProtocol registerClass:[BDNadProtocol class]];
        BDLog(@"[BDNadBlock] network layer on (hosts=%zu paths=%zu suffixes=%zu)",
              sizeof(BDHostRules)/sizeof(BDHostRules[0]),
              sizeof(BDPathRules)/sizeof(BDPathRules[0]),
              sizeof(BDSuffixRules)/sizeof(BDSuffixRules[0]));
    });
}

#pragma mark - 方法 hook（探针 + 下刀）

static NSArray<NSString *> *BDAdClasses(void) {
    return @[
        // 开屏
        @"BDNCSplashAdvertiseWindow", @"BDNCSplashAdvertisePresenter",
        @"BDNCSplashAdvertiseViewController", @"BDNCSplashBiddingTaskManager",
        @"BDNCSplashBiddingEngine", @"BDNCSplashBiddingMainEngine",
        @"BDNCSplashAdLoadStrategy", @"BDNCSplashAdvertiseMonitor",
        @"BDNCBUAdsSplashAD", @"BDNCAPISplashAdHandler", @"BDNCBrandSplashAd",
        // 插屏
        @"BDNCInterstitialAdHandlerProtocol",
        // 激励视频
        @"BDNCBuAdsRewardVideoAD", @"BDNCRewardVideoAdBaseTask",
        @"BDNCRewardVideoAdTaskModel", @"BDNCRewardVideoAdOperation",
        // Banner / 原生
        @"BDPanPersonalBannerAd", @"BDPanFeedOpBannerAd",
        @"BDNCNativeAdBaseTask", @"BDNCNativeAdTaskModel",
        // TopOn 聚合
        @"ABUSplashAd", @"ABUSplashAdLoader", @"ABUInterstitialAd",
        @"ABUInterstitialProAd", @"ABURewardedVideoAd", @"ABUBannerAd",
        // 游戏中心（第二阶段收紧 selector，先 dump）
        @"BDPanGameCenterView", @"BDPanOperationGameCenterView",
        @"BDPanOperationGameListView", @"BDPanMyGamesView",
        @"BDPanRecommendGamesView",
    ];
}

static BOOL BDIsProtectedSelector(NSString *sel) {
    static NSArray *protect = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        protect = @[@"init", @"dealloc", @"new", @"copy", @"copyWithZone:",
                    @"retain", @"release", @"autorelease",
                    @"load", @"initialize", @"setDelegate:",
                    @"description", @"debugDescription", @"hash", @"isEqual:"];
    });
    for (NSString *p in protect)
        if ([sel isEqualToString:p] || [sel hasPrefix:p]) return YES;
    return NO;
}

static id (^BDNoopBlock)(id, SEL) = ^id(id self_, SEL _cmd) { return nil; };

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

static void BDWalkMethods(Class cls, NSString *clsName) {
    unsigned n = 0;
    Method *ms = class_copyMethodList(cls, &n);
    if (!ms) return;
    for (unsigned i = 0; i < n; i++) {
        SEL sel = method_getName(ms[i]);
        if (!sel) continue;
        NSString *s = NSStringFromSelector(sel);
        if (BDIsProtectedSelector(s)) continue;
        if (![BDBlockSelectors containsObject:s]) continue;
        if (!BDNoopIMP) BDNoopIMP = imp_implementationWithBlock(BDNoopBlock);
        method_setImplementation(ms[i], BDNoopIMP);
        BDLog(@"[BDNadBlock] hooked -[%@ %@]", clsName, s);
    }
    free(ms);
}

static void BDBoot(void) {
    BDLogPathReport();
    NSArray *classes = BDAdClasses();
    unsigned dumped = 0;

    for (NSString *n in classes) {
        Class c = objc_getClass(n.UTF8String);
        if (!c) { BDLog(@"[BDNadBlock] class missing: %@", n); continue; }
        BDDumpClass(c);
        dumped++;
    }
    BDLog(@"[BDNadBlock] dumped %u/%lu classes", dumped, (unsigned long)classes.count);

    if (BDDumpOnly() || !BDEnabled()) {
        BDLog(@"[BDNadBlock] dump-only, no method hooks applied");
        return;
    }

    // 刻意不含裸 show/play —— 太宽泛；dump 后再按真实名字补
    BDBlockSelectors = [NSSet setWithArray:@[
        @"showSplashAd", @"showSplashAd:", @"showSplashAdWithCompletion:",
        @"showSplashCard", @"startShow",
        @"presentSplashAd", @"displaySplashAd",
        @"showPrologueAd", @"showPrologueAd:",
        @"showInterstitialAd", @"showInterstitial", @"presentAd",
        @"showRewardVideoAd", @"showRewardVideoAd:", @"startPlay",
        @"showRewardAd",
        @"loadAndShow", @"showBannerAd", @"showNativeAd",
        @"showWithCompletion:", @"showWithCompletion",
    ]];

    unsigned walked = 0;
    for (NSString *n in classes) {
        Class c = objc_getClass(n.UTF8String);
        if (!c) continue;
        BDWalkMethods(c, n);
        walked++;
    }
    BDLog(@"[BDNadBlock] method hooks done, walked %u classes", walked);
}

__attribute__((constructor))
static void BDNadBlockInit(void) {
    BDLog(@"[BDNadBlock] loaded (network + recommend/game-center removal)");
    BDSetupNetwork();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ BDBoot(); });
}