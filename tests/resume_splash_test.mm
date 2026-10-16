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

static void setup_hosts(void) {
    gGateSel = sel_registerName("needToShowSplashWithLaunchType:launchUrl:launchOptions:");
    gManageCls = BDRSMakeClass("BDNCUIAdvertisesManage", Nil);
    CHECK(class_addMethod(gManageCls, gGateSel, (IMP)PhNeedShow, "B40@0:8q16@24@32"));
    gManageHost = [[gManageCls alloc] init];
    CHECK(gManageHost != nil);
}

// 每次发调用的统一入口：断言原实现严格 +1，并回传它这次的返回原值。
// 计数用 before/after 增量，测试自己的准备动作不算进产品动作。
static bool SendAndCount(id host, NSInteger launchType, id url, id options) {
    unsigned before = gCalls;
    bool got = BDRSSendGate(host, launchType, url, options);
    CHECK(gCalls == before + 1);            // 每次调用，原实现只跑一次
    return got;
}

#pragma mark - 测试

// 安装前：槽是空的，调用直接落到原实现。
static void test_before_install(void) {
    CHECK(BDFRSpecResumeSplashGate.installed == NO);
    CHECK(BDFROrigResumeSplashGate == NULL);
    gCalls = 0;
    gOriginalResult = true;
    CHECK(BDRSSendGate(gManageHost, 3, nil, nil) == true);   // 没有 hook：原样
    CHECK(gCalls == 1);
    CHECK(gSeenSelf == gManageHost);
    CHECK(gSeenCmd == gGateSel);
    CHECK(gSeenType == 3);
}

// 安装：挂上 hook，orig 槽指向真实原实现（不是 hook 自己）。
static void test_install(void) {
    unsigned logsBefore = gLogLines;
    BDRSInstallAll();
    CHECK(BDFRSpecResumeSplashGate.installed == YES);
    CHECK(BDFROrigResumeSplashGate == (IMP)PhNeedShow);
    CHECK(BDFROrigResumeSplashGate != (IMP)BDRSNeedShowSplash);   // orig 不自指
    CHECK(class_getMethodImplementation(object_getClass(gManageHost), gGateSel)
          == (IMP)BDRSNeedShowSplash);
    CHECK(gLogLines == logsBefore + 1);      // 只有 installed 一行
    CHECK(gCalls == 1);                      // 安装过程不调用原实现
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

// 重复安装：不动 IMP、orig 不自指、原实现仍然每次只跑一次（不递归）。
static void test_idempotent_reinstall(void) {
    IMP before = class_getMethodImplementation(object_getClass(gManageHost), gGateSel);
    unsigned logsBefore = gLogLines;
    gEnabled = YES; gDumpOnly = NO; gAdMethods = YES;
    gOriginalResult = true;

    BDRSInstallAll();
    BDRSInstallAll();
    CHECK(BDFRSpecResumeSplashGate.installed == YES);
    CHECK(class_getMethodImplementation(object_getClass(gManageHost), gGateSel) == before);
    CHECK(BDFROrigResumeSplashGate == (IMP)PhNeedShow);              // 没被覆盖成 hook
    CHECK(BDFROrigResumeSplashGate != (IMP)BDRSNeedShowSplash);
    CHECK(gLogLines == logsBefore + 2);        // 共享安装器对已装 spec 各打一行「already installed」
    CHECK(SendAndCount(gManageHost, 0, nil, nil) == false);          // 冷启动 0：转发正常，计数 +1 不递归
    CHECK(SendAndCount(gManageHost, 2, nil, nil) == false);          // 热启动 2 同样
    CHECK(gLogLines == logsBefore + 2);                              // 重复安装不再产生 hit
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

    // 以上任何一次失败都不许影响真实那条 spec
    CHECK(BDFRSpecResumeSplashGate.installed == YES);
    CHECK(BDFROrigResumeSplashGate == (IMP)PhNeedShow);
    CHECK(class_getMethodImplementation(object_getClass(gManageHost), gGateSel)
          == (IMP)BDRSNeedShowSplash);
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
        test_idempotent_reinstall();
        test_skip_paths();

        printf("%s: %d 项失败（日志 %u 行，原实现共 %u 次）\n",
               gFailures ? "FAIL" : "PASS", gFailures, gLogLines, gCalls);
    }
    return gFailures ? 1 : 0;
}
