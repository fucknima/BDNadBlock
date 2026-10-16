// tests/home_banner_experiment_test.mm — HomeBannerExperiment.h 的 macOS host 机制测试
//
// include 的是**真实**产品 header（HomeBannerExperiment.h）与**真实** FeatureRemoval.h 安装器；
// 假的只有开关、日志、替身实现，以及一套**最小 fake UIKit**（@interface UIView : NSObject，
// 与真实 UIKit 接口同构：`hidden`（getter = isHidden）/`superview`/`isDescendantOfView:`），
// 这样产品的 typed 用法在 host 上走的就是同一条消息路径，不再用字符串反射。
//
// 只证明：开关组合是否动手 / setup 内部不隐藏、setup 完成才判断 / 保护（含非 UIView 值 fail-closed）/
// 已隐藏不重复写不重复 hit / 原 setter 重现后能再次隐藏 / 其它实例在 setup 前不会被隐藏 /
// 主线程外与关闭时纯透传 / 幂等不自指 / 元数据或签名不符整组 skip。
// **不是真机测试**：真机上这个容器是不是用户看到的那块、隐藏后是否留白，host 测试不承诺。
//
// 构建运行（macOS，无需 IPA，无需 Theos）：
//   clang++ -std=c++17 -fobjc-arc -fblocks -Wall -Wextra -Werror \
//     -framework Foundation -o /tmp/home_banner_experiment_test tests/home_banner_experiment_test.mm
//   /tmp/home_banner_experiment_test

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdio.h>

#pragma mark - 假开关 / 假日志

static BOOL gEnabled = YES;
static BOOL gDumpOnly = NO;
static BOOL gRemoveRecommend = YES;
static BOOL gRemoveGameCenter = YES;
static BOOL gRemoveJobNovel = YES;
static BOOL gExperimentHideHomeBanner = NO;     // 本版默认 NO
static unsigned gLogLines = 0;

static void BDLog(NSString *fmt, ...) { (void)fmt; gLogLines++; }
static BOOL BDEnabled(void) { return gEnabled; }
static BOOL BDDumpOnly(void) { return gDumpOnly; }
static BOOL BDRemoveRecommend(void) { return gRemoveRecommend; }
static BOOL BDRemoveGameCenter(void) { return gRemoveGameCenter; }
static BOOL BDRemoveJobNovel(void) { return gRemoveJobNovel; }
static BOOL BDExperimentHideHomeBanner(void) { return gExperimentHideHomeBanner; }

#pragma mark - 最小 fake UIKit（与真实接口同构；产品用 typed UIView）

static unsigned gHiddenYESWrites = 0;            // 产品写到 hidden = YES 的次数
static unsigned gFixtureInsideSetup = 0;         // fixture 原 setup 的嵌套深度（>0 = 正在 setup 内部）
static unsigned gHiddenYESWritesInsideSetup = 0; // 观察：setup 内部是否有人写过 hidden=YES

@interface UIView : NSObject
{
    BOOL _hidden;
}
@property (nonatomic, assign, getter=isHidden) BOOL hidden;
@property (nonatomic, weak) UIView *superview;
@property (nonatomic, assign) double fixtureWidth;    // 只给 fixture 记录“frame/高度”，产品不引用
@property (nonatomic, assign) double fixtureHeight;
- (BOOL)isDescendantOfView:(UIView *)view;
@end

@implementation UIView
- (BOOL)isHidden { return _hidden; }
- (void)setHidden:(BOOL)hidden {
    if (hidden) {
        gHiddenYESWrites++;
        if (gFixtureInsideSetup > 0) gHiddenYESWritesInsideSetup++;
    }
    _hidden = hidden;
}
- (BOOL)isDescendantOfView:(UIView *)view {
    UIView *v = self;
    for (int i = 0; i < 32 && v; i++) {
        if (v == view) return YES;
        UIView *next = v.superview;
        if (![next isKindOfClass:[UIView class]]) break;
        v = next;
    }
    return NO;
}
@end

#include "../FeatureRemoval.h"
#include "../HomeBannerExperiment.h"

#pragma mark - 断言与小工具

static int gFailures = 0;

#define CHECK(cond)                                                        \
    do {                                                                   \
        if (!(cond)) {                                                     \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
            gFailures++;                                                   \
        }                                                                  \
    } while (0)

static Class BDHBMakeClass(const char *name, Class super) {
    Class c = objc_allocateClassPair(super ? super : [NSObject class], name, 0);
    CHECK(c != nil);
    return c;
}

static void BDHBAddObjectIvar(Class c, const char *name) {
    CHECK(class_addIvar(c, name, sizeof(id), (uint8_t)3, "@"));   // 3 = log2(sizeof(id))
}

static void BDHBSetIvar(id obj, const char *name, id value) {      // 仅 fixture 使用
    Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
    if (iv) object_setIvar(obj, iv, value);
}

#pragma mark - 假 host（真实类名 + 编译器生成的 strong ivar）

static void DummySetupMethod(id self, SEL _cmd) { (void)self; (void)_cmd; }
static id DummyBannerMethod(id self, SEL _cmd) { (void)self; (void)_cmd; return nil; }

@interface BDPanNewMSHTopOperationView : UIView
{
  @public
    UIView *_bannerView;
    UIView *_searchView;
    UIView *_transferButton;
    UIView *_plusButton;
    UIView *_signButton;
    UIView *_transferNumLabel;
    UIView *_transStartView;
    UIView *_transLoadingView;
    UIView *_transDoneView;
    UIView *_searchBgView;
}
- (void)setupView;
- (id)bannerView;
@end

static unsigned gSetupViewCalls = 0;
static unsigned gBannerGetterCalls = 0;
static BOOL gFixtureCreateCandidate = YES;
static BOOL gFixtureAttachCandidate = YES;
static BOOL gFixtureReshow = YES;
static BOOL gFixtureNestedSetup = NO;      // 让 fixture 的 setup 递归调用自己一次
static UIView *gFixtureGetterOverride;     // 非 nil 时原 getter 返回它（测 identity guard）
static id gFixtureLateNormalInCandidate;   // setup 期间塞进候选里的“正常控件”（模拟晚挂载）

@implementation BDPanNewMSHTopOperationView
- (id)bannerView {
    gBannerGetterCalls++;
    return gFixtureGetterOverride ? gFixtureGetterOverride : _bannerView;
}
- (void)setupView {
    gSetupViewCalls++;
    gFixtureInsideSetup++;
    if (gFixtureNestedSetup) {                              // 只嵌套一次（立即消费，禁无限递归）
        gFixtureNestedSetup = NO;
        [self setupView];
    }
    if (gFixtureCreateCandidate && !_bannerView) _bannerView = [[UIView alloc] init];
    [self bannerView];                                     // 真机里 setup 内部也会取它（走同一条方法路径）
    BOOL candidateIsView = [_bannerView isKindOfClass:[UIView class]];
    if (gFixtureAttachCandidate && candidateIsView) _bannerView.superview = (UIView *)self;
    if (gFixtureLateNormalInCandidate && candidateIsView) {
        gFixtureLateNormalInCandidate = nil;               // 只在 setup 内部挂一次
        UIView *normal = [[UIView alloc] init];
        normal.superview = _bannerView;
        _searchView = normal;
    }
    if (gFixtureReshow && candidateIsView) _bannerView.hidden = NO;
    gFixtureInsideSetup--;
}
@end

static void reset_fixture(void) {
    gEnabled = YES;
    gDumpOnly = NO;
    gExperimentHideHomeBanner = YES;
    gFixtureCreateCandidate = YES;
    gFixtureAttachCandidate = YES;
    gFixtureReshow = YES;
    gFixtureLateNormalInCandidate = nil;
    gFixtureNestedSetup = NO;
    gFixtureInsideSetup = 0;
    gFixtureGetterOverride = nil;
    gSetupViewCalls = 0;
    gBannerGetterCalls = 0;
    gHiddenYESWrites = 0;
    gHiddenYESWritesInsideSetup = 0;
}

static BDPanNewMSHTopOperationView *make_host(void) {
    BDPanNewMSHTopOperationView *host = [[BDPanNewMSHTopOperationView alloc] init];
    host->_bannerView = [[UIView alloc] init];
    host->_bannerView.superview = (UIView *)host;
    return host;
}

#pragma mark - 测试

static IMP gOrigSetupIMP, gOrigGetterIMP;

static void test_before_install(void) {
    gOrigSetupIMP = method_getImplementation(class_getInstanceMethod([BDPanNewMSHTopOperationView class],
                                                                     sel_registerName("setupView")));
    gOrigGetterIMP = method_getImplementation(class_getInstanceMethod([BDPanNewMSHTopOperationView class],
                                                                      sel_registerName("bannerView")));
    CHECK(gOrigSetupIMP != NULL && gOrigGetterIMP != NULL);
    CHECK(BDHBspecSetupView.installed == NO);
    CHECK(BDHBspecBannerView.installed == NO);
    BDPanNewMSHTopOperationView *host = make_host();
    reset_fixture();
    [host setupView];
    CHECK(gSetupViewCalls == 1);
    CHECK(gBannerGetterCalls == 1);             // 计数来自 fixture 原 setup 内部的那一次
    CHECK(gHiddenYESWrites == 0);
    CHECK(host->_searchView == nil);            // 不会凭空创建正常控件
}

static void test_install_and_getter(void) {
    unsigned logsBefore = gLogLines;
    BDHBInstallAll();
    CHECK(BDHBspecSetupView.installed == YES);
    CHECK(BDHBspecBannerView.installed == YES);
    CHECK(*BDHBspecSetupView.orig == gOrigSetupIMP);      // 先存的是原实现
    CHECK(*BDHBspecBannerView.orig == gOrigGetterIMP);
    CHECK(*BDHBspecSetupView.orig != (IMP)BDHBSetupView);   // orig 不能自指
    CHECK(*BDHBspecBannerView.orig != (IMP)BDHBBannerView);
    CHECK(method_getImplementation(class_getInstanceMethod([BDPanNewMSHTopOperationView class],
                                                           sel_registerName("setupView"))) == (IMP)BDHBSetupView);
    CHECK(method_getImplementation(class_getInstanceMethod([BDPanNewMSHTopOperationView class],
                                                           sel_registerName("bannerView"))) == (IMP)BDHBBannerView);
    CHECK(gLogLines == logsBefore + 2);          // 两条各一行 installed
    CHECK(BDHBCandidateIvar != NULL);
    CHECK(BDHBProtectedIvars[0] != NULL);

    // getter：原实现每次恰好一次、返回 identity、不递归
    BDPanNewMSHTopOperationView *host = make_host();
    id cand = host->_bannerView;
    reset_fixture();
    unsigned getterBefore = gBannerGetterCalls;
    id got = [host bannerView];
    CHECK(got == cand);
    CHECK(gBannerGetterCalls == getterBefore + 1);   // 外部 getter 只多一次原实现调用
    CHECK(gBannerGetterCalls == 1);                  // 该实例此前没跑过 setup
    CHECK(gHiddenYESWrites == 0);                    // 还没跑过 setup：ready 未建立，不隐藏
}

static void test_gate_passthrough(void) {
    BDPanNewMSHTopOperationView *host = make_host();

    // 1) 总开关关：setup 与 getter 都只透传，不写关联状态、不隐藏、无日志
    reset_fixture();
    gEnabled = NO;
    unsigned logsBefore = gLogLines;
    [host setupView];
    CHECK(gBannerGetterCalls == 1);              // setup 内部那一次（原实现照跑）
    unsigned getterBefore = gBannerGetterCalls;
    id got = [host bannerView];
    CHECK(gSetupViewCalls == 1);
    CHECK(gBannerGetterCalls == getterBefore + 1);   // 显式 getter 再 +1
    CHECK(gBannerGetterCalls == 2);
    CHECK(got == host->_bannerView);
    CHECK(gHiddenYESWrites == 0);
    CHECK(gLogLines == logsBefore);
    CHECK(objc_getAssociatedObject(host, &BDHBDepthKey) == nil);   // 关闭时连状态都不写
    gEnabled = YES;

    // 2) 诊断开
    reset_fixture();
    gDumpOnly = YES;
    [host setupView];
    CHECK(gHiddenYESWrites == 0);
    CHECK(objc_getAssociatedObject(host, &BDHBDepthKey) == nil);
    gDumpOnly = NO;

    // 3) 实验开关关（默认）
    reset_fixture();
    gExperimentHideHomeBanner = NO;
    [host setupView];
    CHECK(gHiddenYESWrites == 0);
    CHECK(objc_getAssociatedObject(host, &BDHBDepthKey) == nil);
    CHECK(host->_searchView == nil);             // 关着也不读/不创建正常控件
    gExperimentHideHomeBanner = YES;
}

static void test_hide_flow(void) {
    BDPanNewMSHTopOperationView *host = make_host();
    reset_fixture();
    unsigned logsBefore = gLogLines;

    // 1) 独立候选：setup 完成后隐藏，原 setter 的 NO 先执行 => 最终 YES 证明顺序
    [host setupView];
    CHECK(gSetupViewCalls == 1);
    CHECK(host->_bannerView.hidden == YES);
    CHECK(gHiddenYESWrites == 1);
    CHECK(gLogLines == logsBefore + 1);                 // 首次 hit 一行
    CHECK([(NSNumber *)objc_getAssociatedObject(host, &BDHBDepthKey) integerValue] == 0);   // ready

    // 2) 已隐藏 + 原实现不再显示 => 不重复写、不重复 hit
    gFixtureReshow = NO;
    [host setupView];
    CHECK(gHiddenYESWrites == 1);
    CHECK(gLogLines == logsBefore + 1);

    // 3) 原 setter 又把它显示出来（刷新/重排）=> setup 后再次隐藏，但不新增 hit
    gFixtureReshow = YES;
    [host setupView];
    CHECK(host->_bannerView.hidden == YES);
    CHECK(gHiddenYESWrites == 2);
    CHECK(gLogLines == logsBefore + 1);

    // 4) getter 路径：原实现一次、返回 identity；先显示回来，再通过 getter 隐藏
    gFixtureReshow = NO;
    host->_bannerView.hidden = NO;
    unsigned writesBefore = gHiddenYESWrites;
    unsigned getterBefore = gBannerGetterCalls;
    id got = [host bannerView];
    CHECK(got == host->_bannerView);
    CHECK(gBannerGetterCalls == getterBefore + 1);
    CHECK(gHiddenYESWrites == writesBefore + 1);         // getter 也真的能隐藏（ready==0）
    CHECK(host->_bannerView.hidden == YES);

    // 5) 另一个实例：在它自己第一次 setup 之前，getter 不能隐藏
    BDPanNewMSHTopOperationView *fresh = make_host();
    CHECK(objc_getAssociatedObject(fresh, &BDHBDepthKey) == nil);
    writesBefore = gHiddenYESWrites;
    id freshGot = [fresh bannerView];
    CHECK(freshGot == fresh->_bannerView);
    CHECK(gHiddenYESWrites == writesBefore);             // 未 ready：不动
    CHECK(fresh->_bannerView.hidden == NO);

    // 6) 不改 frame/高度（fixture 自己的数值字段）
    host->_bannerView.fixtureWidth = 402.0;
    host->_bannerView.fixtureHeight = 103.0;
    [host setupView];
    CHECK(host->_bannerView.fixtureWidth == 402.0);
    CHECK(host->_bannerView.fixtureHeight == 103.0);
}

static void test_setup_internal_getter_does_not_hide(void) {
    // setup 内部调用 bannerView（走 getter hook）时 ready != 0，不能隐藏
    BDPanNewMSHTopOperationView *host = make_host();
    reset_fixture();
    gFixtureReshow = NO;                    // 原实现不写 hidden，保持 NO
    gFixtureAttachCandidate = NO;           // setup 期间不挂载
    host->_bannerView.superview = nil;      // 真正未挂载（fixture 不放行，父保持 nil）
    gHiddenYESWrites = 0;
    gHiddenYESWritesInsideSetup = 0;
    [host setupView];
    CHECK(gBannerGetterCalls == 1);                       // 内部恰好取过一次
    CHECK(gHiddenYESWritesInsideSetup == 0);              // 初始化途中没人写过 hidden=YES
    CHECK(host->_bannerView.hidden == NO);                // 仍是可见
    CHECK(gHiddenYESWrites == 0);
    CHECK(host->_bannerView.superview == nil);            // setup 完成后依旧未挂载 -> 跳过
}

static void test_late_attach_protection(void) {
    // setup 期间把“正常控件”挂进候选：初始化内部不隐藏；setup 完成后因保护也不隐藏
    BDPanNewMSHTopOperationView *host = make_host();
    reset_fixture();
    gFixtureLateNormalInCandidate = [[UIView alloc] init];
    gFixtureReshow = NO;
    unsigned logsBefore = gLogLines;
    [host setupView];
    CHECK(host->_searchView != nil);                 // 晚挂载确实发生了
    CHECK(host->_bannerView.hidden == NO);           // 因保护保留容器
    CHECK(gHiddenYESWrites == 0);
    CHECK(gLogLines == logsBefore + 1);              // 保护 skip 一行

    // 把该正常控件移走后再跑：可以隐藏（说明是保护在起作用，不是永久失效）
    host->_searchView = nil;
    [host setupView];
    CHECK(host->_bannerView.hidden == YES);
    CHECK(gHiddenYESWrites == 1);
    CHECK(gBannerGetterCalls == 2);          // 两次 setup 各一次内部 getter
}

static void test_getter_identity_guard(void) {
    // 原 getter 若返回“别的兄弟 view”，只能保留它；自有候选不能被这次调用隐藏
    BDPanNewMSHTopOperationView *host = make_host();
    reset_fixture();
    [host setupView];                                   // 建立 ready=0
    unsigned logsBefore = gLogLines;
    host->_bannerView.hidden = NO;                      // 让自有候选处于可见状态
    UIView *sibling = [[UIView alloc] init];            // 兄弟：不是自有 _bannerView
    gFixtureGetterOverride = sibling;
    unsigned writesBefore = gHiddenYESWrites;
    unsigned getterBefore = gBannerGetterCalls;
    id got = [host bannerView];
    CHECK(got == sibling);                              // 原样返回
    CHECK(gBannerGetterCalls == getterBefore + 1);      // 原实现仍只多一次
    CHECK(gHiddenYESWrites == writesBefore);            // 没有隐藏任何东西
    CHECK(sibling.hidden == NO);
    CHECK(host->_bannerView.hidden == NO);              // 自有候选保持可见
    CHECK(gLogLines == logsBefore);                     // 同一 skip 原因只记一次（前面已记过）
    gFixtureGetterOverride = nil;
}

static void test_nested_setup(void) {
    // fixture 的 setup 内部递归调用自己一次：内层结束不隐藏，只有最外层完成才隐藏
    BDPanNewMSHTopOperationView *host = make_host();
    reset_fixture();
    gFixtureReshow = NO;
    gFixtureNestedSetup = YES;                          // 立即消费，不会无限递归
    [host setupView];
    CHECK(gSetupViewCalls == 2);                        // 恰好嵌套一次
    CHECK(gHiddenYESWrites == 1);                       // 只隐藏一次（内层没有动手）
    CHECK(gHiddenYESWritesInsideSetup == 0);            // 两次 setup 内部都没有 hidden=YES
    CHECK(host->_bannerView.hidden == YES);
    CHECK([(NSNumber *)objc_getAssociatedObject(host, &BDHBDepthKey) integerValue] == 0);   // 最外层收尾
}

static void test_protection_all_fields(void) {
    // 9 个字段逐个：等于候选 / 是候选后代；另加一个非 UIView 值 fail-closed
    for (unsigned i = 0; i < BDHB_PROTECTED_COUNT; i++) {
        const char *name = BDHBProtectedIvarNames[i];

        // (a) 该字段就是候选本身
        BDPanNewMSHTopOperationView *hostA = make_host();
        BDHBSetIvar(hostA, name, hostA->_bannerView);
        reset_fixture();
        gFixtureAttachCandidate = NO;
        gFixtureReshow = NO;
        [hostA setupView];
        CHECK(hostA->_bannerView.hidden == NO);

        // (b) 该字段是候选的后代
        BDPanNewMSHTopOperationView *hostB = make_host();
        UIView *normal = [[UIView alloc] init];
        normal.superview = hostB->_bannerView;
        BDHBSetIvar(hostB, name, normal);
        reset_fixture();
        gFixtureAttachCandidate = NO;
        gFixtureReshow = NO;
        [hostB setupView];
        CHECK(hostB->_bannerView.hidden == NO);
    }

    // (c) 非 UIView 值（NSString）=> fail-closed 保留
    BDPanNewMSHTopOperationView *hostC = make_host();
    BDHBSetIvar(hostC, "_searchBgView", @"not-a-view");
    reset_fixture();
    gFixtureAttachCandidate = NO;
    gFixtureReshow = NO;
    unsigned writesBefore = gHiddenYESWrites;
    [hostC setupView];
    CHECK(gHiddenYESWrites == writesBefore);
    CHECK(hostC->_bannerView.hidden == NO);

    // 其余字段保持 nil（没有被懒创建）
    CHECK(hostC->_plusButton == nil && hostC->_signButton == nil && hostC->_transDoneView == nil);
}

static void test_skip_candidates(void) {
    unsigned logsBefore = gLogLines;

    // 1) 候选 nil（原实现不创建）
    BDPanNewMSHTopOperationView *host1 = [[BDPanNewMSHTopOperationView alloc] init];
    reset_fixture();
    gFixtureCreateCandidate = NO;
    [host1 setupView];
    CHECK(gHiddenYESWrites == 0);
    CHECK(gLogLines == logsBefore + 1);
    [host1 setupView];
    CHECK(gLogLines == logsBefore + 1);                 // 同一原因只记一次

    // 2) 候选非 UIView（字符串；fixture 不写它的 superview，避免写坏对象）
    BDPanNewMSHTopOperationView *host2 = [[BDPanNewMSHTopOperationView alloc] init];
    BDHBSetIvar(host2, "_bannerView", @"not-a-view");
    reset_fixture();
    gFixtureCreateCandidate = NO;
    [host2 setupView];
    CHECK(gHiddenYESWrites == 0);

    // 3) 候选 == host
    BDPanNewMSHTopOperationView *host3 = [[BDPanNewMSHTopOperationView alloc] init];
    BDHBSetIvar(host3, "_bannerView", host3);
    reset_fixture();
    gFixtureCreateCandidate = NO;
    [host3 setupView];
    CHECK(gHiddenYESWrites == 0);

    // 4) 候选不是 host 的直接子视图（父是别的 view）
    BDPanNewMSHTopOperationView *host4 = make_host();
    UIView *foreignParent = [[UIView alloc] init];      // 父是别的 view（非 host）
    host4->_bannerView.superview = foreignParent;
    reset_fixture();
    gFixtureAttachCandidate = NO;
    gFixtureReshow = NO;
    [host4 setupView];
    CHECK(gHiddenYESWrites == 0);
    CHECK(host4->_bannerView.hidden == NO);
}

static void test_background_thread(void) {
    BDPanNewMSHTopOperationView *host = make_host();
    reset_fixture();
    unsigned logsBefore = gLogLines;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [host setupView];
        (void)[host bannerView];
        dispatch_semaphore_signal(done);
    });
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    CHECK(gSetupViewCalls == 1);                     // 原实现照跑（透传）
    CHECK(gBannerGetterCalls == 2);                  // setup 内 1 次 + 显式 1 次
    CHECK(gHiddenYESWrites == 0);                    // 非主线程不动手
    CHECK(host->_bannerView.hidden == NO);
    CHECK(gLogLines == logsBefore);                  // 也没有 hit / skip 噪音
    CHECK(objc_getAssociatedObject(host, &BDHBDepthKey) == nil);   // 后台不写状态
}

static void test_reinstall_idempotent(void) {
    BDPanNewMSHTopOperationView *host = make_host();
    unsigned logsBefore = gLogLines;
    BDHBInstallAll();
    CHECK(BDHBspecSetupView.installed == YES);
    CHECK(BDHBspecBannerView.installed == YES);
    CHECK(*BDHBspecSetupView.orig != (IMP)BDHBSetupView);        // orig 没被写成替换实现
    CHECK(*BDHBspecBannerView.orig != (IMP)BDHBBannerView);
    CHECK(gLogLines == logsBefore + 2);                          // 两行 already installed

    reset_fixture();
    unsigned hitsBefore = gLogLines;
    [host setupView];
    CHECK(gSetupViewCalls == 1);                                 // 没有自指递归
    CHECK(host->_bannerView.hidden == YES);
    CHECK(gLogLines == hitsBefore);                              // hit token 已消耗
}

#pragma mark - 失败路径（独立 phantom；不 reset 已装真 spec / 不改缓存）

static BDFRSpec BDHBTestSpec(const char *cls, const char *sel, const char *enc, unsigned argc,
                             IMP hook, IMP *orig, const char *name) {
    BDFRSpec s;
    s.cls = cls; s.sel = sel; s.isClassMethod = NO; s.enc = enc; s.argc = argc;
    s.hook = hook; s.orig = orig; s.name = name; s.installed = NO;
    return s;
}

static void add_own_ivars(Class c) {
    BDHBAddObjectIvar(c, "_bannerView");
    for (unsigned i = 0; i < BDHB_PROTECTED_COUNT; i++) BDHBAddObjectIvar(c, BDHBProtectedIvarNames[i]);
}

static void add_both_methods(Class c, const char *setupEnc) {
    CHECK(class_addMethod(c, sel_registerName("setupView"), (IMP)DummySetupMethod, setupEnc));
    CHECK(class_addMethod(c, sel_registerName("bannerView"), (IMP)DummyBannerMethod, "@16@0:8"));
}

static void test_skip_paths(void) {
    IMP o1 = NULL, o2 = NULL;

    // 1) 类缺失
    BDFRSpec s1 = BDHBTestSpec("BDHBPhantomMissing", "setupView", "v16@0:8", 2, (IMP)BDHBSetupView, &o1, "t-missing");
    BDFRSpec g1 = BDHBTestSpec("BDHBPhantomMissing", "bannerView", "@16@0:8", 2, (IMP)BDHBBannerView, &o2, "t-missing");
    CHECK(BDHBInstallWith(&s1, &g1) == NO);
    CHECK(s1.installed == NO && g1.installed == NO && o1 == NULL && o2 == NULL);

    // 2) 两条 spec 类不一致（其它都合法）
    IMP o3 = NULL, o4 = NULL;
    BDFRSpec s2 = BDHBTestSpec("BDHBPhantomSetupOnly", "setupView", "v16@0:8", 2, (IMP)BDHBSetupView, &o3, "t-class-mismatch");
    BDFRSpec g2 = BDHBTestSpec("BDHBPhantomGetterOnly", "bannerView", "@16@0:8", 2, (IMP)BDHBBannerView, &o4, "t-class-mismatch");
    CHECK(BDHBInstallWith(&s2, &g2) == NO);
    CHECK(s2.installed == NO && g2.installed == NO && o3 == NULL && o4 == NULL);

    // 3) encoding 不符：真注册 v24@0:8@16，spec 期望 v16@0:8（两条方法都存在且合法）
    Class encClass = BDHBMakeClass("BDHBPhantomEnc", Nil);
    add_own_ivars(encClass);
    add_both_methods(encClass, "v24@0:8@16");
    objc_registerClassPair(encClass);
    IMP o5 = NULL, o6 = NULL;
    BDFRSpec s3 = BDHBTestSpec("BDHBPhantomEnc", "setupView", "v16@0:8", 2, (IMP)BDHBSetupView, &o5, "t-wrong-enc");
    BDFRSpec g3 = BDHBTestSpec("BDHBPhantomEnc", "bannerView", "@16@0:8", 2, (IMP)BDHBBannerView, &o6, "t-wrong-enc");
    CHECK(BDHBInstallWith(&s3, &g3) == NO);
    CHECK(s3.installed == NO && o5 == NULL);

    // 4) 参数个数不符：真注册 v16@0:8（argc 2），spec 也写 v16@0:8 但期望 argc 3（真实差异）
    Class argcClass = BDHBMakeClass("BDHBPhantomArgc", Nil);
    add_own_ivars(argcClass);
    add_both_methods(argcClass, "v16@0:8");
    objc_registerClassPair(argcClass);
    IMP o7 = NULL, o8 = NULL;
    BDFRSpec s4 = BDHBTestSpec("BDHBPhantomArgc", "setupView", "v16@0:8", 3, (IMP)BDHBSetupView, &o7, "t-wrong-argc");
    BDFRSpec g4 = BDHBTestSpec("BDHBPhantomArgc", "bannerView", "@16@0:8", 2, (IMP)BDHBBannerView, &o8, "t-wrong-argc");
    CHECK(BDHBInstallWith(&s4, &g4) == NO);
    CHECK(s4.installed == NO && o7 == NULL);

    // 5) 只有父类实现（方法在父类，字段在本类）
    Class base = BDHBMakeClass("BDHBPhantomBase", Nil);
    CHECK(class_addMethod(base, sel_registerName("setupView"), (IMP)DummySetupMethod, "v16@0:8"));
    CHECK(class_addMethod(base, sel_registerName("bannerView"), (IMP)DummyBannerMethod, "@16@0:8"));
    objc_registerClassPair(base);
    Class sub = BDHBMakeClass("BDHBPhantomSub", base);
    add_own_ivars(sub);
    objc_registerClassPair(sub);
    IMP o9 = NULL, o10 = NULL;
    BDFRSpec s5 = BDHBTestSpec("BDHBPhantomSub", "setupView", "v16@0:8", 2, (IMP)BDHBSetupView, &o9, "t-inherited-method");
    BDFRSpec g5 = BDHBTestSpec("BDHBPhantomSub", "bannerView", "@16@0:8", 2, (IMP)BDHBBannerView, &o10, "t-inherited-method");
    CHECK(BDHBInstallWith(&s5, &g5) == NO);
    CHECK(s5.installed == NO && o9 == NULL);
    CHECK(method_getImplementation(class_getInstanceMethod(base, sel_registerName("setupView"))) == (IMP)DummySetupMethod);

    // 6) 字段只在父类（方法自有、签名合法）=> 自有表校验必须拒装
    Class ivarBase = BDHBMakeClass("BDHBPhantomIvarBase", Nil);
    add_own_ivars(ivarBase);
    objc_registerClassPair(ivarBase);
    Class ivarChild = BDHBMakeClass("BDHBPhantomIvarChild", ivarBase);
    add_both_methods(ivarChild, "v16@0:8");
    objc_registerClassPair(ivarChild);
    IMP o11 = NULL, o12 = NULL;
    BDFRSpec s6 = BDHBTestSpec("BDHBPhantomIvarChild", "setupView", "v16@0:8", 2, (IMP)BDHBSetupView, &o11, "t-ivar-on-parent");
    BDFRSpec g6 = BDHBTestSpec("BDHBPhantomIvarChild", "bannerView", "@16@0:8", 2, (IMP)BDHBBannerView, &o12, "t-ivar-on-parent");
    CHECK(BDHBInstallWith(&s6, &g6) == NO);
    CHECK(s6.installed == NO && g6.installed == NO && o11 == NULL && o12 == NULL);
    CHECK(method_getImplementation(class_getInstanceMethod(ivarChild, sel_registerName("setupView"))) == (IMP)DummySetupMethod);

    // 7) 本类少一个字段（方法合法）
    Class missing = BDHBMakeClass("BDHBPhantomMissingIvar", Nil);
    BDHBAddObjectIvar(missing, "_bannerView");
    for (unsigned i = 0; i + 1 < BDHB_PROTECTED_COUNT; i++) BDHBAddObjectIvar(missing, BDHBProtectedIvarNames[i]);
    add_both_methods(missing, "v16@0:8");
    objc_registerClassPair(missing);
    IMP o13 = NULL, o14 = NULL;
    BDFRSpec s7 = BDHBTestSpec("BDHBPhantomMissingIvar", "setupView", "v16@0:8", 2, (IMP)BDHBSetupView, &o13, "t-missing-ivar");
    BDFRSpec g7 = BDHBTestSpec("BDHBPhantomMissingIvar", "bannerView", "@16@0:8", 2, (IMP)BDHBBannerView, &o14, "t-missing-ivar");
    CHECK(BDHBInstallWith(&s7, &g7) == NO);
    CHECK(s7.installed == NO && g7.installed == NO);

    // 8) 字段存在但类型不是 object（BOOL）
    Class wrongType = BDHBMakeClass("BDHBPhantomWrongType", Nil);
    BDHBAddObjectIvar(wrongType, "_bannerView");
    for (unsigned i = 0; i + 1 < BDHB_PROTECTED_COUNT; i++) BDHBAddObjectIvar(wrongType, BDHBProtectedIvarNames[i]);
    CHECK(class_addIvar(wrongType, BDHBProtectedIvarNames[BDHB_PROTECTED_COUNT - 1], sizeof(BOOL), (uint8_t)0, "B"));
    add_both_methods(wrongType, "v16@0:8");
    objc_registerClassPair(wrongType);
    IMP o15 = NULL, o16 = NULL;
    BDFRSpec s8 = BDHBTestSpec("BDHBPhantomWrongType", "setupView", "v16@0:8", 2, (IMP)BDHBSetupView, &o15, "t-wrong-type");
    BDFRSpec g8 = BDHBTestSpec("BDHBPhantomWrongType", "bannerView", "@16@0:8", 2, (IMP)BDHBBannerView, &o16, "t-wrong-type");
    CHECK(BDHBInstallWith(&s8, &g8) == NO);
    CHECK(s8.installed == NO && o15 == NULL);

    // 所有失败路径都没影响已装的真 spec 与缓存
    CHECK(BDHBspecSetupView.installed == YES);
    CHECK(BDHBspecBannerView.installed == YES);
    CHECK(BDHBCandidateIvar != NULL);
    CHECK(*BDHBspecSetupView.orig != (IMP)BDHBSetupView);
}

#pragma mark - main

int main(void) {
    @autoreleasepool {
        // 真实 FeatureRemoval.h 的 BDFRInstallAll 在本 TU 没人调用会触发 unused-function。
        // 它的目标类在这里都不存在，只会逐条 skip，不碰本实验的类与断言。
        BDFRInstallAll();

        test_before_install();
        test_install_and_getter();
        test_gate_passthrough();
        test_hide_flow();
        test_setup_internal_getter_does_not_hide();
        test_late_attach_protection();
        test_skip_candidates();          // 先消耗 candidate-skip 的首行日志
        test_getter_identity_guard();    // 再验证同一原因不再新增行
        test_nested_setup();
        test_protection_all_fields();
        test_background_thread();
        test_reinstall_idempotent();
        test_skip_paths();

        printf("%s: %d 项失败（日志共 %u 行）\n",
               gFailures ? "FAIL" : "PASS", gFailures, gLogLines);
    }
    return gFailures ? 1 : 0;
}
