// tests/resume_splash_test.mm — ResumeSplashRemoval.h 的 macOS host 机制测试
//
// include 的是**真实**产品 header（FeatureRemoval.h + ResumeSplashRemoval.h）与真实安装器，
// 只有开关、日志和那条原实现是假的。产品算法不在这里复制。
//
// 测的是**机制**：
//   - hook 装在 BDNCUIAdvertisesManage 自己方法表的实例方法槽上，encoding B40@0:8q16@24@32 / argc 5；
//   - 原 IMP 每次**先且只调一次**，原 bool 先拿到手；
//   - 只有 总开关&&!诊断&&广告方法开关 && launchType∈{0,2,3} && 原结果为 true 才否决成 false；
//   - 其它 launchType（1/负值/未知正值）、任一开关关、原结果 false 一律精确透传原 bool；
//   - 5 个参数原样传递（含 nil），receiver 与 _cmd 准确；
//   - App Open 两条策略闸门（BDPanAdvertisementStrategy 实例方法，B24@0:8@16 / B24@0:8q16，argc 3）同规则：
//     冷那条无枚举；热那条只纳入 from ∈ {1,2,3,4}，0 / 负值 / 未知值（含 NSIntegerMax）一律透传原 bool；
//     实参 identity 保真（含 nil）；两条各有独立 orig 槽与独立 hit token，互不影响，也不动开屏那条；
//   - 重复安装不动 IMP、orig 不自指、不递归；
//   - 独立 phantom 描述覆盖 类缺失 / encoding 不符 / argc 不符 / 只有父类实现 四种不装路径。
//
// **不测**真机行为：空白开屏是否真的不再出现，必须真机验证，本测试不声明这一点。
//
// 构建运行（macOS，无需 IPA，无需 Theos）：
//   clang++ -std=c++17 -fobjc-arc -fblocks -Wall -Wextra -Werror \
//     -framework Foundation -o /tmp/resume_splash_test tests/resume_splash_test.mm
//   /tmp/resume_splash_test

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdio.h>

#pragma mark - 假开关 / 假日志（两个产品 header 依赖这些同名静态函数）

static BOOL gEnabled = YES;         // BDNadBlockEnabled
static BOOL gDumpOnly = NO;         // BDNadBlockDumpOnly
static BOOL gAdMethods = YES;       // BDNadBlockAdMethods
static BOOL gRemoveRecommend = YES; // FeatureRemoval.h 需要的三个旧开关
static BOOL gRemoveGameCenter = YES;
static BOOL gRemoveJobNovel = YES;
static unsigned gLogLines = 0;

static void BDLog(NSString *fmt, ...) {
    (void)fmt;           // 只数行数；测试不比对日志文本
    gLogLines++;
}
static BOOL BDEnabled(void) { return gEnabled; }
static BOOL BDDumpOnly(void) { return gDumpOnly; }
static BOOL BDAdMethodsEnabled(void) { return gAdMethods; }
static BOOL BDRemoveRecommend(void) { return gRemoveRecommend; }
static BOOL BDRemoveGameCenter(void) { return gRemoveGameCenter; }
static BOOL BDRemoveJobNovel(void) { return gRemoveJobNovel; }

// 顺序即真实接线顺序：先 FeatureRemoval.h（安装器），再本组件。
#include "../FeatureRemoval.h"
#include "../ResumeSplashRemoval.h"

#pragma mark - 断言与小工具

static int gFailures = 0;

#define CHECK(cond)                                                        \
    do {                                                                   \
        if (!(cond)) {                                                     \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
            gFailures++;                                                   \
        }                                                                  \
    } while (0)

static Class BDRSMakeClass(const char *name, Class super) {
    Class c = objc_allocateClassPair(super ? super : [NSObject class], name, 0);
    CHECK(c != nil);
    if (c) objc_registerClassPair(c);
    return c;
}

// 本测试自用的 spec 描述（产品里那条是静态的，不在这里造第二套安装器）。
static BDFRSpec BDRSTestSpec(const char *cls, const char *sel, BOOL isClassMethod,
                             const char *enc, unsigned argc, IMP hook,
                             IMP *orig, const char *name) {
    BDFRSpec s;
    s.cls = cls;
    s.sel = sel;
    s.isClassMethod = isClassMethod;
    s.enc = enc;
    s.argc = argc;
    s.hook = hook;
    s.orig = orig;
    s.name = name;
    s.installed = NO;
    return s;
}

static SEL gGateSel;   // -needToShowSplashWithLaunchType:launchUrl:launchOptions:

// receiver 必须是真实实例：产品 hook 装在**实例方法**槽上，用 object_getClass(host)
// 取实例的类，正好对应运行时的方法查找方式（不把类当实例直接调）。
static bool BDRSSendGate(id host, NSInteger launchType, id url, id options) {
    bool (*imp)(id, SEL, NSInteger, id, id) =
        (bool (*)(id, SEL, NSInteger, id, id))
            class_getMethodImplementation(object_getClass(host), gGateSel);
    return imp(host, gGateSel, launchType, url, options);
}

#pragma mark - 原实现替身（假 BDNCUIAdvertisesManage）

// 每次调用：记次数、把 5 个入参原样存下来，返回可配的 bool。
static unsigned gCalls = 0;
static id gSeenSelf = nil;
static SEL gSeenCmd = NULL;
static NSInteger gSeenType = -999;
static id gSeenUrl = nil;
static id gSeenOptions = nil;
static bool gOriginalResult = true;

static bool PhNeedShow(id self, SEL _cmd, NSInteger launchType, id url, id options) {
    gCalls++;
    gSeenSelf = self;
    gSeenCmd = _cmd;
    gSeenType = launchType;
    gSeenUrl = url;
    gSeenOptions = options;
    return gOriginalResult;
}

static Class gManageCls;    // 假 BDNCUIAdvertisesManage
static id gManageHost;      // 真实实例：调用时的 receiver

// ---- App Open 两条策略闸门的替身（同一个假类上的两个实例方法槽）----

static SEL gColdSel;    // -isEnableShowAdForAppColdOpenWithLaunchoptions:
static SEL gHotSel;     // -isEnableShowAdForAppHotOpenWithFrom:

static unsigned gColdCalls = 0;
static id gColdSeenSelf = nil;
static SEL gColdSeenCmd = NULL;
static id gColdSeenOptions = nil;
static bool gColdOriginalResult = true;

static unsigned gHotCalls = 0;
static id gHotSeenSelf = nil;
static SEL gHotSeenCmd = NULL;
static long long gHotSeenFrom = -999;      // 用 64 位存：NSIntegerMax 也要能原样比对
static bool gHotOriginalResult = true;

static bool PhColdGate(id self, SEL _cmd, id launchOptions) {
    gColdCalls++;
    gColdSeenSelf = self;
    gColdSeenCmd = _cmd;
    gColdSeenOptions = launchOptions;
    return gColdOriginalResult;
}

static bool PhHotGate(id self, SEL _cmd, NSInteger from) {
    gHotCalls++;
    gHotSeenSelf = self;
    gHotSeenCmd = _cmd;
    gHotSeenFrom = (long long)from;
    return gHotOriginalResult;
}

static Class gStrategyCls;  // 假 BDPanAdvertisementStrategy
static id gStrategyHost;    // 真实实例

static void setup_hosts(void) {
    gGateSel = sel_registerName("needToShowSplashWithLaunchType:launchUrl:launchOptions:");
    gManageCls = BDRSMakeClass("BDNCUIAdvertisesManage", Nil);
    CHECK(class_addMethod(gManageCls, gGateSel, (IMP)PhNeedShow, "B40@0:8q16@24@32"));
    gManageHost = [[gManageCls alloc] init];
    CHECK(gManageHost != nil);

    // 三条 spec 的真实槽：先注册类与自有方法，再走安装（少造脚手架）。
    gColdSel = sel_registerName("isEnableShowAdForAppColdOpenWithLaunchoptions:");
    gHotSel = sel_registerName("isEnableShowAdForAppHotOpenWithFrom:");
    gStrategyCls = BDRSMakeClass("BDPanAdvertisementStrategy", Nil);
    CHECK(class_addMethod(gStrategyCls, gColdSel, (IMP)PhColdGate, "B24@0:8@16"));
    CHECK(class_addMethod(gStrategyCls, gHotSel, (IMP)PhHotGate, "B24@0:8q16"));
    gStrategyHost = [[gStrategyCls alloc] init];
    CHECK(gStrategyHost != nil);
}

// 每次发调用的统一入口：断言原实现严格 +1，并回传它这次的返回原值。
// 计数用 before/after 增量，测试自己的准备动作不算进产品动作。
static bool SendAndCount(id host, NSInteger launchType, id url, id options) {
    unsigned before = gCalls;
    bool got = BDRSSendGate(host, launchType, url, options);
    CHECK(gCalls == before + 1);            // 每次调用，原实现只跑一次
    return got;
}

static bool BDRSSendColdGate(id host, id options) {
    bool (*imp)(id, SEL, id) =
        (bool (*)(id, SEL, id))class_getMethodImplementation(object_getClass(host), gColdSel);
    return imp(host, gColdSel, options);
}

static bool BDRSSendHotGate(id host, NSInteger from) {
    bool (*imp)(id, SEL, NSInteger) =
        (bool (*)(id, SEL, NSInteger))class_getMethodImplementation(object_getClass(host), gHotSel);
    return imp(host, gHotSel, from);
}

static bool SendColdAndCount(id host, id options) {
    unsigned before = gColdCalls;
    bool got = BDRSSendColdGate(host, options);
    CHECK(gColdCalls == before + 1);
    return got;
}

static bool SendHotAndCount(id host, NSInteger from) {
    unsigned before = gHotCalls;
    bool got = BDRSSendHotGate(host, from);
    CHECK(gHotCalls == before + 1);
    return got;
}

#pragma mark - 测试

// 安装前：槽是空的，调用直接落到原实现。
static void test_before_install(void) {
    CHECK(BDFRSpecResumeSplashGate.installed == NO);
    CHECK(BDFROrigResumeSplashGate == NULL);
    CHECK(BDFRSpecAppColdOpenGate.installed == NO);
    CHECK(BDFRSpecAppHotOpenGate.installed == NO);
    CHECK(BDFROrigAppColdOpenGate == NULL);
    CHECK(BDFROrigAppHotOpenGate == NULL);

    gCalls = 0;
    gOriginalResult = true;
    CHECK(BDRSSendGate(gManageHost, 3, nil, nil) == true);   // 没有 hook：原样
    CHECK(gCalls == 1);
    CHECK(gSeenSelf == gManageHost);
    CHECK(gSeenCmd == gGateSel);
    CHECK(gSeenType == 3);

    gColdCalls = 0;
    gColdOriginalResult = true;
    CHECK(BDRSSendColdGate(gStrategyHost, nil) == true);
    CHECK(gColdCalls == 1);
    CHECK(gColdSeenSelf == gStrategyHost);
    CHECK(gColdSeenCmd == gColdSel);
    CHECK(gColdSeenOptions == nil);

    gHotCalls = 0;
    gHotOriginalResult = true;
    CHECK(BDRSSendHotGate(gStrategyHost, 4) == true);
    CHECK(gHotCalls == 1);
    CHECK(gHotSeenSelf == gStrategyHost);
    CHECK(gHotSeenCmd == gHotSel);
    CHECK(gHotSeenFrom == 4);
}

// 安装：挂上三条 hook，orig 槽都指向真实原实现（不是 hook 自己）。
static void test_install(void) {
    unsigned logsBefore = gLogLines;
    BDRSInstallAll();
    CHECK(BDFRSpecResumeSplashGate.installed == YES);
    CHECK(BDFROrigResumeSplashGate == (IMP)PhNeedShow);
    CHECK(BDFROrigResumeSplashGate != (IMP)BDRSNeedShowSplash);   // orig 不自指
    CHECK(class_getMethodImplementation(object_getClass(gManageHost), gGateSel)
          == (IMP)BDRSNeedShowSplash);

    // App Open 两条：各自独立装上，orig 槽分别指到自己的原实现，不串槽。
    CHECK(BDFRSpecAppColdOpenGate.installed == YES);
    CHECK(BDFRSpecAppHotOpenGate.installed == YES);
    CHECK(BDFROrigAppColdOpenGate == (IMP)PhColdGate);
    CHECK(BDFROrigAppHotOpenGate == (IMP)PhHotGate);
    CHECK(BDFROrigAppColdOpenGate != (IMP)BDRSAppColdOpenGate);
    CHECK(BDFROrigAppHotOpenGate != (IMP)BDRSAppHotOpenGate);
    CHECK(BDFROrigAppColdOpenGate != BDFROrigAppHotOpenGate);      // 两个 slot 各归各
    CHECK(class_getMethodImplementation(object_getClass(gStrategyHost), gColdSel)
          == (IMP)BDRSAppColdOpenGate);
    CHECK(class_getMethodImplementation(object_getClass(gStrategyHost), gHotSel)
          == (IMP)BDRSAppHotOpenGate);

    CHECK(gLogLines == logsBefore + 3);      // 三条 spec 各一行 installed
    CHECK(gCalls == 1);                      // 安装过程不调用任何原实现
    CHECK(gColdCalls == 1);
    CHECK(gHotCalls == 1);
}

// 开关都开着，但这些情况**都不该**是「真正否决」，一行 hit 都不能多。
static void test_no_false_hit(void) {
    gEnabled = YES; gDumpOnly = NO; gAdMethods = YES;
    unsigned logsBefore = gLogLines;

    // 原结果 false：本来就展示不了，已知的 0/2/3 全部原样 false，不记 hit
    gOriginalResult = false;
    for (NSInteger t = 0; t <= 3; t++) {
        CHECK(SendAndCount(gManageHost, t, nil, nil) == false);
    }

    // 未知/兜底 launchType：无论原结果真假都透传（不把未知值当冷热启动）
    gOriginalResult = true;
    CHECK(SendAndCount(gManageHost, 1, nil, nil) == true);
    CHECK(SendAndCount(gManageHost, -1, nil, nil) == true);      // 负值
    CHECK(SendAndCount(gManageHost, 7, nil, nil) == true);       // 未知正值
    gOriginalResult = false;
    CHECK(SendAndCount(gManageHost, 1, nil, nil) == false);
    CHECK(SendAndCount(gManageHost, -1, nil, nil) == false);
    CHECK(SendAndCount(gManageHost, 7, nil, nil) == false);

    // 三个开关各自关掉：0/2/3 + 原 true 也必须透传（绝不能在这里提前消耗 hit token）
    gOriginalResult = true;
    gEnabled = NO;
    CHECK(SendAndCount(gManageHost, 0, nil, nil) == true);
    CHECK(SendAndCount(gManageHost, 2, nil, nil) == true);
    CHECK(SendAndCount(gManageHost, 3, nil, nil) == true);
    gEnabled = YES;

    gDumpOnly = YES;
    CHECK(SendAndCount(gManageHost, 0, nil, nil) == true);
    CHECK(SendAndCount(gManageHost, 2, nil, nil) == true);
    CHECK(SendAndCount(gManageHost, 3, nil, nil) == true);
    gDumpOnly = NO;

    gAdMethods = NO;
    CHECK(SendAndCount(gManageHost, 0, nil, nil) == true);
    CHECK(SendAndCount(gManageHost, 2, nil, nil) == true);
    CHECK(SendAndCount(gManageHost, 3, nil, nil) == true);
    gAdMethods = YES;

    CHECK(gLogLines == logsBefore);          // 以上一次真 hit 都没有
}

// 真正否决：0/2/3 + 三开关全开 + 原 true 这一种组合，且只在第一次（冷启动 0）记一行 hit。
static void test_genuine_veto(void) {
    unsigned logsBefore = gLogLines;
    gEnabled = YES; gDumpOnly = NO; gAdMethods = YES;
    gOriginalResult = true;

    CHECK(SendAndCount(gManageHost, 0, nil, nil) == false);        // 冷启动 0：原 true -> 否决
    CHECK(gLogLines == logsBefore + 1);                            // 首次真正 hit，恰好一行
    CHECK(SendAndCount(gManageHost, 0, nil, nil) == false);        // 重复 0 仍然否决
    CHECK(SendAndCount(gManageHost, 2, nil, nil) == false);
    CHECK(SendAndCount(gManageHost, 3, nil, nil) == false);
    CHECK(gLogLines == logsBefore + 1);                            // dispatch_once：不再重复

    // 否决之后，未知 launchType 仍然原值
    CHECK(SendAndCount(gManageHost, 1, nil, nil) == true);
    CHECK(SendAndCount(gManageHost, -1, nil, nil) == true);
    CHECK(SendAndCount(gManageHost, 7, nil, nil) == true);
    CHECK(gLogLines == logsBefore + 1);
}

// 参数保真：receiver / _cmd / launchType / launchUrl / launchOptions 全部原样到原实现。
static void test_argument_fidelity(void) {
    unsigned logsBefore = gLogLines;
    gOriginalResult = true;

    NSString *url = @"bdnetdisk://n/action.maintab";
    NSDictionary *opts = @{@"UIApplicationLaunchOptionsURLKey": url};

    // 冷启动 0 + nil：不造默认对象，原样传 nil
    gSeenSelf = nil; gSeenCmd = NULL; gSeenType = -999; gSeenUrl = (id)@"sentinel"; gSeenOptions = (id)@"sentinel";
    CHECK(SendAndCount(gManageHost, 0, nil, nil) == false);        // 0 已纳入否决：真 hit 情形
    CHECK(gSeenSelf == gManageHost);
    CHECK(gSeenCmd == gGateSel);
    CHECK(gSeenType == 0);
    CHECK(gSeenUrl == nil);
    CHECK(gSeenOptions == nil);

    // 冷启动 0 + 非 nil：identity 精确，不复制、不换对象
    gSeenType = -999; gSeenUrl = nil; gSeenOptions = nil;
    CHECK(SendAndCount(gManageHost, 0, url, opts) == false);
    CHECK(gSeenSelf == gManageHost);
    CHECK(gSeenCmd == gGateSel);
    CHECK(gSeenType == 0);
    CHECK(gSeenUrl == url);
    CHECK(gSeenOptions == opts);

    // 冷启动混合参数与热启动的原有非 nil 参数路径也须保持 identity。
    CHECK(SendAndCount(gManageHost, 0, nil, opts) == false);
    CHECK(gSeenUrl == nil && gSeenOptions == opts && gSeenType == 0);
    CHECK(SendAndCount(gManageHost, 3, url, opts) == false);
    CHECK(gSeenUrl == url && gSeenOptions == opts && gSeenType == 3);

    // 混合：url 有、options nil，用未知 launchType 1 验证透传
    gSeenUrl = nil; gSeenOptions = (id)@"sentinel"; gSeenType = -999;
    CHECK(SendAndCount(gManageHost, 1, url, nil) == true);
    CHECK(gSeenUrl == url);
    CHECK(gSeenOptions == nil);
    CHECK(gSeenType == 1);
    CHECK(gSeenSelf == gManageHost);

    CHECK(gLogLines == logsBefore);        // 这一组没有新的 hit（token 在前面已消耗）
}

// 紧凑组合检查：真实 hook + SendAndCount，规格 = 「原 true 且三开关全开且 launchType∈{0,2,3}」才否决。
// token 已在 test_genuine_veto 消耗，所以这里全程都不该再出现新日志。
static void test_gate_matrix(void) {
    const BOOL bools[2] = {YES, NO};
    const bool origs[2] = {true, false};
    const NSInteger known[] = {0, 2, 3};        // 纳入否决的三种
    const NSInteger unknown[] = {1, -1, 7};     // 一律透传
    unsigned logsBefore = gLogLines;
    unsigned checked = 0;

    for (unsigned o = 0; o < 2; o++)
    for (unsigned e = 0; e < 2; e++)
    for (unsigned d = 0; d < 2; d++)
    for (unsigned a = 0; a < 2; a++) {
        gEnabled = bools[e]; gDumpOnly = bools[d]; gAdMethods = bools[a];
        gOriginalResult = origs[o];
        BOOL gate = bools[e] && !bools[d] && bools[a];

        for (unsigned k = 0; k < 3; k++) {
            bool want = origs[o] && !gate;
            if (SendAndCount(gManageHost, known[k], nil, nil) != want) {
                fprintf(stderr, "FAIL %s:%d: known %ld (orig=%d enabled=%d dump=%d adMethods=%d)\n",
                        __FILE__, __LINE__, (long)known[k], origs[o], bools[e], bools[d], bools[a]);
                gFailures++;
            }
            checked++;
        }
        for (unsigned u = 0; u < 3; u++) {
            if (SendAndCount(gManageHost, unknown[u], nil, nil) != origs[o]) {
                fprintf(stderr, "FAIL %s:%d: unknown %ld (orig=%d enabled=%d dump=%d adMethods=%d)\n",
                        __FILE__, __LINE__, (long)unknown[u], origs[o], bools[e], bools[d], bools[a]);
                gFailures++;
            }
            checked++;
        }
    }
    CHECK(checked == 2 * 2 * 2 * 2 * 6);
    CHECK(gLogLines == logsBefore);             // token 已消耗：一行都不该再多
    gEnabled = YES; gDumpOnly = NO; gAdMethods = YES; gOriginalResult = true;
}

// ── App Open 两条策略闸门 ───────────────────────────────────────────────
// 顺序刻意如此：先「不该否决」的全部情形（原 false / 开关关 / 未知 from），确认一行 hit 都不多，
// 再真否决，最后才是矩阵（token 已消耗，只验规格与无新日志）。

// 开关都开着，但这些情况**都不该**是「真正否决」。
static void test_appopen_no_false_hit(void) {
    gEnabled = YES; gDumpOnly = NO; gAdMethods = YES;
    unsigned logsBefore = gLogLines;
    NSDictionary *opts = @{@"UIApplicationLaunchOptionsURLKey": @"bdnetdisk://x"};

    // 原结果 false：原生本来就不展示（含 iPad / inactive / 服务端关掉等既有分支），一律原样 false。
    gColdOriginalResult = false;
    CHECK(SendColdAndCount(gStrategyHost, nil) == false);
    CHECK(SendColdAndCount(gStrategyHost, opts) == false);
    gHotOriginalResult = false;
    for (NSInteger f = 0; f <= 7; f++) CHECK(SendHotAndCount(gStrategyHost, f) == false);

    // 热 from 未知：0 / 负值 / 7 / 极值都不当热启动，无论原结果真假都透传。
    gHotOriginalResult = true;
    CHECK(SendHotAndCount(gStrategyHost, 0) == true);
    CHECK(SendHotAndCount(gStrategyHost, -1) == true);
    CHECK(SendHotAndCount(gStrategyHost, 7) == true);
    CHECK(SendHotAndCount(gStrategyHost, NSIntegerMax) == true);
    CHECK(SendHotAndCount(gStrategyHost, NSIntegerMin) == true);

    // 三个开关各自关掉：冷（无枚举）与热（1..4）都必须透传原 true。
    gColdOriginalResult = true;
    gHotOriginalResult = true;
    gEnabled = NO;
    CHECK(SendColdAndCount(gStrategyHost, nil) == true);
    for (NSInteger f = 1; f <= 4; f++) CHECK(SendHotAndCount(gStrategyHost, f) == true);
    gEnabled = YES;
    gDumpOnly = YES;
    CHECK(SendColdAndCount(gStrategyHost, opts) == true);
    for (NSInteger f = 1; f <= 4; f++) CHECK(SendHotAndCount(gStrategyHost, f) == true);
    gDumpOnly = NO;
    gAdMethods = NO;
    CHECK(SendColdAndCount(gStrategyHost, nil) == true);
    for (NSInteger f = 1; f <= 4; f++) CHECK(SendHotAndCount(gStrategyHost, f) == true);
    gAdMethods = YES;

    CHECK(gLogLines == logsBefore);          // 以上两条 gate 一次真 hit 都没有
}

// 冷那条真否决：原 true + 三开关全开；实参（nil 与字典）identity 保真，只首次记一行。
static void test_appopen_cold_veto_identity(void) {
    unsigned logsBefore = gLogLines;
    gEnabled = YES; gDumpOnly = NO; gAdMethods = YES;
    gColdOriginalResult = true;

    gColdSeenSelf = nil; gColdSeenCmd = NULL; gColdSeenOptions = (id)@"sentinel";
    CHECK(SendColdAndCount(gStrategyHost, nil) == false);      // 冷 + nil：不造默认对象
    CHECK(gColdSeenSelf == gStrategyHost);
    CHECK(gColdSeenCmd == gColdSel);
    CHECK(gColdSeenOptions == nil);
    CHECK(gLogLines == logsBefore + 1);                        // 首次真正 hit，恰好一行
    CHECK(SendColdAndCount(gStrategyHost, nil) == false);      // 重复仍否决
    CHECK(gLogLines == logsBefore + 1);                        // dispatch_once 不再重复

    NSDictionary *opts = @{@"UIApplicationLaunchOptionsSourceApplicationKey": @"com.tencent.xin"};
    gColdSeenSelf = nil; gColdSeenCmd = NULL; gColdSeenOptions = nil;
    CHECK(SendColdAndCount(gStrategyHost, opts) == false);     // 冷 + 字典：identity 精确
    CHECK(gColdSeenSelf == gStrategyHost);
    CHECK(gColdSeenCmd == gColdSel);
    CHECK(gColdSeenOptions == opts);
    CHECK(gLogLines == logsBefore + 1);

    gColdOriginalResult = false;                               // 原 false：原值透传，不假记 hit
    CHECK(SendColdAndCount(gStrategyHost, opts) == false);
    CHECK(gColdSeenOptions == opts);
    CHECK(gLogLines == logsBefore + 1);
    gColdOriginalResult = true;

    CHECK(BDFRSpecResumeSplashGate.installed == YES);          // 冷这条否决不牵连另外两条
    CHECK(BDFROrigAppHotOpenGate == (IMP)PhHotGate);
}

// 热那条真否决：只认 from 1/2/3/4（两版 keyForAppHotOpenWithFrom: 字面量表一致），首次一行。
static void test_appopen_hot_veto_enum(void) {
    unsigned logsBefore = gLogLines;
    gEnabled = YES; gDumpOnly = NO; gAdMethods = YES;
    gHotOriginalResult = true;

    const NSInteger known[] = {1, 2, 3, 4};
    for (unsigned i = 0; i < 4; i++) {
        gHotSeenSelf = nil; gHotSeenCmd = NULL; gHotSeenFrom = -999;
        CHECK(SendHotAndCount(gStrategyHost, known[i]) == false);
        CHECK(gHotSeenSelf == gStrategyHost);                  // receiver / _cmd / from 原样到原实现
        CHECK(gHotSeenCmd == gHotSel);
        CHECK(gHotSeenFrom == (long long)known[i]);
        CHECK(gLogLines == logsBefore + 1);                    // 只有 from=1 那次记一行
    }
    CHECK(SendHotAndCount(gStrategyHost, 4) == false);
    CHECK(gLogLines == logsBefore + 1);

    // 已证枚举之外：一律透传原 bool，不消耗 hit、不改值（含极端值）
    CHECK(SendHotAndCount(gStrategyHost, 0) == true);
    CHECK(SendHotAndCount(gStrategyHost, -1) == true);
    CHECK(SendHotAndCount(gStrategyHost, 5) == true);          // 未来新增的下一枚枚举：现在不动
    CHECK(SendHotAndCount(gStrategyHost, 99) == true);
    gHotSeenFrom = -999;
    CHECK(SendHotAndCount(gStrategyHost, NSIntegerMax) == true);
    CHECK(gHotSeenFrom == (long long)NSIntegerMax);
    gHotOriginalResult = false;
    CHECK(SendHotAndCount(gStrategyHost, 1) == false);         // 枚举内但原 false：透传
    CHECK(gLogLines == logsBefore + 1);
    gHotOriginalResult = true;

    CHECK(BDFRSpecResumeSplashGate.installed == YES);
    CHECK(BDFROrigAppColdOpenGate == (IMP)PhColdGate);
}

// 矩阵：冷 = 原 bool × 三开关（16 组）；热 = 原 bool × 三开关 × 8个 from（128组）。
// 两条 token 都已消耗，所以这里全程不该再出现新日志。
static void test_appopen_matrix(void) {
    const BOOL bools[2] = {YES, NO};
    const bool origs[2] = {true, false};
    const NSInteger known[] = {1, 2, 3, 4};
    const NSInteger unknown[] = {0, -1, 5, 99};
    unsigned logsBefore = gLogLines;
    unsigned checked = 0;

    for (unsigned o = 0; o < 2; o++)
    for (unsigned e = 0; e < 2; e++)
    for (unsigned d = 0; d < 2; d++)
    for (unsigned a = 0; a < 2; a++) {
        gEnabled = bools[e]; gDumpOnly = bools[d]; gAdMethods = bools[a];
        BOOL gate = bools[e] && !bools[d] && bools[a];

        gColdOriginalResult = origs[o];
        if (SendColdAndCount(gStrategyHost, nil) != (origs[o] && !gate)) {
            fprintf(stderr, "FAIL %s:%d: cold (orig=%d enabled=%d dump=%d adMethods=%d)\n",
                    __FILE__, __LINE__, origs[o], bools[e], bools[d], bools[a]);
            gFailures++;
        }
        checked++;

        gHotOriginalResult = origs[o];
        for (unsigned k = 0; k < 4; k++) {
            if (SendHotAndCount(gStrategyHost, known[k]) != (origs[o] && !gate)) {
                fprintf(stderr, "FAIL %s:%d: hot known %ld (orig=%d enabled=%d dump=%d adMethods=%d)\n",
                        __FILE__, __LINE__, (long)known[k], origs[o], bools[e], bools[d], bools[a]);
                gFailures++;
            }
            checked++;
        }
        for (unsigned u = 0; u < 4; u++) {
            if (SendHotAndCount(gStrategyHost, unknown[u]) != origs[o]) {
                fprintf(stderr, "FAIL %s:%d: hot unknown %ld (orig=%d enabled=%d dump=%d adMethods=%d)\n",
                        __FILE__, __LINE__, (long)unknown[u], origs[o], bools[e], bools[d], bools[a]);
                gFailures++;
            }
            checked++;
        }
    }
    CHECK(checked == 2 * 2 * 2 * 2 * 9);
    CHECK(gLogLines == logsBefore);             // token 已消耗：一行都不该再多
    gEnabled = YES; gDumpOnly = NO; gAdMethods = YES;
    gColdOriginalResult = true; gHotOriginalResult = true;
}

// 重复安装：不动 IMP、orig 不自指、原实现仍然每次只跑一次（不递归）。
static void test_idempotent_reinstall(void) {
    IMP before = class_getMethodImplementation(object_getClass(gManageHost), gGateSel);
    IMP beforeCold = class_getMethodImplementation(object_getClass(gStrategyHost), gColdSel);
    IMP beforeHot = class_getMethodImplementation(object_getClass(gStrategyHost), gHotSel);
    unsigned logsBefore = gLogLines;
    gEnabled = YES; gDumpOnly = NO; gAdMethods = YES;
    gOriginalResult = true;
    gColdOriginalResult = true;
    gHotOriginalResult = true;

    BDRSInstallAll();
    BDRSInstallAll();
    CHECK(BDFRSpecResumeSplashGate.installed == YES);
    CHECK(BDFRSpecAppColdOpenGate.installed == YES);
    CHECK(BDFRSpecAppHotOpenGate.installed == YES);
    CHECK(class_getMethodImplementation(object_getClass(gManageHost), gGateSel) == before);
    CHECK(class_getMethodImplementation(object_getClass(gStrategyHost), gColdSel) == beforeCold);
    CHECK(class_getMethodImplementation(object_getClass(gStrategyHost), gHotSel) == beforeHot);
    CHECK(BDFROrigResumeSplashGate == (IMP)PhNeedShow);              // 没被覆盖成 hook
    CHECK(BDFROrigResumeSplashGate != (IMP)BDRSNeedShowSplash);
    CHECK(BDFROrigAppColdOpenGate == (IMP)PhColdGate);               // 两条 App Open 各自没被动
    CHECK(BDFROrigAppHotOpenGate == (IMP)PhHotGate);
    CHECK(BDFROrigAppColdOpenGate != (IMP)BDRSAppColdOpenGate);
    CHECK(BDFROrigAppHotOpenGate != (IMP)BDRSAppHotOpenGate);
    CHECK(gLogLines == logsBefore + 6);      // 共享安装器对三条已装 spec 各打一行「already installed」×2 次
    CHECK(SendAndCount(gManageHost, 0, nil, nil) == false);          // 冷启动 0：转发正常，计数 +1 不递归
    CHECK(SendAndCount(gManageHost, 2, nil, nil) == false);          // 热启动 2 同样
    CHECK(SendColdAndCount(gStrategyHost, nil) == false);            // App Open 冷：转发正常
    CHECK(SendHotAndCount(gStrategyHost, 3) == false);               // App Open 热：转发正常
    CHECK(gLogLines == logsBefore + 6);                              // 重复安装不再产生 hit
}

// 四种不装路径：都用独立 phantom 描述，不改已注册的 encoding、不重置真实 spec。
static void test_skip_paths(void) {
    // phantom 宿主：方法名与 encoding 与真实目标一致，但类名是假的
    Class host = BDRSMakeClass("BDRSPhantomHost", Nil);
    CHECK(class_addMethod(host, gGateSel, (IMP)PhNeedShow, "B40@0:8q16@24@32"));

    // 控制组：描述正确时它是能装上的（证明上面的失败不是「phantom 本身不可装」）
    IMP okOrig = NULL;
    BDFRSpec okSpec = BDRSTestSpec("BDRSPhantomHost",
                                   "needToShowSplashWithLaunchType:launchUrl:launchOptions:", NO,
                                   "B40@0:8q16@24@32", 5, (IMP)BDRSNeedShowSplash, &okOrig, "t-ok");
    CHECK(BDFRInstallSpec(&okSpec) == YES);
    CHECK(okSpec.installed == YES && okOrig == (IMP)PhNeedShow);

    // 1) encoding 不符
    IMP origEnc = NULL;
    BDFRSpec s1 = BDRSTestSpec("BDRSPhantomHost",
                               "needToShowSplashWithLaunchType:launchUrl:launchOptions:", NO,
                               "B40@0:8q16@24", 5, (IMP)BDRSNeedShowSplash, &origEnc, "t-wrong-enc");
    CHECK(BDFRInstallSpec(&s1) == NO);
    CHECK(s1.installed == NO && origEnc == NULL);

    // 2) 参数个数不符（真实是 5；这里故意写 4）
    IMP origArgc = NULL;
    BDFRSpec s2 = BDRSTestSpec("BDRSPhantomHost",
                               "needToShowSplashWithLaunchType:launchUrl:launchOptions:", NO,
                               "B40@0:8q16@24@32", 4, (IMP)BDRSNeedShowSplash, &origArgc, "t-wrong-argc");
    CHECK(BDFRInstallSpec(&s2) == NO);
    CHECK(s2.installed == NO && origArgc == NULL);

    // 3) 类缺失
    IMP origMissing = NULL;
    BDFRSpec s3 = BDRSTestSpec("BDRSPhantomNoSuchClass",
                               "needToShowSplashWithLaunchType:launchUrl:launchOptions:", NO,
                               "B40@0:8q16@24@32", 5, (IMP)BDRSNeedShowSplash, &origMissing, "t-missing");
    CHECK(BDFRInstallSpec(&s3) == NO);
    CHECK(s3.installed == NO && origMissing == NULL);

    // 4) 只有父类实现：子类自己的方法表里没有 → 不装（不动父类）
    Class parent = BDRSMakeClass("BDRSPhantomParent", Nil);
    CHECK(class_addMethod(parent, gGateSel, (IMP)PhNeedShow, "B40@0:8q16@24@32"));
    Class child = BDRSMakeClass("BDRSPhantomChild", parent);
    unsigned childOwn = 0;
    Method *childMethods = class_copyMethodList(child, &childOwn);   // 只看自己的方法表
    if (childMethods) free(childMethods);
    CHECK(childOwn == 0);                                            // 继承来的不算「自有方法」
    IMP origInherited = NULL;
    BDFRSpec s4 = BDRSTestSpec("BDRSPhantomChild",
                               "needToShowSplashWithLaunchType:launchUrl:launchOptions:", NO,
                               "B40@0:8q16@24@32", 5, (IMP)BDRSNeedShowSplash, &origInherited, "t-inherited");
    CHECK(BDFRInstallSpec(&s4) == NO);
    CHECK(s4.installed == NO && origInherited == NULL);
    CHECK(class_getMethodImplementation(child, gGateSel) == (IMP)PhNeedShow);  // 父类槽没被动

    // 5) App Open 冷/热那两条走同一个解析器：控制组（enc/argc 都正确）能装，改 enc / 改 argc 就 skip。
    CHECK(class_addMethod(host, gColdSel, (IMP)PhColdGate, "B24@0:8@16"));
    CHECK(class_addMethod(host, gHotSel, (IMP)PhHotGate, "B24@0:8q16"));
    IMP origColdOk = NULL, origHotOk = NULL;
    BDFRSpec c0 = BDRSTestSpec("BDRSPhantomHost", "isEnableShowAdForAppColdOpenWithLaunchoptions:", NO,
                               "B24@0:8@16", 3, (IMP)BDRSAppColdOpenGate, &origColdOk, "t-cold-ok");
    BDFRSpec h0 = BDRSTestSpec("BDRSPhantomHost", "isEnableShowAdForAppHotOpenWithFrom:", NO,
                               "B24@0:8q16", 3, (IMP)BDRSAppHotOpenGate, &origHotOk, "t-hot-ok");
    CHECK(BDFRInstallSpec(&c0) == YES && c0.installed == YES && origColdOk == (IMP)PhColdGate);
    CHECK(BDFRInstallSpec(&h0) == YES && h0.installed == YES && origHotOk == (IMP)PhHotGate);

    IMP origColdEnc = NULL, origHotArgc = NULL;
    BDFRSpec c1 = BDRSTestSpec("BDRSPhantomHost", "isEnableShowAdForAppColdOpenWithLaunchoptions:", NO,
                               "B24@0:8q16", 3, (IMP)BDRSAppColdOpenGate, &origColdEnc, "t-cold-wrong-enc");
    BDFRSpec h1 = BDRSTestSpec("BDRSPhantomHost", "isEnableShowAdForAppHotOpenWithFrom:", NO,
                               "B24@0:8q16", 2, (IMP)BDRSAppHotOpenGate, &origHotArgc, "t-hot-wrong-argc");
    CHECK(BDFRInstallSpec(&c1) == NO && c1.installed == NO && origColdEnc == NULL);
    CHECK(BDFRInstallSpec(&h1) == NO && h1.installed == NO && origHotArgc == NULL);

    // 以上任何一次失败都不许影响真实那三条 spec
    CHECK(BDFRSpecResumeSplashGate.installed == YES);
    CHECK(BDFROrigResumeSplashGate == (IMP)PhNeedShow);
    CHECK(class_getMethodImplementation(object_getClass(gManageHost), gGateSel)
          == (IMP)BDRSNeedShowSplash);
    CHECK(BDFRSpecAppColdOpenGate.installed == YES);
    CHECK(BDFRSpecAppHotOpenGate.installed == YES);
    CHECK(BDFROrigAppColdOpenGate == (IMP)PhColdGate);
    CHECK(BDFROrigAppHotOpenGate == (IMP)PhHotGate);
    CHECK(class_getMethodImplementation(object_getClass(gStrategyHost), gColdSel)
          == (IMP)BDRSAppColdOpenGate);
    CHECK(class_getMethodImplementation(object_getClass(gStrategyHost), gHotSel)
          == (IMP)BDRSAppHotOpenGate);
}

#pragma mark - main

int main(void) {
    @autoreleasepool {
        BDFRInstallAll();        // 引用 FeatureRemoval 的静态安装器：这些类都不存在，整组 skip
        setup_hosts();

        test_before_install();
        test_install();
        test_no_false_hit();           // 必须早于 test_genuine_veto：验「不假记 hit」
        test_genuine_veto();
        test_argument_fidelity();
        test_gate_matrix();            // token 已消耗：矩阵只验规格 + 无新日志
        // App Open 两条同样顺序：先「不该否决」→ 再真 hit → 最后矩阵（不消耗 token 次序）
        test_appopen_no_false_hit();
        test_appopen_cold_veto_identity();
        test_appopen_hot_veto_enum();
        test_appopen_matrix();
        test_idempotent_reinstall();
        test_skip_paths();

        printf("%s: %d 项失败（日志 %u 行，原实现共 %u 次）\n",
               gFailures ? "FAIL" : "PASS", gFailures, gLogLines, gCalls);
    }
    return gFailures ? 1 : 0;
}
