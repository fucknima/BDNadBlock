// tests/feature_removal_test.mm — FeatureRemoval.h 的 macOS host 机制测试
//
// 用动态 fake 类 + 真实同名 selector 跑真实安装器；开关用内存里的假函数，
// 不碰 NSUserDefaults，不写任何文件，不连网。
//
// 这不是真机测试：只证明「匹配时抑制 / 签名或方法不符时 skip / 透传原实现 / 幂等不递归 /
// 不动父类 / 一对校验不完整就一个都不装」这些机制。真机布局与网络行为仍需实测。
//
// 构建运行（macOS，无需 IPA，无需 Theos）：
//   clang++ -std=c++17 -fobjc-arc -fblocks -Wall -Wextra -Werror \
//     -framework Foundation -o /tmp/feature_removal_test tests/feature_removal_test.mm
//   /tmp/feature_removal_test

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdio.h>
#include <string.h>

#pragma mark - 假开关 / 假日志（FeatureRemoval.h 依赖这些同名静态函数）

static BOOL gEnabled = YES;
static BOOL gDumpOnly = NO;
static BOOL gRemoveRecommend = YES;
static BOOL gRemoveGameCenter = YES;
static BOOL gRemoveJobNovel = YES;
static unsigned gLogLines = 0;

static void BDLog(NSString *fmt, ...) {
    (void)fmt;          // 只数行数；测试不比对日志文本
    gLogLines++;
}
static BOOL BDEnabled(void) { return gEnabled; }
static BOOL BDDumpOnly(void) { return gDumpOnly; }
static BOOL BDRemoveRecommend(void) { return gRemoveRecommend; }
static BOOL BDRemoveGameCenter(void) { return gRemoveGameCenter; }
static BOOL BDRemoveJobNovel(void) { return gRemoveJobNovel; }

#include "../FeatureRemoval.h"

#pragma mark - 断言与小工具

static int gFailures = 0;

#define CHECK(cond)                                                        \
    do {                                                                   \
        if (!(cond)) {                                                     \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
            gFailures++;                                                   \
        }                                                                  \
    } while (0)

// 动态 fake 类：名字必须唯一，注册失败（重名或已被占用）要立刻暴露。
static Class BDFRMakeClass(const char *name, Class super) {
    Class c = objc_allocateClassPair(super ? super : [NSObject class], name, 0);
    CHECK(c != nil);
    if (c) objc_registerClassPair(c);
    return c;
}

// 取「当前生效的 IMP」直接调用：既避免 objc_msgSend 声明/ARC 家族的坑，
// 又正好验证安装后运行时查到的就是替换实现。B 编码的返回用内建 bool（见 FeatureRemoval.h）。
static bool BDFRSendBool(id receiver, SEL sel) {
    bool (*imp)(id, SEL) =
        (bool (*)(id, SEL))class_getMethodImplementation(object_getClass(receiver), sel);
    return imp(receiver, sel);
}
static NSInteger BDFRSendCount(id receiver, SEL sel, id first, NSInteger second) {
    NSInteger (*imp)(id, SEL, id, NSInteger) =
        (NSInteger (*)(id, SEL, id, NSInteger))class_getMethodImplementation(object_getClass(receiver), sel);
    return imp(receiver, sel, first, second);
}

static BDFRSpec BDFRTestSpec(const char *cls, const char *sel, BOOL isClassMethod,
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

#pragma mark - 替身实现

// B 编码的替身实现用内建 bool 作为返回值（与 "B16@0:8" 一致，不用 BOOL）。
static unsigned gBoolNoCalls = 0;                  // 原实现被调次数
static unsigned gBoolYesCalls = 0;                 // 替换实现被调次数（分开数，否则证明不了谁被调）
static bool PhBoolNo(id self, SEL _cmd) {          // 当「原实现」：恒 false
    (void)self; (void)_cmd;
    gBoolNoCalls++;
    return false;
}
static bool PhBoolYes(id self, SEL _cmd) {         // 当「替换实现」：恒 true
    (void)self; (void)_cmd;
    gBoolYesCalls++;
    return true;
}

// 三个真实目标方法在 fake 类里的原实现：返回值可调，记录收到的参数。
static bool gHomeRecommend = true;
static unsigned gHomeRecommendCalls = 0;
static bool PhHomeRecommend(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    gHomeRecommendCalls++;
    return gHomeRecommend;
}

static NSInteger gRowCount = 7;
static id gSeenTableView = nil;
static NSInteger gSeenSection = -1;
static NSInteger PhRowCount(id self, SEL _cmd, id tableView, NSInteger section) {
    (void)self; (void)_cmd;
    gSeenTableView = tableView;
    gSeenSection = section;
    return gRowCount;
}

static bool gGameCenter = true;
static bool PhGameCenter(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return gGameCenter;
}

#pragma mark - 金刚区替身（真名 fake 类，getter + q 编码 accessor）

// 原 getter 的返回值与调用次数：用来证明「只调一次原实现」。
static NSArray *gKongSource;
static unsigned gKongOrigCalls;

static id PhKongCache(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    gKongOrigCalls++;
    return gKongSource;      // 原样返回同一个对象（不 copy），便于核对 identity
}

// -[BDPanFHKingKongsModel kingKongId] 的替身：用关联对象存 id，避免子类化或改 ivar 布局。
// 用 class_addMethod 指定 q16@0:8，和真方法一样走 runtime 校验。
static NSInteger PhKongID(id self, SEL _cmd) {
    (void)_cmd;
    NSNumber *n = objc_getAssociatedObject(self, (const void *)&gKongSource);
    return n ? n.longLongValue : -1;
}

static id BDFRMakeKongModel(NSInteger kingKongId) {
    id m = [[NSClassFromString(@"BDPanFHKingKongsModel") alloc] init];
    objc_setAssociatedObject(m, (const void *)&gKongSource, @(kingKongId), OBJC_ASSOCIATION_RETAIN);
    return m;
}

// 装 fake 金刚区：model 类（q16@0:8 accessor）+ config 类（@16@0:8 类方法）。
static void BDFRSetupKongClasses(void) {
    Class model = BDFRMakeClass("BDPanFHKingKongsModel", Nil);
    CHECK(class_addMethod(model, sel_registerName("kingKongId"),
                          (IMP)PhKongID, "q16@0:8"));
    Class cfg = BDFRMakeClass("BDPanFeedHomeConfig", Nil);
    CHECK(class_addMethod(object_getClass(cfg),
                          sel_registerName("cacheKingKongsConfigArray"),
                          (IMP)PhKongCache, "@16@0:8"));
}


#pragma mark - 机制测试（失败路径：类/方法/签名不符必须 skip 且不改任何东西）

static void test_missing_class_or_selector(void) {
    // 类不存在
    IMP orig = NULL;
    BDFRSpec s = BDFRTestSpec("BDFRPhantomMissing", "phantomBool", NO,
                              "B16@0:8", 2, (IMP)PhBoolYes, &orig, "t-missing");
    CHECK(BDFRInstallSpec(&s) == NO);
    CHECK(s.installed == NO);
    CHECK(orig == NULL);

    // 类存在，但 selector 不在它自己的方法表里 -> 同样 skip，什么都不改
    Class c = BDFRMakeClass("BDFRPhantomNoSel", Nil);
    IMP orig2 = NULL;
    BDFRSpec s2 = BDFRTestSpec("BDFRPhantomNoSel", "phantomMissing", NO,
                               "B16@0:8", 2, (IMP)PhBoolYes, &orig2, "t-nosel");
    CHECK(BDFRInstallSpec(&s2) == NO);
    CHECK(s2.installed == NO);
    CHECK(orig2 == NULL);
    CHECK(class_getInstanceMethod(c, sel_registerName("phantomMissing")) == NULL);
}

static void test_inherited_method_not_touched(void) {
    Class parent = BDFRMakeClass("BDFRPhantomParent", Nil);
    CHECK(class_addMethod(parent, sel_registerName("phantomInherited"), (IMP)PhBoolNo, "B16@0:8"));
    Class child = BDFRMakeClass("BDFRPhantomChild", parent);   // child 自己没实现，只有继承

    SEL sel = sel_registerName("phantomInherited");
    IMP before = method_getImplementation(class_getInstanceMethod(parent, sel));
    CHECK(before == (IMP)PhBoolNo);

    IMP orig = NULL;
    BDFRSpec s = BDFRTestSpec("BDFRPhantomChild", "phantomInherited", NO,
                              "B16@0:8", 2, (IMP)PhBoolYes, &orig, "t-inherited");
    CHECK(BDFRInstallSpec(&s) == NO);             // child 自己没有这个方法 -> 跳过
    CHECK(s.installed == NO);
    // 父类的 Method 槽没被碰过，child 仍走父类实现
    CHECK(method_getImplementation(class_getInstanceMethod(parent, sel)) == before);
    CHECK(method_getImplementation(class_getInstanceMethod(child, sel)) == before);
    CHECK(BDFRSendBool([[child alloc] init], sel) == false);   // 走的是原实现，不是替换实现
}

static void test_encoding_and_argc_mismatch(void) {
    Class c = BDFRMakeClass("BDFRPhantomBadEnc", Nil);
    CHECK(class_addMethod(c, sel_registerName("phantomBool"), (IMP)PhBoolNo, "B16@0:8"));
    SEL sel = sel_registerName("phantomBool");

    IMP orig = NULL;
    BDFRSpec bad = BDFRTestSpec("BDFRPhantomBadEnc", "phantomBool", NO,
                                "B24@0:8@16", 2, (IMP)PhBoolYes, &orig, "t-badenc");
    CHECK(BDFRInstallSpec(&bad) == NO);

    IMP orig2 = NULL;
    BDFRSpec badArgc = BDFRTestSpec("BDFRPhantomBadEnc", "phantomBool", NO,
                                    "B16@0:8", 3, (IMP)PhBoolYes, &orig2, "t-argc");
    CHECK(BDFRInstallSpec(&badArgc) == NO);

    CHECK(method_getImplementation(class_getInstanceMethod(c, sel)) == (IMP)PhBoolNo);
    CHECK(BDFRSendBool([[c alloc] init], sel) == false);
    CHECK(orig == NULL && orig2 == NULL);
}

// H1+H2 那种「一对」：任一条校验失败，两条都不许装。
static void test_pair_checked_before_install(void) {
    Class ok = BDFRMakeClass("BDFRPhantomPairOk", Nil);
    CHECK(class_addMethod(ok, sel_registerName("phantomBool"), (IMP)PhBoolNo, "B16@0:8"));
    SEL sel = sel_registerName("phantomBool");

    IMP origA = NULL;
    IMP origB = NULL;
    BDFRSpec a = BDFRTestSpec("BDFRPhantomPairOk", "phantomBool", NO,
                              "B16@0:8", 2, (IMP)PhBoolYes, &origA, "t-pair-ok");
    BDFRSpec b = BDFRTestSpec("BDFRPhantomPairMissing", "phantomBool", NO,
                              "B16@0:8", 2, (IMP)PhBoolYes, &origB, "t-pair-missing");
    CHECK(BDFRInstallPair(&a, &b) == NO);
    CHECK(a.installed == NO && b.installed == NO);
    CHECK(origA == NULL && origB == NULL);
    // 通过校验的那条也不许被装
    CHECK(method_getImplementation(class_getInstanceMethod(ok, sel)) == (IMP)PhBoolNo);
    CHECK(BDFRSendBool([[ok alloc] init], sel) == false);      // 抑制开着也走原实现
}

// A 的槽里已经就是「本 hook」，但 A 没标 installed（例如另一个 spec 用同一个 hook 装过）：
// Pair 必须整体拒绝，B 不许被改，两个 orig 都不许被写。
static void test_pair_refuses_when_slot_is_our_hook(void) {
    Class ca = BDFRMakeClass("BDFRPhantomCollideA", Nil);
    Class cb = BDFRMakeClass("BDFRPhantomCollideB", Nil);
    SEL sel = sel_registerName("phantomBool");
    CHECK(class_addMethod(ca, sel, (IMP)PhBoolYes, "B16@0:8"));   // 槽已是替换实现，但没走安装器
    CHECK(class_addMethod(cb, sel, (IMP)PhBoolNo, "B16@0:8"));

    IMP origA = NULL;
    IMP origB = NULL;
    BDFRSpec a = BDFRTestSpec("BDFRPhantomCollideA", "phantomBool", NO,
                              "B16@0:8", 2, (IMP)PhBoolYes, &origA, "t-collide-a");
    BDFRSpec b = BDFRTestSpec("BDFRPhantomCollideB", "phantomBool", NO,
                              "B16@0:8", 2, (IMP)PhBoolYes, &origB, "t-collide-b");
    CHECK(BDFRInstallPair(&a, &b) == NO);
    CHECK(a.installed == NO && b.installed == NO);
    CHECK(origA == NULL && origB == NULL);
    CHECK(method_getImplementation(class_getInstanceMethod(ca, sel)) == (IMP)PhBoolYes);  // A 没被动
    CHECK(method_getImplementation(class_getInstanceMethod(cb, sel)) == (IMP)PhBoolNo);   // B 没被改
    CHECK(BDFRSendBool([[cb alloc] init], sel) == false);                                 // B 仍是原实现
}

static void test_install_success_and_idempotent(void) {
    Class c = BDFRMakeClass("BDFRPhantomOk", Nil);
    CHECK(class_addMethod(c, sel_registerName("phantomBool"), (IMP)PhBoolNo, "B16@0:8"));
    SEL sel = sel_registerName("phantomBool");

    IMP orig = NULL;
    BDFRSpec s = BDFRTestSpec("BDFRPhantomOk", "phantomBool", NO,
                              "B16@0:8", 2, (IMP)PhBoolYes, &orig, "t-ok");
    CHECK(BDFRInstallSpec(&s) == YES);
    CHECK(s.installed == YES);
    CHECK(orig == (IMP)PhBoolNo);                 // 存的是原实现，不是 replacement
    CHECK(method_getImplementation(class_getInstanceMethod(c, sel)) == (IMP)PhBoolYes);

    id obj = [[c alloc] init];
    CHECK(BDFRSendBool(obj, sel) == true);        // 抑制开 -> replacement

    // 同一 spec 重复安装：认幂等，不重复包装
    CHECK(BDFRInstallSpec(&s) == YES);
    CHECK(orig == (IMP)PhBoolNo);
    CHECK(method_getImplementation(class_getInstanceMethod(c, sel)) == (IMP)PhBoolYes);

    // 另一个 spec 对象但同一个 hook 函数：绝不把自己（或别人的 replacement）存成 original
    IMP again = NULL;
    BDFRSpec s2 = BDFRTestSpec("BDFRPhantomOk", "phantomBool", NO,
                               "B16@0:8", 2, (IMP)PhBoolYes, &again, "t-ok-dup");
    CHECK(BDFRInstallSpec(&s2) == NO);
    CHECK(again == NULL);
    CHECK(s2.installed == NO);
    CHECK(method_getImplementation(class_getInstanceMethod(c, sel)) == (IMP)PhBoolYes);

    // 装了替换实现后，原实现不再被调用；重复安装也不会让它被调两次（这里 hook 是哑替身，
    // 真正「透传 + 不递归」的验证在 test_real_specs 用真实 hook 做）
    unsigned beforeNo = gBoolNoCalls;
    unsigned beforeYes = gBoolYesCalls;
    CHECK(BDFRSendBool(obj, sel) == true);
    CHECK(gBoolNoCalls == beforeNo);              // 原 false 实现确实没被调
    CHECK(gBoolYesCalls == beforeYes + 1);        // 命中的就是替换实现
}

#pragma mark - 三个真实 spec + 真实同名类/selector

static Class gHomeCfg;      // BHSettings
static Class gRowsCtrl;     // BDPanNewMSHContentViewController
static Class gPersonalCfg;  // BDPanPersonalConfig

static void test_real_specs(void) {
    CHECK(objc_getClass("BHSettings") == NULL);
    CHECK(objc_getClass("BDPanNewMSHContentViewController") == NULL);
    CHECK(objc_getClass("BDPanPersonalConfig") == NULL);

    gHomeCfg = BDFRMakeClass("BHSettings", Nil);
    gRowsCtrl = BDFRMakeClass("BDPanNewMSHContentViewController", Nil);
    gPersonalCfg = BDFRMakeClass("BDPanPersonalConfig", Nil);
    CHECK(class_addMethod(object_getClass(gHomeCfg),
                          sel_registerName("isMSHSwitchTypeHomeRecommend"),
                          (IMP)PhHomeRecommend, "B16@0:8"));
    CHECK(class_addMethod(gRowsCtrl,
                          sel_registerName("tableView:numberOfRowsInSection:"),
                          (IMP)PhRowCount, "q32@0:8@16q24"));
    CHECK(class_addMethod(object_getClass(gPersonalCfg),
                          sel_registerName("gameCenterSwitch"),
                          (IMP)PhGameCenter, "B16@0:8"));

    SEL homeSel = sel_registerName("isMSHSwitchTypeHomeRecommend");
    SEL rowSel = sel_registerName("tableView:numberOfRowsInSection:");
    SEL gameSel = sel_registerName("gameCenterSwitch");
    id rows = [[gRowsCtrl alloc] init];
    NSObject *tv = [NSObject new];

    // 0) 安装前：三个目标都还是原实现的原值（说明后面的抑制确实来自替换实现）
    CHECK(BDFRSendBool((id)gHomeCfg, homeSel) == true);
    CHECK(BDFRSendCount(rows, rowSel, tv, 3) == 7);
    CHECK(gSeenTableView == tv && gSeenSection == 3);
    CHECK(BDFRSendBool((id)gPersonalCfg, gameSel) == true);

    unsigned logsBefore = gLogLines;
    BDFRInstallAll();     // H1+H2 一对 + H3 独立 + H4（依赖校验通过）
    CHECK(BDFRSpecHomeRecommend.installed && BDFRSpecHomeRowCount.installed
          && BDFRSpecGameCenter.installed && BDFRSpecKingKongsCache.installed);
    CHECK(*BDFRSpecHomeRecommend.orig == (IMP)PhHomeRecommend);
    CHECK(*BDFRSpecHomeRowCount.orig == (IMP)PhRowCount);
    CHECK(*BDFRSpecGameCenter.orig == (IMP)PhGameCenter);
    CHECK(*BDFRSpecKingKongsCache.orig == (IMP)PhKongCache);
    CHECK(gLogLines == logsBefore + 4);           // 四条 installed 日志
    logsBefore = gLogLines;                       // 往后只数 hit 日志

    // 1) 默认（三个开关都开）：首页整块与游戏都被抑制
    CHECK(BDFRSendBool((id)gHomeCfg, homeSel) == false);
    CHECK(BDFRSendCount(rows, rowSel, (id)@"tv", 5) == 0);
    CHECK(BDFRSendBool((id)gPersonalCfg, gameSel) == false);

    // 2) 各自关掉抑制 -> 透传原实现原值；H2 还要把参数原样传下去
    gRemoveRecommend = NO;
    CHECK(BDFRSendBool((id)gHomeCfg, homeSel) == true);
    CHECK(BDFRSendCount(rows, rowSel, tv, 9) == 7);
    CHECK(gSeenTableView == tv && gSeenSection == 9);
    CHECK(BDFRSendBool((id)gPersonalCfg, gameSel) == false);   // 推荐开关不影响游戏
    gRemoveRecommend = YES;

    gRemoveGameCenter = NO;
    CHECK(BDFRSendBool((id)gPersonalCfg, gameSel) == true);
    CHECK(BDFRSendBool((id)gHomeCfg, homeSel) == false);       // 游戏开关不影响首页
    gRemoveGameCenter = YES;

    // 3) dump-only 与总开关都要透传（H2 连参数一起透传）
    gDumpOnly = YES;
    CHECK(BDFRSendBool((id)gHomeCfg, homeSel) == true);
    CHECK(BDFRSendCount(rows, rowSel, tv, 11) == 7);
    CHECK(gSeenTableView == tv && gSeenSection == 11);
    CHECK(BDFRSendBool((id)gPersonalCfg, gameSel) == true);
    gDumpOnly = NO;

    gEnabled = NO;
    CHECK(BDFRSendBool((id)gHomeCfg, homeSel) == true);
    CHECK(BDFRSendCount(rows, rowSel, tv, 1) == 7);
    CHECK(BDFRSendBool((id)gPersonalCfg, gameSel) == true);
    gEnabled = YES;

    // 4) hit 日志每个 hook 只打一次（dispatch_once），多打几次不再增加
    for (int i = 0; i < 5; i++) {
        (void)BDFRSendBool((id)gHomeCfg, homeSel);
        (void)BDFRSendCount(rows, rowSel, tv, i);
        (void)BDFRSendBool((id)gPersonalCfg, gameSel);
    }
    CHECK(gLogLines == logsBefore + 3);           // 三个 hook 各一行首次 hit

    // 5) 幂等：再装一次不重复包装、不递归
    BDFRInstallAll();
    CHECK(*BDFRSpecHomeRowCount.orig == (IMP)PhRowCount);
    CHECK(method_getImplementation(class_getClassMethod(gHomeCfg, homeSel))
          == (IMP)BDFRHomeRecommend);
    CHECK(method_getImplementation(class_getInstanceMethod(gRowsCtrl, rowSel))
          == (IMP)BDFRHomeRowCount);

    unsigned calls = gHomeRecommendCalls;
    gRemoveRecommend = NO;
    CHECK(BDFRSendBool((id)gHomeCfg, homeSel) == true);
    CHECK(gHomeRecommendCalls == calls + 1);      // 原实现只被调一次
    gRemoveRecommend = YES;
}

#pragma mark - H4：金刚区数组过滤（真名 fake 类 + 真实 FeatureRemoval.h）

// ids 逐个变成真实 model（关联的 NSNumber 就是它的 kingKongId）。
static NSArray *BDFRKongArray(NSArray *ids) {
    NSMutableArray *a = [NSMutableArray array];
    for (NSNumber *n in ids) [a addObject:BDFRMakeKongModel(n.longLongValue)];
    return a;
}
// 15 个连续 id，模拟真实金刚区（其中 6=小说、13=求职）。
static NSArray *BDFRKongArray1To15(void) {
    NSMutableArray *a = [NSMutableArray array];
    for (NSInteger i = 1; i <= 15; i++) [a addObject:BDFRMakeKongModel(i)];
    return a;
}
static NSArray *BDFRSendKongArray(id cfg, SEL sel) {
    id (*imp)(id, SEL) = (id (*)(id, SEL))class_getMethodImplementation(object_getClass(cfg), sel);
    return (NSArray *)imp(cfg, sel);   // 返回类型按 @16@0:8 就是 id；测试按 NSArray * 用
}

// H4 安装**之前**跑（此刻槽里还是原实现）：原 getter 原样透传同一个数组对象。
// 必须排在 test_real_specs 的 BDFRInstallAll() 之前 —— 那之后槽里已经是替换实现。
static void test_kong_getter_before_install(void) {
    Class cfg = NSClassFromString(@"BDPanFeedHomeConfig");
    SEL sel = sel_registerName("cacheKingKongsConfigArray");
    CHECK(cfg != Nil);
    CHECK(BDFRSpecKingKongsCache.installed == NO);

    NSArray *full = BDFRKongArray(@[@1, @13, @2, @6, @3]);
    gKongSource = full;
    gKongOrigCalls = 0;
    CHECK(BDFRSendKongArray((id)cfg, sel) == full);      // 同一个对象，没被复制
    CHECK(gKongOrigCalls == 1);                          // 原 getter 确实被调了一次
}

// H4 已由 test_real_specs 里的 BDFRInstallAll() 装上，这里只验证过滤行为。
static void test_kong_filter(void) {
    Class cfg = NSClassFromString(@"BDPanFeedHomeConfig");
    SEL sel = sel_registerName("cacheKingKongsConfigArray");
    CHECK(cfg != Nil);
    CHECK(BDFRSpecKingKongsCache.installed == YES);
    CHECK(*BDFRSpecKingKongsCache.orig == (IMP)PhKongCache);   // orig 槽里是原实现，不是替换实现

    // 1) 15 个真实 model：6/13 被去掉，其余 13 个同对象同顺序；原 getter 只被调一次
    NSArray *all = BDFRKongArray1To15();
    gKongSource = all;
    unsigned before = gKongOrigCalls;
    unsigned logsBefore = gLogLines;
    NSArray *out = BDFRSendKongArray((id)cfg, sel);
    CHECK(gKongOrigCalls == before + 1);                 // 只穿透一次原实现
    CHECK(out != all);                                   // 有真移除 -> 新数组
    CHECK([out isKindOfClass:[NSArray class]]);
    CHECK(out.count == 13);
    for (NSUInteger i = 0, j = 0; i < 15; i++) {
        id original = [all objectAtIndex:i];
        if (i == 5 || i == 12) continue;                // id 6 / 13 被去掉
        CHECK([out objectAtIndex:j] == original);        // identity 与顺序都不变
        j++;
    }
    CHECK(gLogLines == logsBefore + 1);                  // 首次真移除才 hit

    // 2) 无网络兜底数组（default 分支）同样含 6/13：一样被滤掉
    NSArray *fallback = BDFRKongArray(@[@1, @2, @3, @4, @5, @6, @7, @13, @8, @9, @10]);
    gKongSource = fallback;
    before = gKongOrigCalls;
    out = BDFRSendKongArray((id)cfg, sel);
    CHECK(gKongOrigCalls == before + 1);
    CHECK(out.count == 9);
    for (id kept in out) CHECK([fallback containsObject:kept]);
    CHECK([out objectAtIndex:5] == [fallback objectAtIndex:6]);   // id 7 顺次上移
    CHECK([out objectAtIndex:6] == [fallback objectAtIndex:8]);   // id 8 顺次上移

    // 3) 只有真正的 model 才按 id 过滤：NSString / NSNull / NSNumber 都原样保留、不发 kingKongId。
    // 先存成变量再比 identity —— 直接和字面量比会踩 -Wobjc-string-compare。
    NSString *strayStr = @"not-a-model";
    NSNull *strayNull = [NSNull null];
    NSNumber *strayNum = @13;                            // 数值对，但不是 model 实例
    id jobModel = BDFRMakeKongModel(13);
    id novelModel = BDFRMakeKongModel(6);
    id keepModel = BDFRMakeKongModel(5);
    NSMutableArray *mixed = [NSMutableArray array];
    [mixed addObjectsFromArray:@[strayStr, jobModel, strayNull, novelModel, keepModel, strayNum]];
    gKongSource = mixed;
    before = gKongOrigCalls;
    out = BDFRSendKongArray((id)cfg, sel);
    CHECK(gKongOrigCalls == before + 1);
    CHECK(out.count == 4);                               // 只掉了两个真 model
    CHECK([out objectAtIndex:0] == strayStr);
    CHECK([out objectAtIndex:1] == strayNull);
    CHECK([out objectAtIndex:2] == keepModel);
    CHECK([out objectAtIndex:3] == strayNum);            // NSNumber 不是 model，不该被滤

    // 4) 没有目标项：返回**同一个原数组**（identity），且不再 hit
    NSArray *keep = BDFRKongArray(@[@1, @2, @3]);
    gKongSource = keep;
    before = gKongOrigCalls;
    logsBefore = gLogLines;
    out = BDFRSendKongArray((id)cfg, sel);
    CHECK(out == keep);
    CHECK(gKongOrigCalls == before + 1);
    CHECK(gLogLines == logsBefore);                      // 没移除就不 hit

    // 5) 全被过滤：返回非 nil 空数组
    gKongSource = BDFRKongArray(@[@6, @13]);
    before = gKongOrigCalls;
    out = BDFRSendKongArray((id)cfg, sel);
    CHECK(out != nil);
    CHECK([out isKindOfClass:[NSArray class]]);
    CHECK(out.count == 0);
    CHECK(gKongOrigCalls == before + 1);

    // 6) nil / 非数组 / 空数组：原样透传同一个对象
    before = gKongOrigCalls;
    gKongSource = nil;
    CHECK(BDFRSendKongArray((id)cfg, sel) == nil);
    gKongSource = (NSArray *)@"not-an-array";
    CHECK(BDFRSendKongArray((id)cfg, sel) == gKongSource);
    gKongSource = @[];
    CHECK(BDFRSendKongArray((id)cfg, sel) == gKongSource);
    CHECK(gKongOrigCalls == before + 3);                 // 三次都透传到原实现

    // 7) 总开关 / 诊断 / 独立开关关掉 -> 返回同一个原对象（原行为）
    NSArray *sw = BDFRKongArray(@[@1, @13, @6]);
    gKongSource = sw;
    gRemoveJobNovel = NO;
    CHECK(BDFRSendKongArray((id)cfg, sel) == sw);
    gRemoveJobNovel = YES;
    gDumpOnly = YES;
    CHECK(BDFRSendKongArray((id)cfg, sel) == sw);
    gDumpOnly = NO;
    gEnabled = NO;
    CHECK(BDFRSendKongArray((id)cfg, sel) == sw);
    gEnabled = YES;

    // 8) 幂等：重复安装不重装、不递归，orig 槽不被覆盖；调用仍只穿透一次原实现
    gKongSource = sw;
    before = gKongOrigCalls;
    CHECK(BDFRInstallKingKongs() == YES);
    CHECK(gKongOrigCalls == before);                     // 安装本身不调用 getter
    CHECK(*BDFRSpecKingKongsCache.orig == (IMP)PhKongCache);
    out = BDFRSendKongArray((id)cfg, sel);
    CHECK(out.count == 1);                               // 只剩 id 1
    CHECK(gKongOrigCalls == before + 1);
}

// 依赖校验（安装前 preflight）：依赖不过 -> 目标方法的 IMP 与 orig 槽都不许动；
// 依赖正常 -> 独立的 dummy 目标只装一次。用独立 fake 类，不去改已存在方法的 encoding
// （runtime 也不允许改）。本用例会覆盖运行期的依赖全局，所以放在最后跑。
static void test_kong_dependency_gate(void) {
    Class badModel = BDFRMakeClass("BDFRKongBadIDModel", Nil);
    CHECK(class_addMethod(badModel, sel_registerName("kingKongId"),
                          (IMP)PhBoolNo, "v32@0:8"));     // 故意错的签名
    Class goodModel = BDFRMakeClass("BDFRKongGoodIDModel", Nil);
    CHECK(class_addMethod(goodModel, sel_registerName("kingKongId"),
                          (IMP)PhKongID, "q16@0:8"));
    Class targetCfg = BDFRMakeClass("BDFRKongTargetConfig", Nil);
    CHECK(class_addMethod(object_getClass(targetCfg),
                          sel_registerName("cacheKingKongsConfigArray"),
                          (IMP)PhKongCache, "@16@0:8"));

    SEL cacheSel = sel_registerName("cacheKingKongsConfigArray");
    IMP targetImpBefore = method_getImplementation(class_getClassMethod(targetCfg, cacheSel));

    // a) 依赖签名不符 -> 整条跳过：目标的 IMP 与 orig 都不动
    IMP origBad = NULL;
    BDFRSpec badTarget = BDFRTestSpec("BDFRKongTargetConfig", "cacheKingKongsConfigArray", YES,
                                      "@16@0:8", 2, (IMP)BDFRKingKongsCache, &origBad, "t-kong-bad-dep");
    BDFRSpec badDep = BDFRTestSpec("BDFRKongBadIDModel", "kingKongId", NO,
                                   "q16@0:8", 2, NULL, NULL, "t-kong-bad-dep");
    CHECK(BDFRResolve(&badDep) == NULL);
    CHECK(BDFRInstallKingKongsWith(&badDep, &badTarget) == NO);
    CHECK(badTarget.installed == NO);
    CHECK(origBad == NULL);
    CHECK(method_getImplementation(class_getClassMethod(targetCfg, cacheSel)) == targetImpBefore);

    // b) 依赖类缺失 -> 同样什么都不动
    IMP origMissing = NULL;
    BDFRSpec missingTarget = BDFRTestSpec("BDFRKongTargetConfig", "cacheKingKongsConfigArray", YES,
                                          "@16@0:8", 2, (IMP)BDFRKingKongsCache, &origMissing, "t-kong-missing-dep");
    BDFRSpec missingDep = BDFRTestSpec("BDFRKongIDModelMissing", "kingKongId", NO,
                                       "q16@0:8", 2, NULL, NULL, "t-kong-missing-dep");
    CHECK(BDFRInstallKingKongsWith(&missingDep, &missingTarget) == NO);
    CHECK(missingTarget.installed == NO);
    CHECK(origMissing == NULL);
    CHECK(method_getImplementation(class_getClassMethod(targetCfg, cacheSel)) == targetImpBefore);

    // c) 依赖正常 -> dummy 目标装得上：orig 存原 IMP、槽换成替换实现、重复安装幂等
    IMP origGood = NULL;
    BDFRSpec goodTarget = BDFRTestSpec("BDFRKongTargetConfig", "cacheKingKongsConfigArray", YES,
                                       "@16@0:8", 2, (IMP)BDFRKingKongsCache, &origGood, "t-kong-good-dep");
    BDFRSpec goodDep = BDFRTestSpec("BDFRKongGoodIDModel", "kingKongId", NO,
                                    "q16@0:8", 2, NULL, NULL, "t-kong-good-dep");
    CHECK(BDFRResolve(&goodDep) != NULL);
    CHECK(BDFRInstallKingKongsWith(&goodDep, &goodTarget) == YES);
    CHECK(goodTarget.installed == YES);
    CHECK(origGood == (IMP)PhKongCache);                       // 原 IMP 被保存
    CHECK(method_getImplementation(class_getClassMethod(targetCfg, cacheSel))
          == (IMP)BDFRKingKongsCache);                         // 槽换成替换实现
    unsigned calls = gKongOrigCalls;
    CHECK(BDFRInstallKingKongsWith(&goodDep, &goodTarget) == YES);   // 幂等：不重装
    CHECK(origGood == (IMP)PhKongCache);
    CHECK(method_getImplementation(class_getClassMethod(targetCfg, cacheSel))
          == (IMP)BDFRKingKongsCache);
    CHECK(gKongOrigCalls == calls);                             // 安装过程不调用 getter
}

#pragma mark - main

int main(void) {
    @autoreleasepool {
        test_missing_class_or_selector();
        test_inherited_method_not_touched();
        test_encoding_and_argc_mismatch();
        test_pair_checked_before_install();
        test_pair_refuses_when_slot_is_our_hook();
        test_install_success_and_idempotent();
        // 金刚区的 fake 类先建好：BDFRInstallAll() 里 H4 的依赖校验要查它们。
        BDFRSetupKongClasses();
        test_kong_getter_before_install();   // 必须早于 BDFRInstallAll()
        test_real_specs();                   // 这里面 BDFRInstallAll() 装上 H4
        test_kong_filter();
        test_kong_dependency_gate();         // 会覆盖依赖全局，放最后

        printf("%s: %d 项失败（日志共 %u 行）\n",
               gFailures ? "FAIL" : "PASS", gFailures, gLogLines);
    }
    return gFailures ? 1 : 0;
}
