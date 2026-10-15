// BDNadBlock — 百度网盘广告拦截
//
// 已知事实（来自 13.32.2 IPA 静态分析）：
//   - 广告层类名以 BDNCSplash / BDPanPrologue / BDNCInterstitial /
//     BDNCRewardVideo / BDNCNativeAd / BDPanPersonalBanner 为主
//   - 服务端下发开关：bdnc_feed_ad_switch_*、ad_conf_splash_waterfall
//   - 该包 ObjC 元数据疑似被加固壳剥离，固定类名 hook 可能打不中
//
// 因此这里不硬编码类名，改为运行时遍历 ObjC runtime，
// 匹配广告相关类名 + 方法名后统一短路。命中的类会在 syslog 打日志。

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <string.h>

static BOOL BDEnabled = YES;

// ---------- 匹配规则 ----------

// 类名前缀/片段：命中即认为该类与广告有关
static BOOL BDIsAdClass(const char *name) {
    static const char *frags[] = {
        "SplashAdvertise", "SplashAd", "PrologueAd",
        "InterstitialAd", "RewardVideoAd", "RewardAd",
        "NativeAd", "BannerAd", "AdvertiseWindow",
        "AdvertisesModel", "AdvertiseTask", "AdBaseTask",
        "ADXAd", "BrandAd", "AdTaskQueue", "AdHandler",
        "AppOpenAd", "FlowPlayerAd", "SplashCard",
    };
    if (!name) return NO;
    // 排除明显无关的：SVIP 会员、设置、权限等
    static const char *deny[] = {
        "AdSupport", "AddTo", "Address", "AdapterLoading",
        "AdAutoSearch", "Advanced", "Adaptive", "Adsense",
    };
    for (unsigned i = 0; i < sizeof(deny)/sizeof(deny[0]); i++)
        if (strstr(name, deny[i])) return NO;

    for (unsigned i = 0; i < sizeof(frags)/sizeof(frags[0]); i++)
        if (strstr(name, frags[i])) return YES;
    return NO;
}

// 方法名：这些方法被短路后广告不会展示
static BOOL BDIsAdSelector(const char *sel) {
    static const char *hits[] = {
        "show", "showAd", "showSplashAd", "showWithCompletion",
        "presentAd", "present", "startShow", "startPlay",
        "play", "display", "loadAndShow", "showInterstitial",
        "showPrologueAd", "showSplashCard", "insert", "attach",
    };
    if (!sel) return NO;
    for (unsigned i = 0; i < sizeof(hits)/sizeof(hits[0]); i++) {
        const char *h = hits[i];
        size_t hl = strlen(h);
        if (strncmp(sel, h, hl) == 0) {
            // 精确匹配或以 "xxx:" / "xxxWith..." 形式
            if (sel[hl] == '\0' || sel[hl] == ':' ||
                (hl > 0 && (sel[hl] == 'W' || sel[hl] == 'w'))) {
                // 再排除掉会破坏状态的 getter/setter 类
                if (strncmp(sel, "showAdSize", 10) == 0) return NO;
                if (strncmp(sel, "playType", 8) == 0) return NO;
                return YES;
            }
        }
    }
    return NO;
}

// ---------- 短路实现 ----------

// 返回值走 arm64 的 x0，返回 nil 对任意返回类型都成立
// 必须是 block 字面量，ARC 才允许 imp_implementationWithBlock 转换
static id (^BDNoopBlock)(id, SEL) = ^id(id self_, SEL _cmd) {
    return nil;
};

// ---------- 核心：遍历 runtime 并 hook ----------

static unsigned BDHookedCount = 0;

static void BDHookAllAdClasses(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) {
        NSLog(@"[BDNadBlock] objc_getClassList failed");
        return;
    }
    Class *classes = (Class *)malloc(sizeof(Class) * count);
    count = objc_getClassList(classes, count);

    IMP BDTrampoline = imp_implementationWithBlock(BDNoopBlock);

    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        const char *cname = class_getName(cls);
        if (!BDIsAdClass(cname)) continue;

        unsigned mcount = 0;
        Method *methods = class_copyMethodList(cls, &mcount);
        for (unsigned m = 0; m < mcount; m++) {
            SEL sel = method_getName(methods[m]);
            const char *sname = sel_getName(sel);
            if (!BDIsAdSelector(sname)) continue;

            // 只拦对象方法；类方法不动，避免破坏单例初始化
            if (!class_isMetaClass(cls)) {
                method_setImplementation(methods[m], BDTrampoline);
                NSLog(@"[BDNadBlock] hooked -[%@ %s]", NSStringFromClass(cls), sname);
                BDHookedCount++;
            }
        }
        free(methods);
    }
    free(classes);
    NSLog(@"[BDNadBlock] total hooked: %u", BDHookedCount);
}

// ---------- 视图层兜底：移除已挂载的广告视图 ----------

static BOOL BDLooksLikeAdView(UIView *v) {
    Class c = object_getClass(v);
    const char *n = class_getName(c);
    if (n && (strstr(n, "Ad") || strstr(n, "Splash") || strstr(n, "Banner"))) {
        // 排除纯布局辅助类
        if (!strstr(n, "Adapter") && !strstr(n, "Add") && !strstr(n, "Shadow"))
            return YES;
    }
    return NO;
}

static void BDPurgeAdViewsInView(UIView *root) {
    for (UIView *sub in [root.subviews copy]) {
        if (BDLooksLikeAdView(sub)) {
            NSLog(@"[BDNadBlock] removed ad view: %@", NSStringFromClass(object_getClass(sub)));
            [sub removeFromSuperview];
        } else {
            BDPurgeAdViewsInView(sub);
        }
    }
}

@interface BDPurger : NSObject
+ (void)tick;
@end

@implementation BDPurger
+ (void)tick {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    UIWindow *key = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if (![s isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)s).windows) [windows addObject:w];
            if (((UIWindowScene *)s).keyWindow) key = ((UIWindowScene *)s).keyWindow;
        }
    }
    if (windows.count == 0) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [windows addObjectsFromArray:[UIApplication sharedApplication].windows];
#pragma clang diagnostic pop
    }
    if (!key) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        key = [UIApplication sharedApplication].keyWindow;
#pragma clang diagnostic pop
    }
    if (key && !windows.count) [windows addObject:key];

    for (UIWindow *w in windows) {
        if (!w.hidden) BDPurgeAdViewsInView(w);
    }
}
@end

static void BDEnableViewPurge(void) {
    static NSTimer *t = nil;
    if (t) return;
    t = [NSTimer scheduledTimerWithTimeInterval:1.0
                                         target:[BDPurger class]
                                       selector:@selector(tick)
                                       userInfo:nil
                                        repeats:YES];
}

// ---------- 设置开关（注入后在设置里可关） ----------

static BOOL BDReadBoolFromDefaults(NSString *key, BOOL dflt) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    id v = [d objectForKey:key];
    return v ? [v boolValue] : dflt;
}

__attribute__((constructor))
static void BDNadBlockInit(void) {
    setenv("DYLD_INSERT_LIBRARIES", getenv("DYLD_INSERT_LIBRARIES"), 1);
    NSLog(@"[BDNadBlock] loaded");

    // 稍等主程序起来再扫 runtime
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (BDReadBoolFromDefaults(@"BDNadBlockEnabled", YES)) {
            BDHookAllAdClasses();
            BDEnableViewPurge();
        }
        __block id token = nil;
        token = [[NSNotificationCenter defaultCenter]
                 addObserverForName:UIApplicationDidBecomeActiveNotification
                             object:nil
                              queue:[NSOperationQueue mainQueue]
                         usingBlock:^(NSNotification *n) {
            if (BDReadBoolFromDefaults(@"BDNadBlockEnabled", YES))
                [BDPurger tick];
        }];
        (void)token;
    });
}