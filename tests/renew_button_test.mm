// tests/renew_button_test.mm — RenewButtonRemoval.h 的 macOS host 机制测试
//
// include 的是**真实**产品 header（FeatureRemoval.h + RenewButtonRemoval.h）与真实安装器，
// 只有开关、日志、getter 替身和 UIButton 是假的。
//
// 关于 UIButton：macOS Foundation 宿主里没有 UIKit，这里只声明一个最小的
//     @interface UIButton : NSObject  （BOOL hidden + 计数用的 -setHidden:）
// 让产品代码能做类型检查。**这不是真 UIKit**：它只用来验证
// 原 IMP 调用次数、对象 identity、开关组合、隐藏调用时机与幂等；
// 不证明任何布局、层级、约束或真机行为。
//
// 构建运行（macOS，无需 IPA，无需 Theos）：
//   clang++ -std=c++17 -fobjc-arc -fblocks -Wall -Wextra -Werror \
//     -framework Foundation -o /tmp/renew_button_test tests/renew_button_test.mm
//   /tmp/renew_button_test

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdio.h>

#pragma mark - 最小 fake UIButton（仅供类型检查，不是真 UIKit）

static unsigned gSetHiddenCalls = 0;   // 产品代码调 -setHidden: 的总次数

@interface UIButton : NSObject
{
    BOOL _hidden;   // 两个访问器都自己实现，clang 不会自动合成 ivar，这里显式声明
}
@property (nonatomic, assign, getter=isHidden) BOOL hidden;
@end

@implementation UIButton
- (BOOL)isHidden { return _hidden; }
- (void)setHidden:(BOOL)hidden { gSetHiddenCalls++; _hidden = hidden; }
@end

#pragma mark - 假开关 / 假日志（两个产品 header 依赖这些同名静态函数）

static BOOL gEnabled = YES;
static BOOL gDumpOnly = NO;
static BOOL gRemoveRecommend = YES;
static BOOL gRemoveGameCenter = YES;
static BOOL gRemoveJobNovel = YES;
static BOOL gRemoveRenewButton = YES;      // 默认 ON 只为让用例跑起来；产品默认由 Prefs 决定（NO）
static unsigned gLogLines = 0;

static void BDLog(NSString *fmt, ...) {
    (void)fmt;
    gLogLines++;
}
static BOOL BDEnabled(void) { return gEnabled; }
static BOOL BDDumpOnly(void) { return gDumpOnly; }
static BOOL BDRemoveRecommend(void) { return gRemoveRecommend; }
static BOOL BDRemoveGameCenter(void) { return gRemoveGameCenter; }
static BOOL BDRemoveJobNovel(void) { return gRemoveJobNovel; }
static BOOL BDRemoveRenewButton(void) { return gRemoveRenewButton; }

// 顺序即真实接线顺序：先 FeatureRemoval.h（安装器 + 旧 hook），再 RenewButtonRemoval.h。
#include "../FeatureRemoval.h"
#include "../RenewButtonRemoval.h"

#pragma mark - 断言与小工具

static int gFailures = 0;

#define CHECK(cond)                                                        \
    do {                                                                   \
        if (!(cond)) {                                                     \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
            gFailures++;                                                   \
        }                                                                  \
    } while (0)

static Class BDRBMakeClass(const char *name, Class super) {
    Class c = objc_allocateClassPair(super ? super : [NSObject class], name, 0);
    CHECK(c != nil);
    if (c) objc_registerClassPair(c);
    return c;
}

// 本测试自用的 spec 描述（产品 header 里那三条是静态的，不在这里造第二套安装器）。
static BDFRSpec BDRBTestSpec(const char *cls, const char *sel, BOOL isClassMethod,
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

// receiver 必须是真实实例：产品 hook 装在**实例方法**槽上，用 object_getClass(host)
// 取实例的类，正好对应运行时的方法查找方式（不把实例方法当类方法直接调）。
static id BDRBSendGetter(id host, SEL sel) {
    id (*imp)(id, SEL) =
        (id (*)(id, SEL))class_getMethodImplementation(object_getClass(host), sel);
    return imp(host, sel);
}

#pragma mark - 三个 getter 替身

// 每个 host 一份：返回值与调用次数可调。
static id gSourceNew, gSourceVip, gSourceAdv;
static unsigned gCallsNew, gCallsVip, gCallsAdv;

static id PhGetterNew(id self, SEL _cmd) { (void)self; (void)_cmd; gCallsNew++; return gSourceNew; }
static id PhGetterVip(id self, SEL _cmd) { (void)self; (void)_cmd; gCallsVip++; return gSourceVip; }
static id PhGetterAdv(id self, SEL _cmd) { (void)self; (void)_cmd; gCallsAdv++; return gSourceAdv; }

static Class gNewCard, gVipCard, gAdvCard;   // 只用来给实例方法表注册方法
static id gNewHost, gVipHost, gAdvHost;       // 真实实例：测试里 getter 的 receiver
static SEL gGetterSel;

static void setup_hosts(void) {
    gGetterSel = sel_registerName("vipButton");
    gNewCard = BDRBMakeClass("BDPanPersonNewVipCardHeaderView", Nil);
    gVipCard = BDRBMakeClass("BDPanPersonVipHeaderView", Nil);
    gAdvCard = BDRBMakeClass("BDPanPersonAdvanceVIPHeaderView", Nil);
    CHECK(class_addMethod(gNewCard, gGetterSel, (IMP)PhGetterNew, "@16@0:8"));
    CHECK(class_addMethod(gVipCard, gGetterSel, (IMP)PhGetterVip, "@16@0:8"));
    CHECK(class_addMethod(gAdvCard, gGetterSel, (IMP)PhGetterAdv, "@16@0:8"));
    gNewHost = [[gNewCard alloc] init];
    gVipHost = [[gVipCard alloc] init];
    gAdvHost = [[gAdvCard alloc] init];
    CHECK(gNewHost != nil && gVipHost != nil && gAdvHost != nil);
}

#pragma mark - 测试

static void test_before_install(void) {
    CHECK(BDFRSpecRenewButtonNew.installed == NO);
    setup_hosts();

    UIButton *btn = [[UIButton alloc] init];
    gSourceNew = btn;
    gSourceVip = [[UIButton alloc] init];
    gSourceAdv = [[UIButton alloc] init];
    gCallsNew = gCallsVip = gCallsAdv = 0;

    CHECK(BDRBSendGetter(gNewHost, gGetterSel) == btn);   // 安装前：原对象透传
    CHECK(BDRBSendGetter(gVipHost, gGetterSel) == gSourceVip);
    CHECK(BDRBSendGetter(gAdvHost, gGetterSel) == gSourceAdv);
    CHECK(gCallsNew == 1 && gCallsVip == 1 && gCallsAdv == 1);
    CHECK(btn.hidden == NO);                                   // 没被动过

    // 旧三个 hook 的类不存在：BDFRInstallAll() 逐条 skip，不影响任何东西
    unsigned logsBefore = gLogLines;
    BDFRInstallAll();
    CHECK(gLogLines > logsBefore);
    CHECK(BDFRSpecRenewButtonNew.installed == NO);              // 由 BDRBInstallAll() 单独装
    CHECK(gCallsNew == 1);
}

static void test_install_and_hide(void) {
    unsigned logsBefore = gLogLines;
    BDRBInstallAll();
    CHECK(BDFRSpecRenewButtonNew.installed == YES);
    CHECK(BDFRSpecRenewButtonVip.installed == YES);
    CHECK(BDFRSpecRenewButtonAdv.installed == YES);
    CHECK(*BDFRSpecRenewButtonNew.orig == (IMP)PhGetterNew);
    CHECK(*BDFRSpecRenewButtonVip.orig == (IMP)PhGetterVip);
    CHECK(*BDFRSpecRenewButtonAdv.orig == (IMP)PhGetterAdv);
    CHECK(*BDFRSpecRenewButtonNew.orig != (IMP)BDRBRenewButtonNew);   // orig 不能自指
    CHECK(*BDFRSpecRenewButtonVip.orig != (IMP)BDRBRenewButtonVip);
    CHECK(*BDFRSpecRenewButtonAdv.orig != (IMP)BDRBRenewButtonAdv);
    CHECK(gLogLines == logsBefore + 3);                           // 三条 installed 日志

    // 三类各自：开关全开 -> 返回同一对象、按钮变 hidden、原 getter 只被调一次、各记一次 hit
    UIButton *newBtn = [[UIButton alloc] init];
    UIButton *vipBtn = [[UIButton alloc] init];
    UIButton *advBtn = [[UIButton alloc] init];
    gSourceNew = newBtn; gSourceVip = vipBtn; gSourceAdv = advBtn;
    gCallsNew = gCallsVip = gCallsAdv = 0;
    gSetHiddenCalls = 0;
    logsBefore = gLogLines;

    CHECK(BDRBSendGetter(gNewHost, gGetterSel) == newBtn);
    CHECK(BDRBSendGetter(gVipHost, gGetterSel) == vipBtn);
    CHECK(BDRBSendGetter(gAdvHost, gGetterSel) == advBtn);
    CHECK(newBtn.hidden && vipBtn.hidden && advBtn.hidden);
    CHECK(gCallsNew == 1 && gCallsVip == 1 && gCallsAdv == 1);
    CHECK(gSetHiddenCalls == 3);
    CHECK(gLogLines == logsBefore + 3);                          // 三张卡各一行首次 hit

    // 已经 hidden 的不再重复处理，也不再重复 hit
    gSetHiddenCalls = 0;
    logsBefore = gLogLines;
    for (int i = 0; i < 3; i++) {
        (void)BDRBSendGetter(gNewHost, gGetterSel);
        (void)BDRBSendGetter(gVipHost, gGetterSel);
        (void)BDRBSendGetter(gAdvHost, gGetterSel);
    }
    CHECK(gSetHiddenCalls == 0);
    CHECK(gLogLines == logsBefore);
}

static void test_switches_off(void) {
    // 说明：下面的 btn.hidden = ... 是**测试自己**的准备工作，会让 fake 的 -setHidden: 计数 +1；
    // 所以每次准备之后都清零，产品动作按增量断言。原 getter 调用次数 gCallsNew 仍按每次 +1 严格数。
    UIButton *btn = [[UIButton alloc] init];
    gSourceNew = btn;
    gCallsNew = 0;

    // 独立开关关：原样透传，不碰 hidden
    gRemoveRenewButton = NO;
    gSetHiddenCalls = 0;
    CHECK(BDRBSendGetter(gNewHost, gGetterSel) == btn);
    CHECK(gCallsNew == 1 && gSetHiddenCalls == 0 && btn.hidden == NO);
    gRemoveRenewButton = YES;

    // 总开关关
    btn.hidden = NO;
    gEnabled = NO;
    gSetHiddenCalls = 0;
    CHECK(BDRBSendGetter(gNewHost, gGetterSel) == btn);
    CHECK(gCallsNew == 2 && gSetHiddenCalls == 0 && btn.hidden == NO);
    gEnabled = YES;

    // 诊断开启
    btn.hidden = NO;
    gDumpOnly = YES;
    gSetHiddenCalls = 0;
    CHECK(BDRBSendGetter(gNewHost, gGetterSel) == btn);
    CHECK(gCallsNew == 3 && gSetHiddenCalls == 0 && btn.hidden == NO);
    gDumpOnly = NO;

    // 开关全开时同一个按钮才被隐藏（顺带证明上面三次确实没生效）
    gSetHiddenCalls = 0;
    CHECK(BDRBSendGetter(gNewHost, gGetterSel) == btn);
    CHECK(gCallsNew == 4 && gSetHiddenCalls == 1 && btn.hidden == YES);

    // 其它 promo 开关不影响本开关
    btn.hidden = NO;
    gRemoveRecommend = NO; gRemoveGameCenter = NO; gRemoveJobNovel = NO;
    gSetHiddenCalls = 0;
    CHECK(BDRBSendGetter(gNewHost, gGetterSel) == btn);
    CHECK(gCallsNew == 5 && gSetHiddenCalls == 1 && btn.hidden == YES);
    gRemoveRecommend = YES; gRemoveGameCenter = YES; gRemoveJobNovel = YES;
}

static void test_non_button_results(void) {
    // nil：原样返回，不发消息、不记 hit
    gSourceNew = nil;
    gSetHiddenCalls = 0;
    unsigned logsBefore = gLogLines;
    CHECK(BDRBSendGetter(gNewHost, gGetterSel) == nil);
    CHECK(gSetHiddenCalls == 0);
    CHECK(gLogLines == logsBefore);

    // 非 UIButton：原样透传同一个对象，同样不发消息
    NSString *str = @"not-a-button";
    gSourceNew = str;
    CHECK(BDRBSendGetter(gNewHost, gGetterSel) == str);
    CHECK(gSetHiddenCalls == 0);
    CHECK(gLogLines == logsBefore);
}

static void test_off_main_thread(void) {
    UIButton *btn = [[UIButton alloc] init];
    gSourceNew = btn;
    gCallsNew = 0;
    gSetHiddenCalls = 0;
    unsigned logsBefore = gLogLines;

    // 开关全开，但在后台线程取 getter：只调原 IMP，不动 UI、不记 hit。
    // 主线程只等信号量，不需要主队列回调，所以不会死锁。
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block id got = nil;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        got = BDRBSendGetter(gNewHost, gGetterSel);
        dispatch_semaphore_signal(sem);
    });
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    CHECK(got == btn);
    CHECK(gCallsNew == 1);                 // 后台线程同样原样穿透一次原 getter
    CHECK(btn.hidden == NO);
    CHECK(gSetHiddenCalls == 0);           // 没有发送可见性消息
    CHECK(gLogLines == logsBefore);

    // 回到主线程同一个按钮就会被隐藏
    gSetHiddenCalls = 0;
    CHECK(BDRBSendGetter(gNewHost, gGetterSel) == btn);
    CHECK(gCallsNew == 2 && gSetHiddenCalls == 1 && btn.hidden == YES);
}

static void test_idempotent_reinstall(void) {
    UIButton *btn = [[UIButton alloc] init];
    gSourceNew = btn;
    gCallsNew = 0;
    gSetHiddenCalls = 0;
    BDRBInstallAll();
    CHECK(BDFRSpecRenewButtonNew.installed == YES);
    CHECK(*BDFRSpecRenewButtonNew.orig == (IMP)PhGetterNew);        // 没被覆盖成替换实现
    CHECK(*BDFRSpecRenewButtonVip.orig == (IMP)PhGetterVip);
    CHECK(*BDFRSpecRenewButtonAdv.orig == (IMP)PhGetterAdv);
    CHECK(gCallsNew == 0);                                          // 安装过程不调用 getter
    CHECK(BDRBSendGetter(gNewHost, gGetterSel) == btn);        // 仍然正常转发
    CHECK(gCallsNew == 1 && gSetHiddenCalls == 1 && btn.hidden == YES);
}

// 失败路径：独立 fake 描述，不改已注册的 encoding、不重置真实 spec。
static void test_skip_paths(void) {
    // 1) 编码不符
    Class wrong = BDRBMakeClass("BDRBPhantomWrongEnc", Nil);
    CHECK(class_addMethod(wrong, sel_registerName("vipButton"), (IMP)PhGetterNew, "@16@0:8"));
    IMP origEnc = NULL;
    BDFRSpec s1 = BDRBTestSpec("BDRBPhantomWrongEnc", "vipButton", NO,
                               "v24@0:8", 2, (IMP)BDRBRenewButtonNew, &origEnc, "t-wrong-enc");
    CHECK(BDFRInstallSpec(&s1) == NO);
    CHECK(s1.installed == NO && origEnc == NULL);

    // 2) 参数个数不符
    IMP origArgc = NULL;
    BDFRSpec s2 = BDRBTestSpec("BDRBPhantomWrongEnc", "vipButton", NO,
                               "@16@0:8", 3, (IMP)BDRBRenewButtonNew, &origArgc, "t-wrong-argc");
    CHECK(BDFRInstallSpec(&s2) == NO);
    CHECK(s2.installed == NO && origArgc == NULL);

    // 3) 当类方法装（真实 3 条都是实例方法，这里故意写错）
    IMP origKind = NULL;
    BDFRSpec s3 = BDRBTestSpec("BDRBPhantomWrongEnc", "vipButton", YES,
                               "@16@0:8", 2, (IMP)BDRBRenewButtonNew, &origKind, "t-wrong-kind");
    CHECK(BDFRInstallSpec(&s3) == NO);
    CHECK(s3.installed == NO && origKind == NULL);

    // 4) 类缺失
    IMP origMissing = NULL;
    BDFRSpec s4 = BDRBTestSpec("BDRBPhantomNoCardClass", "vipButton", NO,
                               "@16@0:8", 2, (IMP)BDRBRenewButtonNew, &origMissing, "t-missing");
    CHECK(BDFRInstallSpec(&s4) == NO);
    CHECK(s4.installed == NO && origMissing == NULL);

    // 上面 4 次失败都不许动已装好的三条真实 spec
    CHECK(BDFRSpecRenewButtonNew.installed == YES);
    CHECK(*BDFRSpecRenewButtonNew.orig == (IMP)PhGetterNew);
}

#pragma mark - main

int main(void) {
    @autoreleasepool {
        test_before_install();
        test_install_and_hide();
        test_switches_off();
        test_non_button_results();
        test_off_main_thread();
        test_idempotent_reinstall();
        test_skip_paths();

        printf("%s: %d 项失败（日志共 %u 行，setHidden 共 %u 次）\n",
               gFailures ? "FAIL" : "PASS", gFailures, gLogLines, gSetHiddenCalls);
    }
    return gFailures ? 1 : 0;
}