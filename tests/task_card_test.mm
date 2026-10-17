// tests/task_card_test.mm — PersonalViewRemoval.h 的 macOS host 机制测试
//
// include 的是**真实**产品头（FeatureRemoval.h + PersonalViewRemoval.h）；假的只有三样：
//   - 假开关 BDEnabled / BDDumpOnly / BDRemoveRecommend / BDRemoveGameCenter / BDRemoveJobNovel /
//     BDRemoveTaskCard / BDRemovePersonalSpaceCard，和假日志 BDLog
//   - 一个**最小声明面**的 UIView（只有 hidden 与 setHidden: 计数）。这不是伪造 UIKit SDK：
//     macOS 上没有 UIKit，这里只声明本产品头唯一用到的那个属性，好让真实 hook 代码原样跑起来。
//   - 两个真实类名的动态 fake section：各自的 -layoutViews(v16@0:8) 与 -pointsCard(@16@0:8)，
//     原 layoutViews 会像真机那样把任务卡 setHidden:NO（可用 fixture 开关关掉）。
//
// 测的是调用/对象边界/开关机制：原 layout 先跑且每次都跑、之后产品把任务卡按回隐藏、
// getter 返回非视图对象时不动手、原布局重显时反复覆盖、已隐藏不重复写也不重复 hit、
// 关闭时完全不碰本组件状态、后台只转发原实现、重复安装不递归、预检不过什么都不写。
// **不证明**真机布局：两卡约束、80/84pt原高度压缩后的实际观感仍需设备验证。
//
// 构建运行（macOS，无需 IPA，无需 Theos）：
//   clang++ -std=c++17 -fobjc-arc -fblocks -Wall -Wextra -Werror \
//     -framework Foundation -o /tmp/task_card_test tests/task_card_test.mm
//   /tmp/task_card_test

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <math.h>

#pragma mark - 假开关 / 假日志

static BOOL gEnabled = YES;
static BOOL gDumpOnly = NO;
static BOOL gRemoveRecommend = YES;
static BOOL gRemoveGameCenter = YES;
static BOOL gRemoveJobNovel = YES;
static BOOL gRemoveTaskCard = YES;
static BOOL gRemovePersonalSpaceCard = NO;   // 旧 fixture 默认关：老用例语义不变，新用例显式打开
static unsigned gLogLines = 0;

static void BDLog(NSString *fmt, ...) { (void)fmt; gLogLines++; }
static BOOL BDEnabled(void) { return gEnabled; }
static BOOL BDDumpOnly(void) { return gDumpOnly; }
static BOOL BDRemoveRecommend(void) { return gRemoveRecommend; }
static BOOL BDRemoveGameCenter(void) { return gRemoveGameCenter; }
static BOOL BDRemoveJobNovel(void) { return gRemoveJobNovel; }
static BOOL BDRemoveTaskCard(void) { return gRemoveTaskCard; }
static BOOL BDRemovePersonalSpaceCard(void) { return gRemovePersonalSpaceCard; }

#pragma mark - 最小 UIView 替身（只声明 hidden；不伪造 UIKit 其它任何东西）

static unsigned gHiddenYESCalls = 0;    // setHidden:YES 的总次数（谁发的都算）
static unsigned gHiddenNOCalls = 0;     // setHidden:NO 的总次数
static unsigned gHiddenReads = 0;       // 读 hidden 的次数

@interface UIView : NSObject
{
    BOOL _hidden;   // 两个访问器都自己实现，clang 不会自动合成 ivar，这里显式声明
}
@property (nonatomic, assign, getter=isHidden) BOOL hidden;
@end

@implementation UIView
- (BOOL)isHidden { gHiddenReads++; return _hidden; }
- (void)setHidden:(BOOL)hidden {
    if (hidden) gHiddenYESCalls++; else gHiddenNOCalls++;
    _hidden = hidden;
}
@end

#pragma mark - 真实产品头（PersonalViewRemoval.h 要求调用方先 import UIKit + FeatureRemoval）

#include "../FeatureRemoval.h"
#include "../PersonalViewRemoval.h"

#pragma mark - 断言与小工具

static int gFailures = 0;

#define CHECK(cond)                                                        \
    do {                                                                   \
        if (!(cond)) {                                                     \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
            gFailures++;                                                   \
        }                                                                  \
    } while (0)

static Class BDTVMakeClass(const char *name, Class super) {
    Class c = objc_allocateClassPair(super ? super : [NSObject class], name, 0);
    CHECK(c != nil);
    if (c) objc_registerClassPair(c);
    return c;
}

static BDFRSpec BDTVSpec(const char *cls, const char *sel, BOOL isClassMethod,
                         const char *enc, unsigned argc, IMP hook,
                         IMP *orig, const char *name) {
    BDFRSpec s;
    s.cls = cls; s.sel = sel; s.isClassMethod = isClassMethod; s.enc = enc;
    s.argc = argc; s.hook = hook; s.orig = orig; s.name = name; s.installed = NO;
    return s;
}

#pragma mark - 两个 fake section 的替身实现

static unsigned gLayoutCallsA = 0, gLayoutCallsB = 0;   // 原 layoutViews 被调次数
static unsigned gGetterCallsA = 0, gGetterCallsB = 0;   // 原 pointsCard 被调次数
static unsigned gSpaceGetterCallsA = 0, gSpaceGetterCallsB = 0;  // 容量卡 getter 被调次数
static unsigned gHeightCallsA = 0, gHeightCallsB = 0;   // 原 heightForView 被调次数
static BOOL gNativeReShow = YES;   // fixture：原 layoutViews 要不要像真机那样把任务卡 setHidden:NO
static BOOL gNativeReShowSpace = NO;  // 容量卡也一样（默认关，避免影响旧用例的计数）

static UIView *gCardA;             // 任务卡（advanced 样式）
static UIView *gCardB;             // 任务卡（legacy 样式）
static id gGetterResultA;          // getter 返回值，可换成 nil / NSString
static id gGetterResultB;
static id gSpaceGetterResultA;     // 容量卡 getter 返回值，可换成 nil / NSString
static id gSpaceGetterResultB;
static UIView *gCapacityA;
static UIView *gCapacityB;
static double gHeightOrigA = 80.0; // 两个 style 的原生常量（真机 ASM：80.0 / 84.0）
static double gHeightOrigB = 84.0;
static id gHeightSeenReceiverA, gHeightSeenReceiverB;
static SEL gHeightSeenSelA, gHeightSeenSelB;

static id FakePointsCardA(id self, SEL _cmd) { (void)self; (void)_cmd; gGetterCallsA++; return gGetterResultA; }
static id FakePointsCardB(id self, SEL _cmd) { (void)self; (void)_cmd; gGetterCallsB++; return gGetterResultB; }
static id FakeSpaceCardA(id self, SEL _cmd)  { (void)self; (void)_cmd; gSpaceGetterCallsA++; return gSpaceGetterResultA; }
static id FakeSpaceCardB(id self, SEL _cmd)  { (void)self; (void)_cmd; gSpaceGetterCallsB++; return gSpaceGetterResultB; }
static double FakeHeightA(id self, SEL _cmd) {
    gHeightCallsA++; gHeightSeenReceiverA = self; gHeightSeenSelA = _cmd;
    return gHeightOrigA;
}
static double FakeHeightB(id self, SEL _cmd) {
    gHeightCallsB++; gHeightSeenReceiverB = self; gHeightSeenSelB = _cmd;
    return gHeightOrigB;
}

static void FakeLayoutA(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    gLayoutCallsA++;
    if (gNativeReShow && [gGetterResultA isKindOfClass:[UIView class]]) {
        [(UIView *)gGetterResultA setHidden:NO];     // 真机上 layoutViews 的 iPhone 分支就是这样
    }
    if (gNativeReShowSpace && [gSpaceGetterResultA isKindOfClass:[UIView class]]) {
        [(UIView *)gSpaceGetterResultA setHidden:NO];   // 容量卡：真机不会，这里只用来测"覆盖回来"
    }
}
static void FakeLayoutB(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    gLayoutCallsB++;
    if (gNativeReShow && [gGetterResultB isKindOfClass:[UIView class]]) {
        [(UIView *)gGetterResultB setHidden:NO];
    }
    if (gNativeReShowSpace && [gSpaceGetterResultB isKindOfClass:[UIView class]]) {
        [(UIView *)gSpaceGetterResultB setHidden:NO];
    }
}

static Class gSectionA, gSectionB;
static id gSectionAInst, gSectionBInst;
static SEL gLayoutSel, gHeightSel;

static void setup_sections(void) {
    gLayoutSel = sel_registerName("layoutViews");
    gHeightSel = sel_registerName("heightForView");
    SEL cardSel = sel_registerName("pointsCard");
    SEL spaceSel = sel_registerName("spaceCard");

    gSectionA = BDTVMakeClass("BDPanPersonalSpaceAndPointSection", Nil);
    CHECK(class_addMethod(gSectionA, gLayoutSel, (IMP)FakeLayoutA, "v16@0:8"));
    CHECK(class_addMethod(gSectionA, cardSel, (IMP)FakePointsCardA, "@16@0:8"));
    CHECK(class_addMethod(gSectionA, spaceSel, (IMP)FakeSpaceCardA, "@16@0:8"));
    CHECK(class_addMethod(gSectionA, gHeightSel, (IMP)FakeHeightA, "d16@0:8"));

    gSectionB = BDTVMakeClass("BDPanPersonalSpaceSection", Nil);
    CHECK(class_addMethod(gSectionB, gLayoutSel, (IMP)FakeLayoutB, "v16@0:8"));
    CHECK(class_addMethod(gSectionB, cardSel, (IMP)FakePointsCardB, "@16@0:8"));
    CHECK(class_addMethod(gSectionB, spaceSel, (IMP)FakeSpaceCardB, "@16@0:8"));
    CHECK(class_addMethod(gSectionB, gHeightSel, (IMP)FakeHeightB, "d16@0:8"));

    gCapacityA = [[UIView alloc] init]; [gCapacityA setHidden:NO];
    gCapacityB = [[UIView alloc] init]; [gCapacityB setHidden:NO];
    gCardA = [[UIView alloc] init]; [gCardA setHidden:NO];
    gCardB = [[UIView alloc] init]; [gCardB setHidden:NO];
    gGetterResultA = gCardA;
    gGetterResultB = gCardB;
    gSpaceGetterResultA = gCapacityA;
    gSpaceGetterResultB = gCapacityB;

    gSectionAInst = [[gSectionA alloc] init];
    gSectionBInst = [[gSectionB alloc] init];
}

static void BDTVCallLayout(Class cls, id inst) {
    void (*imp)(id, SEL) = (void (*)(id, SEL))class_getMethodImplementation(cls, gLayoutSel);
    imp(inst, gLayoutSel);
}

static double BDTVCallHeight(Class cls, id inst) {
    double (*imp)(id, SEL) = (double (*)(id, SEL))class_getMethodImplementation(cls, gHeightSel);
    return imp(inst, gHeightSel);
}

// 依赖隔离用例里只当「替换实现」占位：不调任何原实现，只让 attach 有个不同的 IMP 可比对。
static void PhLayoutHook(id self, SEL _cmd) { (void)self; (void)_cmd; }
static double PhHeightHook(id self, SEL _cmd) { (void)self; (void)_cmd; return 0.0; }

static void BDTVResetCounters(void) {
    gLayoutCallsA = gLayoutCallsB = 0;
    gGetterCallsA = gGetterCallsB = 0;
    gSpaceGetterCallsA = gSpaceGetterCallsB = 0;
    gHeightCallsA = gHeightCallsB = 0;
    gHiddenYESCalls = gHiddenNOCalls = gHiddenReads = 0;
}

#pragma mark - 测试

static void test_before_install(void) {
    CHECK(objc_getClass("BDPanPersonalSpaceAndPointSection") == NULL);
    setup_sections();
    CHECK(BDPVSpecLayoutAndPoint.installed == NO);
    CHECK(BDPVSpecLayoutSpace.installed == NO);

    // 安装前调 layoutViews：只有原实现在跑，什么都不隐藏
    BDTVResetCounters();               // 把 setup_sections 里那几条准备动作的计数清掉
    unsigned logsBefore = gLogLines;
    BDTVCallLayout(gSectionA, gSectionAInst);
    BDTVCallLayout(gSectionB, gSectionBInst);
    CHECK(gLayoutCallsA == 1);
    CHECK(gLayoutCallsB == 1);
    CHECK(gHiddenYESCalls == 0);
    CHECK(gHiddenNOCalls == 2);          // 只是替身自己发的
    CHECK(gLogLines == logsBefore);

    // 安装前 heightForView 就是原常量（两个 style 各自的 80.0 / 84.0）
    CHECK(BDPVHeightReadyAndPoint == NO);
    CHECK(BDPVHeightReadySpace == NO);
    BDTVResetCounters();
    CHECK(BDTVCallHeight(gSectionA, gSectionAInst) == 80.0);
    CHECK(BDTVCallHeight(gSectionB, gSectionBInst) == 84.0);
    CHECK(gHeightCallsA == 1 && gHeightCallsB == 1);
}

static void test_install_and_hide(void) {
    unsigned logsBefore = gLogLines;
    BDPVInstallAll();
    CHECK(BDPVSpecLayoutAndPoint.installed == YES);
    CHECK(BDPVSpecLayoutSpace.installed == YES);
    CHECK(*BDPVSpecLayoutAndPoint.orig == (IMP)FakeLayoutA);
    CHECK(*BDPVSpecLayoutSpace.orig == (IMP)FakeLayoutB);
    CHECK(*BDPVSpecLayoutAndPoint.orig != (IMP)BDPVLayoutAndPoint);
    CHECK(*BDPVSpecLayoutSpace.orig != (IMP)BDPVLayoutSpace);
    // 依赖槽：各自 class 自己的 pointsCard 原实现，不是别处的
    CHECK(BDPVPointsCardImpAndPoint == (IMP)FakePointsCardA);
    CHECK(BDPVPointsCardImpSpace == (IMP)FakePointsCardB);
    CHECK(BDPVPointsCardSelAndPoint == sel_registerName("pointsCard"));
    CHECK(BDPVPointsCardSelSpace == sel_registerName("pointsCard"));
    CHECK(BDPVSpaceCardImpAndPoint == (IMP)FakeSpaceCardA);
    CHECK(BDPVSpaceCardImpSpace == (IMP)FakeSpaceCardB);
    CHECK(BDPVSpaceCardSelAndPoint == sel_registerName("spaceCard"));
    CHECK(BDPVSpaceCardSelSpace == sel_registerName("spaceCard"));
    // 行高 gate：两个依赖都可用时才装
    CHECK(BDPVHeightReadyAndPoint == YES);
    CHECK(BDPVHeightReadySpace == YES);
    CHECK(BDPVSpecHeightAndPoint.installed == YES);
    CHECK(BDPVSpecHeightSpace.installed == YES);
    CHECK(*BDPVSpecHeightAndPoint.orig == (IMP)FakeHeightA);
    CHECK(*BDPVSpecHeightSpace.orig == (IMP)FakeHeightB);
    CHECK(*BDPVSpecHeightAndPoint.orig != (IMP)BDPVHeightAndPoint);
    CHECK(*BDPVSpecHeightSpace.orig != (IMP)BDPVHeightSpace);
    CHECK(gLogLines == logsBefore + 4);   // 两个 style 各两行 installed（layout + height）

    // 1) 开关全开：原 layout 先跑（每次都跑），之后产品把任务卡按回隐藏
    [gCardA setHidden:NO]; [gCardB setHidden:NO];
    BDTVResetCounters();
    logsBefore = gLogLines;
    BDTVCallLayout(gSectionA, gSectionAInst);
    CHECK(gLayoutCallsA == 1);             // 原实现先且仅一次
    CHECK(gGetterCallsA == 1);             // 只问了一次自己的 getter
    CHECK(gCardA.hidden == YES);           // 被产品按成隐藏
    CHECK(gHiddenYESCalls == 1);
    CHECK(gHiddenNOCalls == 1);            // 那一行 NO 来自原实现
    CHECK(gLogLines == logsBefore + 1);   // 首次真正收起记一行 hit

    // 2) 原布局把卡片重新显示（真机每次 layoutViews 都会这样）-> 产品必须再按回去，
    //    但 hit 不再打。
    BDTVCallLayout(gSectionA, gSectionAInst);
    CHECK(gLayoutCallsA == 2);
    CHECK(gGetterCallsA == 2);
    CHECK(gCardA.hidden == YES);
    CHECK(gHiddenNOCalls == 2);
    CHECK(gHiddenYESCalls == 2);
    CHECK(gLogLines == logsBefore + 1);   // dispatch_once，不再打

    // 3) 同一套语义对 legacy 样式那条同样成立
    BDTVCallLayout(gSectionB, gSectionBInst);
    CHECK(gLayoutCallsB == 1);
    CHECK(gGetterCallsB == 1);
    CHECK(gCardB.hidden == YES);
    CHECK(gLogLines == logsBefore + 2);

    // 4) 容量卡：容量开关默认是关的，所以本产品一次都不该发消息（连 getter 都不问）
    CHECK(gSpaceGetterCallsA == 0);
    CHECK(gSpaceGetterCallsB == 0);
    CHECK(gCapacityA.hidden == NO);       // identity 与 hidden 原样
    CHECK(gCapacityB.hidden == NO);

    // 5) 只藏了任务卡：行高必须原样透传（不能压没仍可见的容量卡那半段）
    BDTVResetCounters();
    CHECK(BDTVCallHeight(gSectionA, gSectionAInst) == 80.0);
    CHECK(BDTVCallHeight(gSectionB, gSectionBInst) == 84.0);
    CHECK(gHeightCallsA == 1 && gHeightCallsB == 1);   // 原实现每次都先被调一次
}

static void test_gate_off_and_bad_getter(void) {
    // 关掉三种 gate 时：原实现照跑、照它自己那样显示，本产品不动 hidden、不发 getter
    for (int i = 0; i < 3; i++) {
        gEnabled = YES; gDumpOnly = NO; gRemoveTaskCard = YES;
        if (i == 0) gEnabled = NO;
        if (i == 1) gDumpOnly = YES;
        if (i == 2) gRemoveTaskCard = NO;

        [gCardA setHidden:NO];
        BDTVResetCounters();
        unsigned logsBefore = gLogLines;
        BDTVCallLayout(gSectionA, gSectionAInst);
        CHECK(gLayoutCallsA == 1);
        CHECK(gGetterCallsA == 0);        // 开关不生效时不问 getter
        CHECK(gHiddenNOCalls == 1);       // 原实现自己的显示
        CHECK(gHiddenYESCalls == 0);      // 本产品没有再按回去
        CHECK(gCardA.hidden == NO);
        CHECK(gLogLines == logsBefore);   // 没有 hit
    }
    gEnabled = YES; gDumpOnly = NO; gRemoveTaskCard = YES;

    // getter 返回 nil / 非视图对象：一律不动手，也不 hit
    gGetterResultA = nil;
    BDTVResetCounters();
    unsigned logsBefore = gLogLines;
    BDTVCallLayout(gSectionA, gSectionAInst);
    CHECK(gLayoutCallsA == 1);
    CHECK(gGetterCallsA == 1);
    CHECK(gHiddenYESCalls == 0);
    CHECK(gLogLines == logsBefore);

    gGetterResultA = @"not-a-view";
    BDTVResetCounters();
    logsBefore = gLogLines;
    BDTVCallLayout(gSectionA, gSectionAInst);
    CHECK(gGetterCallsA == 1);
    CHECK(gHiddenYESCalls == 0);
    CHECK(gLogLines == logsBefore);
    gGetterResultA = gCardA;
}

static void test_already_hidden_no_duplicate_hit(void) {
    // 原生这次不再把它显示出来（fixture 关掉 re-show），而且它本来就已经是隐藏的：
    // 产品不该再写一次 hidden，也不该再记 hit。
    gNativeReShow = NO;
    [gCardA setHidden:YES];
    BDTVResetCounters();
    unsigned logsBefore = gLogLines;
    BDTVCallLayout(gSectionA, gSectionAInst);
    CHECK(gLayoutCallsA == 1);
    CHECK(gGetterCallsA == 1);
    CHECK(gHiddenReads >= 1);             // 确实读了 hidden 才决定不动手
    CHECK(gHiddenYESCalls == 0);          // 没有重复写
    CHECK(gCardA.hidden == YES);
    CHECK(gLogLines == logsBefore);       // 没有重复 hit
    gNativeReShow = YES;
    [gCardA setHidden:NO];
}

static void test_reinstall_no_recursion(void) {
    unsigned logsBefore = gLogLines;
    BDPVInstallAll();
    CHECK(BDPVSpecLayoutAndPoint.installed == YES);
    CHECK(*BDPVSpecLayoutAndPoint.orig == (IMP)FakeLayoutA);
    CHECK(*BDPVSpecLayoutSpace.orig == (IMP)FakeLayoutB);
    CHECK(*BDPVSpecHeightAndPoint.orig == (IMP)FakeHeightA);   // height 的 orig 也没被覆盖
    CHECK(*BDPVSpecHeightSpace.orig == (IMP)FakeHeightB);
    CHECK(gLogLines == logsBefore + 4);   // 四条 already installed，不是重新 attach

    BDTVResetCounters();
    unsigned hitsBefore = gLogLines;
    BDTVCallLayout(gSectionA, gSectionAInst);
    CHECK(gLayoutCallsA == 1);            // 原实现只跑一次，没有自指递归
    CHECK(gCardA.hidden == YES);
    CHECK(gLogLines == hitsBefore);       // hit token 已消耗，不再打
}

static void test_background_thread(void) {
    // 后台（非主线程）只转发原实现：产品不调 getter、不发 hidden、不改行高、不记 hit。
    // 用 dispatch_group_async + wait（不是在主线程 dispatch_sync 假后台），并在块内核对确实非主线程。
    gEnabled = YES; gDumpOnly = NO; gRemoveTaskCard = YES; gRemovePersonalSpaceCard = YES;
    [gCardA setHidden:NO]; [gCapacityA setHidden:NO];
    BDTVResetCounters();
    unsigned logsBefore = gLogLines;
    __block BOOL offMain = NO;
    __block double gotHeight = -999.0;
    dispatch_group_t grp = dispatch_group_create();
    dispatch_group_async(grp, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        offMain = ![NSThread isMainThread];
        BDTVCallLayout(gSectionA, gSectionAInst);
        gotHeight = BDTVCallHeight(gSectionA, gSectionAInst);
    });
    CHECK(dispatch_group_wait(grp, DISPATCH_TIME_FOREVER) == 0);

    CHECK(offMain == YES);
    CHECK(gLayoutCallsA == 1);            // 原实现被转发
    CHECK(gGetterCallsA == 0);            // 本组件没问 getter
    CHECK(gSpaceGetterCallsA == 0);       // 容量卡也一样
    CHECK(gHiddenNOCalls == 1);           // 只有替身自己那条 NO
    CHECK(gHiddenYESCalls == 0);          // 本组件没发 YES
    CHECK(gotHeight == 80.0);             // 行高原样
    CHECK(gLogLines == logsBefore);       // 也没借道记 hit
}

static BOOL BDTVInstallPhantom(const char *cls,
                               IMP *pImp, SEL *pSel, IMP *sImp, SEL *sSel, BOOL *ready);

static void test_precheck_failures(void) {
    IMP points = NULL, space = NULL;
    SEL pointsSel = NULL, spaceSel = NULL;
    BOOL ready = NO;
    // 1) 依赖签名错（真注册 @32@0:8，spec 期望 @16@0:8）-> 整条跳过
    Class depWrong = BDTVMakeClass("BDTVPhantomDepWrongEnc", Nil);
    CHECK(class_addMethod(depWrong, sel_registerName("pointsCard"), (IMP)FakePointsCardA, "@32@0:8"));
    CHECK(class_addMethod(depWrong, gLayoutSel, (IMP)FakeLayoutA, "v16@0:8"));
    CHECK(BDTVInstallPhantom("BDTVPhantomDepWrongEnc", &points, &pointsSel, &space, &spaceSel, &ready) == NO);
    CHECK(points == NULL && pointsSel == NULL && space == NULL && spaceSel == NULL && !ready);
    CHECK(class_getMethodImplementation(depWrong, gLayoutSel) == (IMP)FakeLayoutA);

    // 2) 目标签名错（真注册 v24@0:8@16，spec 期望 v16@0:8）-> 整条跳过
    Class tgtWrong = BDTVMakeClass("BDTVPhantomTargetWrongEnc", Nil);
    CHECK(class_addMethod(tgtWrong, sel_registerName("pointsCard"), (IMP)FakePointsCardA, "@16@0:8"));
    CHECK(class_addMethod(tgtWrong, gLayoutSel, (IMP)FakeLayoutA, "v24@0:8@16"));
    CHECK(BDTVInstallPhantom("BDTVPhantomTargetWrongEnc", &points, &pointsSel, &space, &spaceSel, &ready) == NO);
    CHECK(points == NULL && pointsSel == NULL && space == NULL && spaceSel == NULL && !ready);
    CHECK(class_getMethodImplementation(tgtWrong, gLayoutSel) == (IMP)FakeLayoutA);

    // 3) 只有继承实现（layoutViews 在父类上）-> 整条跳过，绝不碰父类
    Class base = BDTVMakeClass("BDTVPhantomBase", Nil);
    CHECK(class_addMethod(base, gLayoutSel, (IMP)FakeLayoutA, "v16@0:8"));
    Class sub = BDTVMakeClass("BDTVPhantomSub", base);
    CHECK(class_addMethod(sub, sel_registerName("pointsCard"), (IMP)FakePointsCardA, "@16@0:8"));
    CHECK(BDTVInstallPhantom("BDTVPhantomSub", &points, &pointsSel, &space, &spaceSel, &ready) == NO);
    CHECK(points == NULL && pointsSel == NULL && space == NULL && spaceSel == NULL && !ready);
    // 父类那个槽没被动过
    CHECK(class_getMethodImplementation(base, gLayoutSel) == (IMP)FakeLayoutA);
}

// 只藏容量卡（任务开关关）：容量卡只按自己的开关隐藏、每次 layout 后覆盖回隐藏、
// 行高必须透传（不压没仍可见的任务卡那半段）；nil / 非视图不崩。
static void test_space_first_hit_and_repeat(void) {
    gEnabled = YES; gDumpOnly = NO; gRemoveTaskCard = NO; gRemovePersonalSpaceCard = YES;
    gNativeReShowSpace = YES;             // fixture：原 layout 也把容量卡 setHidden:NO

    [gCapacityA setHidden:NO]; [gCapacityB setHidden:NO];
    [gCardA setHidden:NO]; [gCardB setHidden:NO];
    BDTVResetCounters();
    unsigned logsBefore = gLogLines;
    BDTVCallLayout(gSectionA, gSectionAInst);
    CHECK(gLayoutCallsA == 1);
    CHECK(gSpaceGetterCallsA == 1);       // 只问了一次自己的 spaceCard
    CHECK(gCapacityA.hidden == YES);      // 被按回隐藏
    CHECK(gHiddenYESCalls == 1);
    CHECK(gCardA.hidden == NO);           // 任务开关关：不动任务卡
    CHECK(gGetterCallsA == 0);
    CHECK(gLogLines == logsBefore + 1);   // 每 style 首次真正隐藏一行

    BDTVCallLayout(gSectionA, gSectionAInst);   // 原 layout 又显示 -> 必须再按回去
    CHECK(gCapacityA.hidden == YES);
    CHECK(gLogLines == logsBefore + 1);         // dispatch_once：不再打

    BDTVCallLayout(gSectionB, gSectionBInst);   // legacy 样式同样
    CHECK(gCapacityB.hidden == YES);
    CHECK(gCardB.hidden == NO);
    CHECK(gLogLines == logsBefore + 2);         // 另一 style 的首次

    // 只藏一张：行高透传（80.0 / 84.0）
    BDTVResetCounters();
    CHECK(BDTVCallHeight(gSectionA, gSectionAInst) == 80.0);
    CHECK(BDTVCallHeight(gSectionB, gSectionBInst) == 84.0);
    CHECK(gHeightCallsA == 1 && gHeightCallsB == 1);

    // getter 返回 nil / 非视图：不动手、不 hit、不崩
    gSpaceGetterResultA = nil;
    BDTVResetCounters();
    logsBefore = gLogLines;
    BDTVCallLayout(gSectionA, gSectionAInst);
    CHECK(gSpaceGetterCallsA == 1);
    CHECK(gHiddenYESCalls == 0);
    CHECK(gLogLines == logsBefore);
    gSpaceGetterResultA = @"not-a-view";
    BDTVCallLayout(gSectionA, gSectionAInst);
    CHECK(gHiddenYESCalls == 0);
    CHECK(gLogLines == logsBefore);
    gSpaceGetterResultA = gCapacityA;

    // 关掉开关不主动恢复：隐藏状态保持到下次冷启动（既有契约，本组件从不 setHidden:NO）
    gNativeReShowSpace = NO;
    gNativeReShow = NO;                   // 两个替身都别再自己显示，免得干扰计数
    gRemovePersonalSpaceCard = NO;
    BDTVResetCounters();
    BDTVCallLayout(gSectionA, gSectionAInst);
    CHECK(gSpaceGetterCallsA == 0);       // 门控关：连 getter 都不问
    CHECK(gCapacityA.hidden == YES);      // 也不会替用户恢复
    CHECK(gHiddenNOCalls == 0);
    gNativeReShow = YES;
}

// 两张都藏 -> 首次折叠成 0.0（宿主 +6 => 正常 6pt 段间距）；0 / 未知 / NaN 原样透传。
static void test_row_collapse_first_hit_and_edges(void) {
    gEnabled = YES; gDumpOnly = NO; gRemoveTaskCard = YES; gRemovePersonalSpaceCard = YES;
    [gCardA setHidden:NO]; [gCapacityA setHidden:NO];
    [gCardB setHidden:NO]; [gCapacityB setHidden:NO];
    BDTVCallLayout(gSectionA, gSectionAInst);
    BDTVCallLayout(gSectionB, gSectionBInst);
    CHECK(gCardA.hidden == YES && gCapacityA.hidden == YES);
    CHECK(gCardB.hidden == YES && gCapacityB.hidden == YES);

    unsigned logsBefore = gLogLines;
    BDTVResetCounters();
    // 首次真正折叠之前，原值已为目标0不能消耗hit token。
    gHeightOrigA = 0.0;
    CHECK(BDTVCallHeight(gSectionA, gSectionAInst) == 0.0);
    CHECK(gLogLines == logsBefore);
    gHeightOrigA = 80.0;
    BDTVResetCounters();
    CHECK(BDTVCallHeight(gSectionA, gSectionAInst) == 0.0);   // A 首次折叠
    CHECK(gLogLines == logsBefore + 1);
    CHECK(BDTVCallHeight(gSectionB, gSectionBInst) == 0.0);   // B 首次折叠
    CHECK(gLogLines == logsBefore + 2);
    CHECK(BDTVCallHeight(gSectionA, gSectionAInst) == 0.0);   // 重复：不再打
    CHECK(gLogLines == logsBefore + 2);
    CHECK(gHeightCallsA == 2 && gHeightCallsB == 1);          // 原实现每次都先被调一次
    CHECK(gHeightSeenReceiverA == gSectionAInst && gHeightSeenSelA == gHeightSel);
    CHECK(gHeightSeenReceiverB == gSectionBInst && gHeightSeenSelB == gHeightSel);

    // 宿主 +6.0 的算术：0.0 + 6.0 = 6pt 正常段间距
    CHECK(BDTVCallHeight(gSectionA, gSectionAInst) + 6.0 == 6.0);
    CHECK(BDTVCallHeight(gSectionB, gSectionBInst) + 6.0 == 6.0);

    // 未知高度 / 负值 / NaN：原样透传，不覆盖未知原实现
    gHeightOrigA = 55.5;
    CHECK(BDTVCallHeight(gSectionA, gSectionAInst) == 55.5);
    gHeightOrigA = -2.0;
    CHECK(BDTVCallHeight(gSectionA, gSectionAInst) == -2.0);
    gHeightOrigA = NAN;
    CHECK(isnan(BDTVCallHeight(gSectionA, gSectionAInst)));
    gHeightOrigA = 80.0;

    // 原生已经是 0.0：原样返回且不假记 hit
    gHeightOrigB = 0.0;
    logsBefore = gLogLines;
    CHECK(BDTVCallHeight(gSectionB, gSectionBInst) == 0.0);
    CHECK(gLogLines == logsBefore);
    gHeightOrigB = 84.0;

    gRemoveTaskCard = YES; gRemovePersonalSpaceCard = NO;
}

// 两个开关各自的 16 组矩阵（每 style 都跑）：各按自己的开关隐藏；只有两张都隐藏才折叠行高。
static void test_gate_matrix(void) {
    const BOOL bools[2] = {YES, NO};
    unsigned checked = 0;
    for (unsigned e = 0; e < 2; e++)
    for (unsigned d = 0; d < 2; d++)
    for (unsigned t = 0; t < 2; t++)
    for (unsigned s = 0; s < 2; s++) {
        gEnabled = bools[e]; gDumpOnly = bools[d];
        gRemoveTaskCard = bools[t]; gRemovePersonalSpaceCard = bools[s];
        BOOL taskGate = bools[e] && !bools[d] && bools[t];
        BOOL spaceGate = bools[e] && !bools[d] && bools[s];

        [gCardA setHidden:NO]; [gCardB setHidden:NO];
        [gCapacityA setHidden:NO]; [gCapacityB setHidden:NO];
        BDTVResetCounters();
        BDTVCallLayout(gSectionA, gSectionAInst);
        BDTVCallLayout(gSectionB, gSectionBInst);
        checked++;

        CHECK(gLayoutCallsA == 1 && gLayoutCallsB == 1);      // 原实现先且只一次
        CHECK(gGetterCallsA == (taskGate ? 1u : 0u));         // 开关不生效就不问 getter
        CHECK(gGetterCallsB == (taskGate ? 1u : 0u));
        CHECK(gSpaceGetterCallsA == (spaceGate ? 1u : 0u));
        CHECK(gSpaceGetterCallsB == (spaceGate ? 1u : 0u));
        CHECK(gCardA.hidden == (taskGate ? YES : NO));
        CHECK(gCardB.hidden == (taskGate ? YES : NO));
        CHECK(gCapacityA.hidden == (spaceGate ? YES : NO));
        CHECK(gCapacityB.hidden == (spaceGate ? YES : NO));

        BOOL collapse = taskGate && spaceGate;
        unsigned logs = gLogLines;
        CHECK(BDTVCallHeight(gSectionA, gSectionAInst) == (collapse ? 0.0 : 80.0));
        CHECK(BDTVCallHeight(gSectionB, gSectionBInst) == (collapse ? 0.0 : 84.0));
        CHECK(gHeightCallsA == 1 && gHeightCallsB == 1);
        CHECK(gLogLines == logs);                             // token 都已消耗：不再增长
    }
    CHECK(checked == 16);
    gEnabled = YES; gDumpOnly = NO; gRemoveTaskCard = YES; gRemovePersonalSpaceCard = NO;
}

// 依赖隔离的公共骨架：phantom 类上装 layoutViews + heightForView 两个目标、两条依赖 spec。
// orig 槽指向文件级静态（每次用例先清空），避免每个 case 重复声明一堆局部变量。
static IMP gPhantomLayoutOrig, gPhantomHeightOrig;
static BOOL BDTVInstallPhantom(const char *cls,
                               IMP *pImp, SEL *pSel, IMP *sImp, SEL *sSel, BOOL *ready) {
    BDFRSpec dP = BDTVSpec(cls, "pointsCard", NO, "@16@0:8", 2, NULL, NULL, "t-p");
    BDFRSpec dS = BDTVSpec(cls, "spaceCard", NO, "@16@0:8", 2, NULL, NULL, "t-s");
    BDFRSpec tL = BDTVSpec(cls, "layoutViews", NO, "v16@0:8", 2, (IMP)PhLayoutHook, &gPhantomLayoutOrig, "t-l");
    BDFRSpec tH = BDTVSpec(cls, "heightForView", NO, "d16@0:8", 2, (IMP)PhHeightHook, &gPhantomHeightOrig, "t-h");
    *pImp = NULL; *pSel = NULL; *sImp = NULL; *sSel = NULL; *ready = YES;
    gPhantomLayoutOrig = NULL; gPhantomHeightOrig = NULL;
    return BDPVInstallSectionWith(&dP, &dS, &tL, &tH, pImp, pSel, sImp, sSel, ready);
}

// 依赖隔离：单条依赖缺失/签名不符只关掉它那一条；height 只在两条都可用时装。
static void test_dep_isolation(void) {
    SEL spaceSel = sel_registerName("spaceCard");
    SEL cardSel = sel_registerName("pointsCard");
    IMP p = NULL, s = NULL; SEL ps = NULL, ss = NULL; BOOL ready = YES;

    // 1) spaceCard 缺失：仍装 layout（任务卡可用），height 不装
    Class c1 = BDTVMakeClass("BDTVPhantomOnlyPoints", Nil);
    CHECK(class_addMethod(c1, gLayoutSel, (IMP)FakeLayoutA, "v16@0:8"));
    CHECK(class_addMethod(c1, cardSel, (IMP)FakePointsCardA, "@16@0:8"));
    CHECK(class_addMethod(c1, gHeightSel, (IMP)FakeHeightA, "d16@0:8"));
    CHECK(BDTVInstallPhantom("BDTVPhantomOnlyPoints", &p, &ps, &s, &ss, &ready) == YES);
    CHECK(p == (IMP)FakePointsCardA && ps == cardSel);
    CHECK(s == NULL && ss == NULL);          // 单条依赖缺失不写半套
    CHECK(ready == NO && gPhantomHeightOrig == NULL);
    CHECK(class_getMethodImplementation(c1, gHeightSel) == (IMP)FakeHeightA);

    // 2) pointsCard 缺失：容量卡仍能隐藏，height 同样不装
    Class c2 = BDTVMakeClass("BDTVPhantomOnlySpace", Nil);
    CHECK(class_addMethod(c2, gLayoutSel, (IMP)FakeLayoutA, "v16@0:8"));
    CHECK(class_addMethod(c2, spaceSel, (IMP)FakeSpaceCardA, "@16@0:8"));
    CHECK(class_addMethod(c2, gHeightSel, (IMP)FakeHeightA, "d16@0:8"));
    CHECK(BDTVInstallPhantom("BDTVPhantomOnlySpace", &p, &ps, &s, &ss, &ready) == YES);
    CHECK(p == NULL && ps == NULL);
    CHECK(s == (IMP)FakeSpaceCardA && ss == spaceSel);
    CHECK(ready == NO && gPhantomHeightOrig == NULL);

    // 3) 两个依赖都没有：整条跳过，什么都不写
    Class c3 = BDTVMakeClass("BDTVPhantomNoDeps", Nil);
    CHECK(class_addMethod(c3, gLayoutSel, (IMP)FakeLayoutA, "v16@0:8"));
    CHECK(class_addMethod(c3, gHeightSel, (IMP)FakeHeightA, "d16@0:8"));
    CHECK(BDTVInstallPhantom("BDTVPhantomNoDeps", &p, &ps, &s, &ss, &ready) == NO);
    CHECK(gPhantomLayoutOrig == NULL && gPhantomHeightOrig == NULL && ready == NO);
    CHECK(class_getMethodImplementation(c3, gLayoutSel) == (IMP)FakeLayoutA);

    // 4) spaceCard 只有父类实现：own 校验 skip，任务那条照装、height 不装、父类槽不动
    Class base = BDTVMakeClass("BDTVPhantomDepBase", Nil);
    CHECK(class_addMethod(base, spaceSel, (IMP)FakeSpaceCardA, "@16@0:8"));
    Class c4 = BDTVMakeClass("BDTVPhantomDepSub", base);
    CHECK(class_addMethod(c4, gLayoutSel, (IMP)FakeLayoutA, "v16@0:8"));
    CHECK(class_addMethod(c4, cardSel, (IMP)FakePointsCardA, "@16@0:8"));
    CHECK(class_addMethod(c4, gHeightSel, (IMP)FakeHeightA, "d16@0:8"));
    CHECK(BDTVInstallPhantom("BDTVPhantomDepSub", &p, &ps, &s, &ss, &ready) == YES);
    CHECK(p == (IMP)FakePointsCardA);
    CHECK(s == NULL && ss == NULL);
    CHECK(ready == NO);
    CHECK(class_getMethodImplementation(base, spaceSel) == (IMP)FakeSpaceCardA);

    // 5) height 签名不符：layout 照装、hide 可用、height 不装
    Class c5 = BDTVMakeClass("BDTVPhantomHeightWrong", Nil);
    CHECK(class_addMethod(c5, gLayoutSel, (IMP)FakeLayoutA, "v16@0:8"));
    CHECK(class_addMethod(c5, cardSel, (IMP)FakePointsCardA, "@16@0:8"));
    CHECK(class_addMethod(c5, spaceSel, (IMP)FakeSpaceCardA, "@16@0:8"));
    CHECK(class_addMethod(c5, gHeightSel, (IMP)FakeHeightA, "d32@0:8"));
    CHECK(BDTVInstallPhantom("BDTVPhantomHeightWrong", &p, &ps, &s, &ss, &ready) == YES);
    CHECK(gPhantomHeightOrig == NULL && ready == NO);
    CHECK(class_getMethodImplementation(c5, gHeightSel) == (IMP)FakeHeightA);

    // 6) 容量getter签名不符：仍保留任务隐藏，不能安装整行压缩。
    Class c6 = BDTVMakeClass("BDTVPhantomSpaceWrong", Nil);
    CHECK(class_addMethod(c6, gLayoutSel, (IMP)FakeLayoutA, "v16@0:8"));
    CHECK(class_addMethod(c6, cardSel, (IMP)FakePointsCardA, "@16@0:8"));
    CHECK(class_addMethod(c6, spaceSel, (IMP)FakeSpaceCardA, "@32@0:8"));
    CHECK(class_addMethod(c6, gHeightSel, (IMP)FakeHeightA, "d16@0:8"));
    CHECK(BDTVInstallPhantom("BDTVPhantomSpaceWrong", &p, &ps, &s, &ss, &ready) == YES);
    CHECK(p == (IMP)FakePointsCardA && s == NULL && ss == NULL);
    CHECK(!ready && gPhantomHeightOrig == NULL);
}

#pragma mark - main

int main(void) {
    @autoreleasepool {
        // 真实 FeatureRemoval.h 里的 BDFRInstallAll 在本 TU 没人调用会触发 unused-function。
        // 这里先调一次当机制 fixture：它的目标类（BHSettings / BDPanNewMSHContentViewController /
        // BDPanPersonalConfig / BDPanFeedHomeConfig / BDPanFHKingKongsModel）在这里全都不存在，
        // 只会逐条 skip，不碰两个 Task section，也不碰本测试的任何计数与后续断言
        // （每个用例都用自己的 logsBefore，不依赖日志总行数）。
        BDFRInstallAll();

        test_before_install();
        test_install_and_hide();
        test_space_first_hit_and_repeat();
        test_row_collapse_first_hit_and_edges();
        test_gate_matrix();
        test_gate_off_and_bad_getter();
        test_already_hidden_no_duplicate_hit();
        test_reinstall_no_recursion();
        test_background_thread();
        test_precheck_failures();
        test_dep_isolation();

        printf("%s: %d 项失败（日志共 %u 行）\n",
               gFailures ? "FAIL" : "PASS", gFailures, gLogLines);
    }
    return gFailures ? 1 : 0;
}
