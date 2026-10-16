// tests/task_card_test.mm — PersonalViewRemoval.h 的 macOS host 机制测试
//
// include 的是**真实**产品头（FeatureRemoval.h + PersonalViewRemoval.h）；假的只有三样：
//   - 假开关 BDEnabled / BDDumpOnly / BDRemoveRecommend / BDRemoveGameCenter / BDRemoveJobNovel /
//     BDRemoveTaskCard，和假日志 BDLog（两个产品头都按同名静态函数引用）
//   - 一个**最小声明面**的 UIView（只有 hidden 与 setHidden: 计数）。这不是伪造 UIKit SDK：
//     macOS 上没有 UIKit，这里只声明本产品头唯一用到的那个属性，好让真实 hook 代码原样跑起来。
//   - 两个真实类名的动态 fake section：各自的 -layoutViews(v16@0:8) 与 -pointsCard(@16@0:8)，
//     原 layoutViews 会像真机那样把任务卡 setHidden:NO（可用 fixture 开关关掉）。
//
// 测的是调用/对象边界/开关机制：原 layout 先跑且每次都跑、之后产品把任务卡按回隐藏、
// getter 返回非视图对象时不动手、原布局重显时反复覆盖、已隐藏不重复写也不重复 hit、
// 关闭时完全不碰本组件状态、后台只转发原实现、重复安装不递归、预检不过什么都不写。
// **不证明**真机布局：容量卡、约束、80/96pt 行高留白都验证不了。
//
// 构建运行（macOS，无需 IPA，无需 Theos）：
//   clang++ -std=c++17 -fobjc-arc -fblocks -Wall -Wextra -Werror \
//     -framework Foundation -o /tmp/task_card_test tests/task_card_test.mm
//   /tmp/task_card_test

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdio.h>

#pragma mark - 假开关 / 假日志

static BOOL gEnabled = YES;
static BOOL gDumpOnly = NO;
static BOOL gRemoveRecommend = YES;
static BOOL gRemoveGameCenter = YES;
static BOOL gRemoveJobNovel = YES;
static BOOL gRemoveTaskCard = YES;
static unsigned gLogLines = 0;

static void BDLog(NSString *fmt, ...) { (void)fmt; gLogLines++; }
static BOOL BDEnabled(void) { return gEnabled; }
static BOOL BDDumpOnly(void) { return gDumpOnly; }
static BOOL BDRemoveRecommend(void) { return gRemoveRecommend; }
static BOOL BDRemoveGameCenter(void) { return gRemoveGameCenter; }
static BOOL BDRemoveJobNovel(void) { return gRemoveJobNovel; }
static BOOL BDRemoveTaskCard(void) { return gRemoveTaskCard; }

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
static unsigned gSpaceGetterCallsA = 0, gSpaceGetterCallsB = 0;  // 容量卡 getter（本产品不该碰）
static BOOL gNativeReShow = YES;   // fixture：原 layoutViews 要不要像真机那样把任务卡 setHidden:NO

static UIView *gCardA;             // 任务卡（advanced 样式）
static UIView *gCardB;             // 任务卡（legacy 样式）
static id gGetterResultA;          // getter 返回值，可换成 nil / NSString
static id gGetterResultB;
static UIView *gCapacityA;         // 容量卡：本产品不该发任何消息给它
static UIView *gCapacityB;

static id FakePointsCardA(id self, SEL _cmd) { (void)self; (void)_cmd; gGetterCallsA++; return gGetterResultA; }
static id FakePointsCardB(id self, SEL _cmd) { (void)self; (void)_cmd; gGetterCallsB++; return gGetterResultB; }
static id FakeSpaceCardA(id self, SEL _cmd)  { (void)self; (void)_cmd; gSpaceGetterCallsA++; return gCapacityA; }
static id FakeSpaceCardB(id self, SEL _cmd)  { (void)self; (void)_cmd; gSpaceGetterCallsB++; return gCapacityB; }

static void FakeLayoutA(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    gLayoutCallsA++;
    if (gNativeReShow && [gGetterResultA isKindOfClass:[UIView class]]) {
        [(UIView *)gGetterResultA setHidden:NO];     // 真机上 layoutViews 的 iPhone 分支就是这样
    }
}
static void FakeLayoutB(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    gLayoutCallsB++;
    if (gNativeReShow && [gGetterResultB isKindOfClass:[UIView class]]) {
        [(UIView *)gGetterResultB setHidden:NO];
    }
}

static Class gSectionA, gSectionB;
static id gSectionAInst, gSectionBInst;
static SEL gLayoutSel;

static void setup_sections(void) {
    gLayoutSel = sel_registerName("layoutViews");
    SEL cardSel = sel_registerName("pointsCard");
    SEL spaceSel = sel_registerName("spaceCard");

    gSectionA = BDTVMakeClass("BDPanPersonalSpaceAndPointSection", Nil);
    CHECK(class_addMethod(gSectionA, gLayoutSel, (IMP)FakeLayoutA, "v16@0:8"));
    CHECK(class_addMethod(gSectionA, cardSel, (IMP)FakePointsCardA, "@16@0:8"));
    CHECK(class_addMethod(gSectionA, spaceSel, (IMP)FakeSpaceCardA, "@16@0:8"));

    gSectionB = BDTVMakeClass("BDPanPersonalSpaceSection", Nil);
    CHECK(class_addMethod(gSectionB, gLayoutSel, (IMP)FakeLayoutB, "v16@0:8"));
    CHECK(class_addMethod(gSectionB, cardSel, (IMP)FakePointsCardB, "@16@0:8"));
    CHECK(class_addMethod(gSectionB, spaceSel, (IMP)FakeSpaceCardB, "@16@0:8"));

    gCapacityA = [[UIView alloc] init]; [gCapacityA setHidden:NO];
    gCapacityB = [[UIView alloc] init]; [gCapacityB setHidden:NO];
    gCardA = [[UIView alloc] init]; [gCardA setHidden:NO];
    gCardB = [[UIView alloc] init]; [gCardB setHidden:NO];
    gGetterResultA = gCardA;
    gGetterResultB = gCardB;

    gSectionAInst = [[gSectionA alloc] init];
    gSectionBInst = [[gSectionB alloc] init];
}

static void BDTVCallLayout(Class cls, id inst) {
    void (*imp)(id, SEL) = (void (*)(id, SEL))class_getMethodImplementation(cls, gLayoutSel);
    imp(inst, gLayoutSel);
}

static void BDTVResetCounters(void) {
    gLayoutCallsA = gLayoutCallsB = 0;
    gGetterCallsA = gGetterCallsB = 0;
    gSpaceGetterCallsA = gSpaceGetterCallsB = 0;
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
    CHECK(gLogLines == logsBefore + 2);   // 两组各一行 installed

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

    // 4) 容量卡：本产品一次都不该发消息（连 getter 都不问）
    CHECK(gSpaceGetterCallsA == 0);
    CHECK(gSpaceGetterCallsB == 0);
    CHECK(gCapacityA.hidden == NO);       // identity 与 hidden 原样
    CHECK(gCapacityB.hidden == NO);
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
    CHECK(gLogLines == logsBefore + 2);   // 两行 already installed，不是重新 attach

    BDTVResetCounters();
    unsigned hitsBefore = gLogLines;
    BDTVCallLayout(gSectionA, gSectionAInst);
    CHECK(gLayoutCallsA == 1);            // 原实现只跑一次，没有自指递归
    CHECK(gCardA.hidden == YES);
    CHECK(gLogLines == hitsBefore);       // hit token 已消耗，不再打
}

static void test_background_thread(void) {
    // 只转发原 layoutViews：产品不调 pointsCard getter、不发 hidden 消息、不记 hit。
    // 同步用 semaphore（测试里的调度，不进产品代码）。
    gEnabled = YES; gDumpOnly = NO; gRemoveTaskCard = YES;
    [gCardA setHidden:NO];
    BDTVResetCounters();
    unsigned logsBefore = gLogLines;

    // 本用例后台没有任何主队列回调，所以直接等完成再读计数；不用超时等待
    // （超时后继续读共享计数会有竞态）。调度只发生在测试里，产品代码不加任何调度或延时。
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BDTVCallLayout(gSectionA, gSectionAInst);
        dispatch_semaphore_signal(done);
    });
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);

    CHECK(gLayoutCallsA == 1);            // 原实现被转发
    CHECK(gGetterCallsA == 0);            // 本组件没问 getter
    CHECK(gHiddenNOCalls == 1);           // 只有替身自己那条 NO
    CHECK(gHiddenYESCalls == 0);          // 本组件没发 YES
    CHECK(gLogLines == logsBefore);       // 也没借道记 hit
}

static void test_precheck_failures(void) {
    // 1) 依赖签名错（真注册 @32@0:8，spec 期望 @16@0:8）-> 整条跳过
    Class depWrong = BDTVMakeClass("BDTVPhantomDepWrongEnc", Nil);
    CHECK(class_addMethod(depWrong, sel_registerName("pointsCard"), (IMP)FakePointsCardA, "@32@0:8"));
    CHECK(class_addMethod(depWrong, gLayoutSel, (IMP)FakeLayoutA, "v16@0:8"));
    IMP origT1 = NULL, cardImp1 = NULL;
    SEL cardSel1 = NULL;
    BDFRSpec dep1 = BDTVSpec("BDTVPhantomDepWrongEnc", "pointsCard", NO, "@16@0:8", 2,
                             NULL, NULL, "t-dep-wrong-enc");
    BDFRSpec tgt1 = BDTVSpec("BDTVPhantomDepWrongEnc", "layoutViews", NO, "v16@0:8", 2,
                             (IMP)FakeLayoutA, &origT1, "t-target-dep-wrong-enc");
    CHECK(BDPVInstallTaskCardWith(&dep1, &tgt1, &cardImp1, &cardSel1) == NO);
    CHECK(tgt1.installed == NO);
    CHECK(origT1 == NULL);
    CHECK(cardImp1 == NULL);
    CHECK(cardSel1 == NULL);

    // 2) 目标签名错（真注册 v24@0:8@16，spec 期望 v16@0:8）-> 整条跳过
    Class tgtWrong = BDTVMakeClass("BDTVPhantomTargetWrongEnc", Nil);
    CHECK(class_addMethod(tgtWrong, sel_registerName("pointsCard"), (IMP)FakePointsCardA, "@16@0:8"));
    CHECK(class_addMethod(tgtWrong, gLayoutSel, (IMP)FakeLayoutA, "v24@0:8@16"));
    IMP origT2 = NULL, cardImp2 = NULL;
    SEL cardSel2 = NULL;
    BDFRSpec dep2 = BDTVSpec("BDTVPhantomTargetWrongEnc", "pointsCard", NO, "@16@0:8", 2,
                             NULL, NULL, "t-dep-target-wrong");
    BDFRSpec tgt2 = BDTVSpec("BDTVPhantomTargetWrongEnc", "layoutViews", NO, "v16@0:8", 2,
                             (IMP)FakeLayoutA, &origT2, "t-target-wrong-enc");
    CHECK(BDPVInstallTaskCardWith(&dep2, &tgt2, &cardImp2, &cardSel2) == NO);
    CHECK(tgt2.installed == NO);
    CHECK(origT2 == NULL);
    CHECK(cardImp2 == NULL);
    CHECK(cardSel2 == NULL);

    // 3) 只有继承实现（layoutViews 在父类上）-> 整条跳过，绝不碰父类
    Class base = BDTVMakeClass("BDTVPhantomBase", Nil);
    CHECK(class_addMethod(base, gLayoutSel, (IMP)FakeLayoutA, "v16@0:8"));
    Class sub = BDTVMakeClass("BDTVPhantomSub", base);
    CHECK(class_addMethod(sub, sel_registerName("pointsCard"), (IMP)FakePointsCardA, "@16@0:8"));
    IMP origT3 = NULL, cardImp3 = NULL;
    SEL cardSel3 = NULL;
    BDFRSpec dep3 = BDTVSpec("BDTVPhantomSub", "pointsCard", NO, "@16@0:8", 2,
                             NULL, NULL, "t-dep-sub");
    BDFRSpec tgt3 = BDTVSpec("BDTVPhantomSub", "layoutViews", NO, "v16@0:8", 2,
                             (IMP)FakeLayoutA, &origT3, "t-target-sub");
    CHECK(BDPVInstallTaskCardWith(&dep3, &tgt3, &cardImp3, &cardSel3) == NO);
    CHECK(tgt3.installed == NO);
    CHECK(origT3 == NULL);
    CHECK(cardImp3 == NULL);
    CHECK(cardSel3 == NULL);
    // 父类那个槽没被动过
    CHECK(class_getMethodImplementation(base, gLayoutSel) == (IMP)FakeLayoutA);
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
        test_gate_off_and_bad_getter();
        test_already_hidden_no_duplicate_hit();
        test_reinstall_no_recursion();
        test_background_thread();
        test_precheck_failures();

        printf("%s: %d 项失败（日志共 %u 行）\n",
               gFailures ? "FAIL" : "PASS", gFailures, gLogLines);
    }
    return gFailures ? 1 : 0;
}