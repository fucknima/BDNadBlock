// tests/network_rules_test.mm — NetworkRules.h 的 macOS host 回归测试
//
// 直接 include 真身 matcher（不抄算法），开关用内存假函数：
// 不碰 NSUserDefaults、不注册 NSURLProtocol、不发任何请求。
//
// 这不是真机测试：证明的是「规则命中 / 不命中 / 开关组合」，
// 不证明 NSURLProtocol 拦截真的在进程里生效（那需要真机或模拟器）。
//
// 构建运行（macOS，无需 IPA，无需 Theos）：
//   clang++ -std=c++17 -fobjc-arc -fblocks -Wall -Wextra -Werror \
//     -framework Foundation -o /tmp/network_rules_test tests/network_rules_test.mm
//   /tmp/network_rules_test

#import <Foundation/Foundation.h>
#include <stdio.h>

#pragma mark - 内存假开关（NetworkRules.h 依赖这些同名静态函数）

static BOOL gMaster = YES;         // 总开关
static BOOL gDumpOnly = NO;        // 仅诊断
static BOOL gNetwork = YES;        // 旧网络规则
static BOOL gRecommend = YES;      // 记忆中心推荐卡片
static BOOL gSearchPromo = YES;    // 搜索框底部推广词
static BOOL gGameCenter = YES;     // 游戏中心

static BOOL BDEnabled(void)           { return gMaster; }
static BOOL BDDumpOnly(void)          { return gDumpOnly; }
static BOOL BDRemoveRecommend(void)   { return gRecommend; }
static BOOL BDRemoveSearchPromo(void) { return gSearchPromo; }
static BOOL BDRemoveGameCenter(void)  { return gGameCenter; }

// 与 Tweak.xm 里的组合保持一致：总开关 + 诊断 + 网络开关，任一不满足都不拦。
// （BDEnabled/BDDumpOnly 只有在这里被调用，否则 CI 的 -Werror 会报 unused-function。）
static BOOL BDBlockNetwork(void) { return BDEnabled() && !BDDumpOnly() && gNetwork; }

#include "../NetworkRules.h"

#pragma mark - 断言

static int gFailures = 0;

#define CHECK(cond)                                                        \
    do {                                                                   \
        if (!(cond)) {                                                     \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
            gFailures++;                                                   \
        }                                                                  \
    } while (0)

// 断言 matcher 的返回 tag（nil = 不拦）；带调用点行号，fail 时打印真实路径与期望。
static void ExpectLine(NSString *host, NSString *path, NSString *want, int line) {
    NSString *got = BDMatchNetwork(host, path);
    if (got == want || (got && want && [got isEqualToString:want])) return;
    const char *gotStr = got ? got.UTF8String : "nil";
    const char *wantStr = want ? want.UTF8String : "nil";
    fprintf(stderr, "FAIL %s:%d: %s%s -> %s (want %s)\n", __FILE__, line,
            host.UTF8String, path.UTF8String, gotStr, wantStr);
    gFailures++;
}
#define EXPECT(host, path, want) ExpectLine((host), (path), (want), __LINE__)

// 每个用例开头调一次：回到「全部开启」。
static void ResetSwitches(void) {
    gMaster = YES; gDumpOnly = NO; gNetwork = YES;
    gRecommend = YES; gSearchPromo = YES; gGameCenter = YES;
}

#pragma mark - 用例

// 1) 正常广告：host 规则、host+path 规则、游戏接口与资源
static void test_ads_matched(void) {
    ResetSwitches();
    EXPECT(@"cpc-service-square.yunxish.com", @"/api/v1/cpc", @"ad-host");
    EXPECT(@"logrcv.yunxish.com", @"/log", @"ad-host");
    EXPECT(@"afdconf.baidu.com", @"/sdk/conf", @"ad-host");
    EXPECT(@"nsclick.baidu.com", @"/click", @"ad-host");
    EXPECT(@"logu.hpplay.cn", @"/v1/report", @"ad-host");

    EXPECT(@"pan.baidu.com", @"/buy/ad/banner", @"ad-banner");
    EXPECT(@"pan.baidu.com", @"/rest/2.0/pcs/adv/task", @"ad-task");

    EXPECT(@"pan.baidu.com", @"/act/v2/gamecenter/recommend", @"game-center-api");
    EXPECT(@"ndstatic.cdn.bcebos.com", @"/gamecenter/js/nsr.bundle.js", @"game-center-asset");
    EXPECT(@"spcsz.cdn.bcebos.com", @"/cmpkg/1_swan-game_abc.zip", @"game-center-asset");
}

// 2) 合法功能：抓包里明确不是广告的东西必须继续放行
static void test_legit_traffic_not_matched(void) {
    ResetSwitches();
    EXPECT(@"pan.baidu.com", @"/feed/kingkongdistrict", nil);            // 首页金刚区
    EXPECT(@"pan.baidu.com", @"/api/getsyscfg", nil);                    // 混合配置，不能整拦
    EXPECT(@"staticsns.cdn.bcebos.com", @"/staticsns/amis/rain_v5.zip", nil);   // 首页特效
    EXPECT(@"spcsz.cdn.bcebos.com", @"/cmpkg/1_swan-core_v3.zip", nil);  // 小程序运行时
    EXPECT(@"antpcdn.com", @"/e/s0-ant.baidu.com/staticsns/amis/snow.zip", nil);
    EXPECT(@"pan.baidu.com", @"/rest/2.0/pcs/file?method=list", nil);
    EXPECT(@"", @"/anything", nil);                                      // 空 host 不拦
}

// 3) 三个总门：总开关 OFF / dump-only ON / 网络开关 OFF，任一都不拦（含明确广告）
static void test_master_gates(void) {
    ResetSwitches();
    gMaster = NO;
    EXPECT(@"cpc-service-square.yunxish.com", @"/x", nil);
    EXPECT(@"pan.baidu.com", @"/buy/ad/banner", nil);
    EXPECT(@"pan.baidu.com", @"/act/v2/gamecenter/recommend", nil);
    EXPECT(@"pan.baidu.com", @"/recommend/searchbox/bottom", nil);

    ResetSwitches();
    gDumpOnly = YES;
    EXPECT(@"cpc-service-square.yunxish.com", @"/x", nil);
    EXPECT(@"pan.baidu.com", @"/rest/2.0/pcs/adv", nil);
    EXPECT(@"pan.baidu.com", @"/recommend/searchbox/bottom", nil);

    ResetSwitches();
    gNetwork = NO;
    EXPECT(@"cpc-service-square.yunxish.com", @"/x", nil);
    EXPECT(@"pan.baidu.com", @"/buy/ad/banner", nil);
    EXPECT(@"spcsz.cdn.bcebos.com", @"/cmpkg/1_swan-game_x.zip", nil);
}

// 4) 搜索推广与首页推荐互相独立：关一个不能连累另一个
static void test_search_promo_and_recommend_independent(void) {
    ResetSwitches();
    gSearchPromo = NO;                                   // 想保留搜索推广
    EXPECT(@"pan.baidu.com", @"/recommend/searchbox/bottom", nil);
    EXPECT(@"pan.baidu.com", @"/aisearch/agent/memorycenter/getrecommendcards", @"recommend-api");

    ResetSwitches();
    gRecommend = NO;                                     // 想保留首页推荐
    EXPECT(@"pan.baidu.com", @"/recommend/searchbox/bottom", @"search-promo-api");
    EXPECT(@"pan.baidu.com", @"/aisearch/agent/memorycenter/getrecommendcards", nil);

    ResetSwitches();                                     // 两个都开：各自生效
    EXPECT(@"pan.baidu.com", @"/recommend/searchbox/bottom", @"search-promo-api");
    EXPECT(@"pan.baidu.com", @"/aisearch/agent/memorycenter/getrecommendcards", @"recommend-api");
}

// 5) 游戏中心开关关闭：游戏相关放行，广告规则照旧
static void test_game_center_off_keeps_network(void) {
    ResetSwitches();
    gGameCenter = NO;
    EXPECT(@"pan.baidu.com", @"/act/v2/gamecenter/gametaskinfo", nil);
    EXPECT(@"pan.baidu.com", @"/act/v2/gamecenter/historyplay", nil);
    EXPECT(@"ndstatic.cdn.bcebos.com", @"/gamecenter/js/nsr.bundle.js", nil);
    EXPECT(@"spcsz.cdn.bcebos.com", @"/cmpkg/1_swan-game_x.zip", nil);
    EXPECT(@"cpc-service-square.yunxish.com", @"/api/v1/cpc", @"ad-host");   // 广告不受影响
    EXPECT(@"pan.baidu.com", @"/buy/ad/banner", @"ad-banner");
    EXPECT(@"pan.baidu.com", @"/recommend/searchbox/bottom", @"search-promo-api");
}

// 6) 精确路径：/recommend/ 下其它接口、子路径与 bottomFake 都不许被误拦
static void test_recommend_path_precision(void) {
    ResetSwitches();
    EXPECT(@"pan.baidu.com", @"/recommend/searchbox/bottom", @"search-promo-api");
    EXPECT(@"pan.baidu.com", @"/recommend/searchbox/bottom/", @"search-promo-api");   // 末尾可选 斜杠
    EXPECT(@"pan.baidu.com", @"/recommend/searchbox/bottom/next", nil);               // 子路径不放行
    EXPECT(@"pan.baidu.com", @"/recommend/searchbox/bottomFake", nil);
    EXPECT(@"pan.baidu.com", @"/recommend/other", nil);
    EXPECT(@"pan.baidu.com", @"/recommend/searchbox/top", nil);
    EXPECT(@"other.example.com", @"/recommend/searchbox/bottom", nil);                // host 不对
}

// 7) 大小写：host 与 path 都按原规则先转小写再比
static void test_case_insensitive(void) {
    ResetSwitches();
    EXPECT(@"CPC-Service-Square.YunXish.COM", @"/API/v1/Cpc", @"ad-host");
    EXPECT(@"Pan.Baidu.COM", @"/BUY/AD/Banner", @"ad-banner");
    EXPECT(@"Pan.Baidu.com", @"/ACT/V2/GameCenter/recommend", @"game-center-api");
    EXPECT(@"Pan.Baidu.Com", @"/RECOMMEND/SearchBox/Bottom", @"search-promo-api");
    EXPECT(@"NDStatic.Cdn.Bcebos.COM", @"/GameCenter/js/x.js", @"game-center-asset");
}

#pragma mark - main

int main(void) {
    @autoreleasepool {
        test_ads_matched();
        test_legit_traffic_not_matched();
        test_master_gates();
        test_search_promo_and_recommend_independent();
        test_game_center_off_keeps_network();
        test_recommend_path_precision();
        test_case_insensitive();
    }

    if (gFailures == 0) {
        printf("network_rules_test: all checks passed\n");
        return 0;
    }
    fprintf(stderr, "network_rules_test: %d check(s) failed\n", gFailures);
    return 1;
}
