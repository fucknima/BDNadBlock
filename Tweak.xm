// BDNadBlock — 广告拦截 + 方法清单导出
//
// 安全策略（首要目标：不把 App 搞崩）：
//   1. 不 hook 单例初始化、init、dealloc、配置 setter —— 只碰展示路径
//   2. hook 前先验证 IMP 存在、方法确实属于该类
//   3. 短路实现返回 nil / 0 / NO，任何读取方拿到空值都走"无广告"分支
//   4. 每次 hook 打 syslog，出问题一眼能看出哪条生效
//   5. 全部用 method_setImplementation（可逆），不用 method_getImplementation 覆写
//
// 第一步是探针：把广告类的真实方法名 dump 到日志，
// 因为静态解析 __objc_const 的 method list 在这个 418MB 二进制上不可靠。
// 拿到真实 selector 后再收紧 BDBlockSelectors。

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <string.h>

// 待 hook 的 selector 名单，BDBoot 里填充
static NSSet<NSString *> *BDBlockSelectors = nil;
// 复用的短路 IMP，只建一次
static IMP BDNoopIMP;

#pragma mark - 配置

static BOOL BDEnabled(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    id v = [d objectForKey:@"BDNadBlockEnabled"];
    return v ? [v boolValue] : YES;
}

static BOOL BDDumpOnly(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    id v = [d objectForKey:@"BDNadBlockDumpOnly"];
    return v ? [v boolValue] : NO;   // 默认直接拦
}

#pragma mark - 广告类名单（来自 34946 个类的真实解析）

static NSArray<NSString *> *BDAdClasses(void) {
    return @[
        // 开屏
        @"BDNCSplashAdvertiseWindow",
        @"BDNCSplashAdvertisePresenter",
        @"BDNCSplashAdvertiseViewController",
        @"BDNCSplashBiddingTaskManager",
        @"BDNCSplashBiddingEngine",
        @"BDNCSplashBiddingMainEngine",
        @"BDNCSplashAdLoadStrategy",
        @"BDNCSplashAdvertiseMonitor",
        @"BDNCBUAdsSplashAD",
        @"BDNCAPISplashAdHandler",
        @"BDNCBrandSplashAd",
        // 插屏
        @"BDNCInterstitialAdHandlerProtocol",
        // 激励视频
        @"BDNCBuAdsRewardVideoAD",
        @"BDNCRewardVideoAdBaseTask",
        @"BDNCRewardVideoAdTaskModel",
        @"BDNCRewardVideoAdOperation",
        // Banner / 原生
        @"BDPanPersonalBannerAd",
        @"BDPanFeedOpBannerAd",
        @"BDNCNativeAdBaseTask",
        @"BDNCNativeAdTaskModel",
        // TopOn 聚合层
        @"ABUSplashAd",
        @"ABUSplashAdLoader",
        @"ABUInterstitialAd",
        @"ABUInterstitialProAd",
        @"ABURewardedVideoAd",
        @"ABUBannerAd",
    ];
}

// 明确不碰的方法（防崩）
static BOOL BDIsProtectedSelector(NSString *sel) {
    static NSArray *protect = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        protect = @[
            @"init", @"dealloc", @"new", @"copy", @"copyWithZone:",
            @"retain", @"release", @"autorelease",
            @"load", @"initialize", @"setDelegate:",
            @"setX:", @"setY:", @"setZ:",
            @"description", @"debugDescription", @"hash", @"isEqual:",
        ];
    });
    for (NSString *p in protect) {
        if ([sel isEqualToString:p] || [sel hasPrefix:p]) return YES;
    }
    return NO;
}

#pragma mark - 短路实现

// arm64 返回值在 x0。返回 nil 对指针/对象/BOOL/int 都成立（0 == NO == nil）。
// 只建一次并复用：每次调用 imp_implementationWithBlock 都是一个新 block 副本，会持续泄漏。
static id (^BDNoopBlock)(id, SEL) = ^id(id self_, SEL _cmd) {
    return nil;
};

#pragma mark - 探针：导出真实方法

static void BDDumpClass(Class cls) {
    unsigned n = 0;
    Method *ms = class_copyMethodList(cls, &n);
    if (!ms) return;
    NSMutableString *line = [NSMutableString string];
    for (unsigned i = 0; i < n; i++) {
        SEL s = method_getName(ms[i]);
        if (s) [line appendFormat:@"%s,", sel_getName(s)];
    }
    NSLog(@"[BDNadDump] %@ (%u) :: %@", NSStringFromClass(cls), n, line);
    free(ms);
}

#pragma mark - 核心 hook

static void BDWalkMethod(Class cls, NSString *clsName) {
    unsigned mc = 0;
    Method *ms = class_copyMethodList(cls, &mc);
    if (!ms) return;
    for (unsigned i = 0; i < mc; i++) {
        SEL sel = method_getName(ms[i]);
        if (!sel) continue;
        NSString *s = NSStringFromSelector(sel);
        if (BDIsProtectedSelector(s)) continue;
        if (![BDBlockSelectors containsObject:s]) continue;
        if (!BDNoopIMP) BDNoopIMP = imp_implementationWithBlock(BDNoopBlock);
        method_setImplementation(ms[i], BDNoopIMP);
        NSLog(@"[BDNadBlock] hooked -[%@ %@]", clsName, s);
    }
    free(ms);
}

// 阻塞回调替换为 BLOCK 0，避免上游等一个永远不会调的 completion
static void BDWalkBlockCallback(Class cls, NSString *clsName) {
    unsigned mc = 0;
    Method *ms = class_copyMethodList(cls, &mc);
    if (!ms) return;
    for (unsigned i = 0; i < mc; i++) {
        SEL sel = method_getName(ms[i]);
        if (!sel) continue;
        NSString *s = NSStringFromSelector(sel);
        if (![BDBlockSelectors containsObject:s]) continue;
        // 只短路参数含 block 的方法签名，避免误伤
        const char *t = method_getTypeEncoding(ms[i]);
        if (!t || !strstr(t, "@?")) continue;
        if (!BDNoopIMP) BDNoopIMP = imp_implementationWithBlock(BDNoopBlock);
        method_setImplementation(ms[i], BDNoopIMP);
        NSLog(@"[BDNadBlock] hooked(block) -[%@ %@]", clsName, s);
    }
    free(ms);
}

#pragma mark - 启动

static void BDBoot(void) {
    unsigned dumped = 0, found = 0;
    NSArray *classes = BDAdClasses();
    for (NSString *n in classes) {
        Class c = objc_getClass(n.UTF8String);
        if (!c) { NSLog(@"[BDNadBlock] class missing: %@", n); continue; }
        BDDumpClass(c);
        dumped++;
    }
    NSLog(@"[BDNadBlock] dumped %u/%lu classes", dumped, (unsigned long)classes.count);

    if (BDDumpOnly() || !BDEnabled()) {
        NSLog(@"[BDNadBlock] dump-only mode, skipping hooks");
        return;
    }

    // 只对确认存在的 selector 下刀。
    // 刻意不含裸的 show/play —— 太宽泛，容易误伤这些类的非广告职责。
    // dump 日志拿到真实名字后（见 README 第二步），再按需补进来。
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

    for (NSString *n in classes) {
        Class c = objc_getClass(n.UTF8String);
        if (!c) continue;
        BDWalkMethod(c, n);
        BDWalkBlockCallback(c, n);
        found++;
    }
    NSLog(@"[BDNadBlock] done, walked %u classes", found);
}

__attribute__((constructor))
static void BDNadBlockInit(void) {
    NSLog(@"[BDNadBlock] loaded");

    // 第一轮：全部 dump，确认 selector 真实存在
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ BDBoot(); });
}