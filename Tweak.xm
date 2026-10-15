// BDNadBlock — 网络层广告拦截
//
// 依据 2026-10-15 Loon 抓包（381_1792041072312.har，632 条请求，30s 窗口）：
//   cpc-service-square.yunxish.com   /v1/getConfig   趣盟 CPC 广告配置
//   cpc-service-square.iggrowth.cn   /v1/getConfig   同上，备用域
//   *.yunxish.com                     /report/v1      趣盟曝光/点击上报
//   afdconf.baidu.com                 /afd/platform   开屏 NAD 开关（nad_*）
//   *.jomoxc.com:9082                 百度个性化广告素材 zip
//   *.antpcdn.com                     百度联盟广告素材
//   conf.hpplay.cn                    投屏配置，含 csj_ad_switch（穿山甲）
//
// 原理：注册 NSURLProtocol 子类，在请求发出前按 host 判定。
// 命中则 canInitWithRequest: 返回 YES（截流），startLoading 直接给一个空成功响应。
// 覆盖 NSURLSession / AFNetworking；不覆盖 QUIC、Tquic、自研 socket。
//
// 已知限制见 README。

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>

#pragma mark - 拦截名单

typedef struct { const char *host; const char *tag; } BDRule;

static const BDRule BDRules[] = {
    // 趣盟 CPC 广告
    {"cpc-service-square.yunxish.com", "qumeng-config"},
    {"cpc-service-square.iggrowth.cn", "qumeng-config-backup"},
    {"logrcv.yunxish.com",             "qumeng-logrcv"},
    {"show-api.yunxish.com",           "qumeng-show"},
    {"usr-api.yunxish.com",            "qumeng-report"},
    {"tracelog-debug.yunxish.com",     "qumeng-trace"},
    // 开屏 NAD 开关下发
    {"afdconf.baidu.com",              "splash-nad-config"},
    // 百度个性化广告素材走 BDPathRules（按 /amis/ 路径拦，不整域）
    // 归因 / 监测（可选，默认一并断掉）
    {"nsclick.baidu.com",              "click-track"},
    {"ef-dongfeng.tanx.com",           "tanx-track"},
    {"tnc3-alisc1.zijieapi.com",       "pangle-dns"},
    // 火山引擎上报（穿山甲/头条系）
    {"mssdk.volces.com",               "volc-report"},
    // 投屏 SDK 的穿山甲开关
    {"conf.hpplay.cn",                 "hpplay-csj-switch"},
    {"vfa.hpplay.cn",                  "hpplay-vipauth"},
    {"ssdkauth.hpplay.cn",             "hpplay-auth"},
    {"logu.hpplay.cn",                 "hpplay-log"},
};

static const unsigned BDRuleCount = sizeof(BDRules) / sizeof(BDRules[0]);

// 动态后缀（jomoxc 的 host 每次会话带随机前缀，形如 d4bcfee4...-64be1fd886d9b94b.jomoxc.com）
// 注意：不拦 bdstatic.com / bcebos.com 全域，它们同时承载正常静态资源，
// 只按路径拦（见 BDMatchesPath）。
static const char *BDSuffixRules[] = {
    "jomoxc.com",
    "antpcdn.com",
    "yingt.asia",
};
static const unsigned BDSuffixCount = sizeof(BDSuffixRules) / sizeof(BDSuffixRules[0]);

// 按路径拦的规则：host 正常，但只有 /amis/ 这类广告目录要断
typedef struct { const char *host; const char *pathPrefix; const char *tag; } BDPathRule;

static const BDPathRule BDPathRules[] = {
    {"staticsns.cdn.bcebos.com", "/amis/",     "baidu-ad-material"},
    {"spcsz.cdn.bcebos.com",     "/amis/",     "baidu-ad-material"},
    {"s0-ant.baidu.com",         "/staticsns/amis/", "baidu-ad-material"},
    {"ndstatic.cdn.bcebos.com",  "/amis/",     "baidu-ad-material"},
};
static const unsigned BDPathRuleCount = sizeof(BDPathRules) / sizeof(BDPathRules[0]);

// 注意：/amis/ 目录里既有广告也有正常运营位（如 novel_inter_ad_force_cover
// 是插屏遮罩，但同目录也有 aiapps_default_banner 之类的功能图）。
// 这里按前缀粗拦，如需精细化见 README。

#pragma mark - 匹配

static NSString *BDMatchHost(NSString *host, NSString *path) {
    if (!host.length) return nil;
    host = host.lowercaseString;
    path = path.lowercaseString ?: @"";

    // 1. 精确 host
    for (unsigned i = 0; i < BDRuleCount; i++) {
        if ([host isEqualToString:@(BDRules[i].host)])
            return @(BDRules[i].tag);
    }
    // 2. host + path 前缀
    for (unsigned i = 0; i < BDPathRuleCount; i++) {
        if ([host isEqualToString:@(BDPathRules[i].host)] &&
            [path hasPrefix:@(BDPathRules[i].pathPrefix)])
            return @(BDPathRules[i].tag);
    }
    // 3. 动态后缀（host 每次会话带随机前缀）
    for (unsigned i = 0; i < BDSuffixCount; i++) {
        NSString *s = @(BDSuffixRules[i]);
        if ([host hasSuffix:s] || [host containsString:[@"." stringByAppendingString:s]])
            return [@"suffix:" stringByAppendingString:s];
    }
    return nil;
}

#pragma mark - NSURLProtocol

@interface BDNadProtocol : NSURLProtocol
@end

// NSURLSession 只在 configuration.protocolClasses 里带协议类时才走我们的截流，
// 裸的 registerClass: 对它无效 —— 所以 swizzle configuration 的 getter，追加自己。
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

// 方法交换后，bd_ 里的 defaultSessionConfiguration 调用已指向原实现，
// 这是标准 trick，不递归。
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
    NSString *host = request.URL.host;
    NSString *tag = BDMatchHost(host, request.URL.path);
    if (!tag) return NO;
    NSLog(@"[BDNadBlock] blocked [%@] %@%@", tag, host, request.URL.path);
    return YES;
}

+ (BOOL)canInitWithTask:(NSURLSessionTask *)task {
    if (task.state == NSURLSessionTaskStateCompleted) return NO;
    NSURLRequest *r = task.originalRequest ?: task.currentRequest;
    if (!r) return NO;
    return [self canInitWithRequest:r];
}

// 重定向后 host 可能变，续投时再判一次
- (void)willPerformHTTPRedirection:(NSHTTPURLResponse *)response
                        newRequest:(NSURLRequest *)request
                 completionHandler:(void (^)(NSURLRequest *))completionHandler {
    if (BDMatchHost(request.URL.host, request.URL.path))
        completionHandler(nil);          // 掐断跳转，不去广告域
    else
        completionHandler(request);
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    // 返回 200 + 空体，让调用方走成功分支而不会崩在 nil 上
    NSDictionary *h = @{
        @"Content-Type": @"application/json",
        @"Content-Length": @"2",
    };
    NSHTTPURLResponse *r = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                                         statusCode:200
                                                        HTTPVersion:@"HTTP/1.1"
                                                       headerFields:h];
    [self.client URLProtocol:self didReceiveResponse:r cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:[@"{}" dataUsingEncoding:NSUTF8StringEncoding]];
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)stopLoading {}

@end

#pragma mark - 注册

static BOOL BDEnabled(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    id v = [d objectForKey:@"BDNadBlockEnabled"];
    return v ? [v boolValue] : YES;
}

static void BDRegisterProtocol(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [NSURLProtocol registerClass:[BDNadProtocol class]];
        NSLog(@"[BDNadBlock] NSURLProtocol registered (rules=%u+%u+%u)",
              BDRuleCount, BDSuffixCount, BDPathRuleCount);
    });
}

static void BDSwizzleSessionConfig(void) {
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
        NSLog(@"[BDNadBlock] NSURLSessionConfiguration swizzled");
    });
}

__attribute__((constructor))
static void BDNadBlockInit(void) {
    NSLog(@"[BDNadBlock] loaded (network layer)");
    BDSwizzleSessionConfig();
    BDRegisterProtocol();
    // 兜底：某些 SDK 在 +load 之后才建 session，再注册一次
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ BDRegisterProtocol(); });
}