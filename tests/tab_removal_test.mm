// tests/tab_removal_test.mm — TabRemoval.h 的 macOS host 机制测试
//
// 用动态 fake 类 + 真实同名 selector 跑真安装器；开关用内存里的假函数，
// 不碰 NSUserDefaults，不写任何文件，不连网。
//
// 测的是**机制**：AI 条被按 identity 过滤并生成坐标 map；四个 index getter 先调原 IMP 再换算；
// 根身份来自 customTabBar 的同步上下文或 AppDelegate 的 active root（不是「最后进过 setter 的实例」）；
// 没命中/开关关/滤空/非法入参时原样透传；整组校验不过就一个 IMP 都不写。
// **不测 App 真机路由**：页面跳转、点击、红点等仍需真机。
//
// 构建运行（macOS，无需 IPA，无需 Theos）：
//   clang++ -std=c++17 -fobjc-arc -fblocks -Wall -Wextra -Werror \
//     -framework Foundation -o /tmp/tab_removal_test tests/tab_removal_test.mm
//   /tmp/tab_removal_test

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#include <stdio.h>
#include <string.h>

#pragma mark - 假开关 / 假日志（FeatureRemoval.h 与 TabRemoval.h 依赖这些同名静态函数）

static BOOL gEnabled = YES;
static BOOL gDumpOnly = NO;
static BOOL gRemoveAITab = YES;
static BOOL gRemoveRecommend = YES;
static BOOL gRemoveGameCenter = YES;
static BOOL gRemoveJobNovel = YES;
static unsigned gLogLines = 0;

static void BDLog(NSString *fmt, ...) {
    (void)fmt;          // 只数行数；测试不比对日志文本
    gLogLines++;
}
static BOOL BDEnabled(void)          { return gEnabled; }
static BOOL BDDumpOnly(void)         { return gDumpOnly; }
static BOOL BDRemoveAITab(void)      { return gRemoveAITab; }
static BOOL BDRemoveRecommend(void)  { return gRemoveRecommend; }
static BOOL BDRemoveGameCenter(void) { return gRemoveGameCenter; }
static BOOL BDRemoveJobNovel(void)   { return gRemoveJobNovel; }

#include "../FeatureRemoval.h"
#include "../TabRemoval.h"

#pragma mark - 断言与动态 fake 类

static int gFailures = 0;

#define CHECK(cond)                                                        \
    do {                                                                   \
        if (!(cond)) {                                                     \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
            gFailures++;                                                   \
        }                                                                  \
    } while (0)

static Class MakeClass(const char *name, Class super) {
    Class c = objc_allocateClassPair(super ? super : [NSObject class], name, 0);
    CHECK(c != nil);
    if (c) objc_registerClassPair(c);
    return c;
}

static Class gModelCls;     // fake BDTabItemModel
static Class gTabCls;       // fake BDPanTabBarController
static Class gIndexCls;     // fake BDTabViewController（四个索引是类方法）

// fake model 的属性用关联对象存（不改 ivar 布局，也不改已注册方法的 encoding）。
// type 仍然建模并可设置，只是产品代码不再读它 —— 用例靠它证明「type 不影响判据」。
static char kFakeTypeKey;
static char kFakeNameKey;

static unsigned long long TItemType(id self, SEL _cmd) {
    (void)_cmd;
    NSNumber *n = objc_getAssociatedObject(self, &kFakeTypeKey);
    return n ? n.unsignedLongLongValue : 0ULL;
}
static id TItemName(id self, SEL _cmd) {
    (void)_cmd;
    return objc_getAssociatedObject(self, &kFakeNameKey);
}
static id MakeModel(const char *name, unsigned long long type) {
    id m = [[gModelCls alloc] init];
    objc_setAssociatedObject(m, &kFakeNameKey, @(name), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(m, &kFakeTypeKey, @(type), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return m;
}

// 原 setter：只记录收到的对象与次数，不做任何加工
static id gLastModels = nil;
static NSInteger gSetCalls = 0;
static void TSetModels(id self, SEL _cmd, id models) {
    (void)self; (void)_cmd;
    gSetCalls++;
    gLastModels = models;
}

// 原 customTabBar：模拟原生链路 —— 读四个索引 getter 并记录返回值。
// 可配行为（都只为机制测试，产品侧没有这些）：再发一次 customTabBar（gNestedTarget）、
// 抛预设异常、进入 ctx 后用信号量暂停（跨线程用例）。这些开关都在测试里，不进产品。
static NSInteger gCustomCalls = 0;            // 原 customTabBar 被调总次数（嵌套算两次）
static NSInteger gNestedCalls = 0;            // 外层发起过嵌套的次数
static NSInteger gInsideFriends = -99, gInsideMagic = -99, gInsideFind = -99, gInsideSetting = -99;
static NSInteger gBeforeFriends = -99;         // 嵌套「之前」读到的值（外层视角）
static NSInteger gAfterFriends = -99;          // 嵌套「之后」读到的值：证明 ctx 已回到外层 receiver
static void *gCtxAfterNested = (void *)-1;     // 嵌套返回瞬间观察到的 ctx 指针
static id gNestedTarget;                       // 嵌套目标：用例自己创建并强持有的 fixture
static id gCountedOuter;                        // 只统计这一个 receiver 的原实现被调了几次
static NSInteger gOuterOriginalCalls = 0;
static BOOL gCustomThrows = NO;
static NSString * const kTestExceptionName = @"BDTRTestException";

// 跨线程暂停：只给「ctx 是线程局部」那条用例用。产品不调度、不发信号。
static dispatch_semaphore_t gEnteredSignal = nil, gResumeSignal = nil;
static void *gCtxOnBackground = NULL;

static NSInteger CallOriginalIndex(const char *name) {
    SEL sel = sel_registerName(name);
    NSInteger (*imp)(id, SEL) =
        (NSInteger (*)(id, SEL))class_getMethodImplementation(object_getClass(gIndexCls), sel);
    return imp(gIndexCls, sel);
}

static void TCustomTabBar(id self, SEL _cmd) {
    (void)_cmd;
    gCustomCalls++;
    if (self == gCountedOuter) gOuterOriginalCalls++;
    gInsideFriends = CallOriginalIndex("friendsIndex");
    gInsideMagic = CallOriginalIndex("magicTrickIndex");
    gInsideFind = CallOriginalIndex("findSourceIndex");
    gInsideSetting = CallOriginalIndex("settingIndex");

    dispatch_semaphore_t entered = gEnteredSignal;     // 只暂停最外层那一层
    if (entered) {
        gEnteredSignal = nil;
        gCtxOnBackground = BDTRContextController;       // 后台线程此刻压的是谁
        dispatch_semaphore_signal(entered);
        dispatch_semaphore_wait(gResumeSignal, DISPATCH_TIME_FOREVER);
    }

    id inner = gNestedTarget;
    if (inner) {
        gNestedTarget = nil;                            // 只嵌一层
        gBeforeFriends = CallOriginalIndex("friendsIndex");
        SEL sel = @selector(customTabBar);
        void (*imp)(id, SEL) = (void (*)(id, SEL))
            class_getMethodImplementation(object_getClass(inner), sel);
        imp(inner, sel);
        gNestedCalls++;
        gAfterFriends = CallOriginalIndex("friendsIndex");
        gCtxAfterNested = BDTRContextController;        // 必须是外层 self，不是 inner
    }

    if (gCustomThrows)
        [NSException raise:kTestExceptionName format:@"preset"];
}

// AppDelegate 的 active root：weak，模拟系统只弱持有 active，不让 fixture 强持有掩盖生命周期
static __weak id gActiveRoot;
static Class gAppDelegateCls;

static id TActiveTabBarController(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return gActiveRoot;      // 故意不 retain：读出来就是 weak 当时的状态
}

// 四个原索引 getter：返回值可配，并各自记调用次数（验证 wrapper 只调原 IMP 一次）
static NSInteger gFriends = 3, gMagic = 2, gFindSource = -1, gSetting = 4;
static NSInteger gOrigFriendsCalls = 0, gOrigMagicCalls = 0;
static NSInteger gOrigFindCalls = 0, gOrigSettingCalls = 0;
static NSInteger TIndex(id self, SEL cmd) {
    (void)self;
    const char *n = sel_getName(cmd);
    if (strcmp(n, "friendsIndex") == 0)    { gOrigFriendsCalls++; return gFriends; }
    if (strcmp(n, "magicTrickIndex") == 0) { gOrigMagicCalls++;   return gMagic; }
    if (strcmp(n, "findSourceIndex") == 0) { gOrigFindCalls++;     return gFindSource; }
    if (strcmp(n, "settingIndex") == 0)    { gOrigSettingCalls++;  return gSetting; }
    return -99;   // 未列出的 selector 不该被装
}

static void SendModels(id tab, id models) {
    SEL sel = @selector(setTabBarItemModels:);
    void (*imp)(id, SEL, id) =
        (void (*)(id, SEL, id))class_getMethodImplementation(gTabCls, sel);
    imp(tab, sel, models);
}
static void SendCustomTabBar(id tab) {
    SEL sel = @selector(customTabBar);
    void (*imp)(id, SEL) = (void (*)(id, SEL))class_getMethodImplementation(gTabCls, sel);
    imp(tab, sel);
}
static NSInteger SendIndex(const char *name) {
    SEL sel = sel_registerName(name);
    NSInteger (*imp)(id, SEL) =
        (NSInteger (*)(id, SEL))class_getMethodImplementation(object_getClass(gIndexCls), sel);
    return imp(gIndexCls, sel);
}

// 直接读产品挂在 controller 上的 map（同 TU，同一个 key）：只观察，不复制映射算法
static NSArray *MapOf(id tab) {
    return objc_getAssociatedObject(tab, &kBDTRIndexMapKey);
}

static void SetupFakes(void) {
    gModelCls = MakeClass("BDTabItemModel", Nil);
    CHECK(class_addMethod(gModelCls, @selector(itemType), (IMP)TItemType, "Q16@0:8"));
    CHECK(class_addMethod(gModelCls, @selector(itemTabName), (IMP)TItemName, "@16@0:8"));

    gTabCls = MakeClass("BDPanTabBarController", Nil);
    CHECK(class_addMethod(gTabCls, @selector(setTabBarItemModels:), (IMP)TSetModels, "v24@0:8@16"));
    CHECK(class_addMethod(gTabCls, @selector(customTabBar), (IMP)TCustomTabBar, "v16@0:8"));

    gAppDelegateCls = MakeClass("AppDelegate", Nil);
    CHECK(class_addMethod(object_getClass(gAppDelegateCls),
                          @selector(ad_curTabBarController), (IMP)TActiveTabBarController, "@16@0:8"));

    gIndexCls = MakeClass("BDTabViewController", Nil);
    const char *names[] = {"friendsIndex", "magicTrickIndex", "findSourceIndex", "settingIndex"};
    for (unsigned i = 0; i < 4; i++)
        CHECK(class_addMethod(object_getClass(gIndexCls), sel_registerName(names[i]),
                              (IMP)TIndex, "q16@0:8"));

    BDFRInstallAll();     // FeatureRemoval 那套：这些类不存在，应整组 skip，不崩
    BDTRInstallAll();     // 本组件真实安装
    CHECK(gSetCalls == 0);                 // 安装阶段不该调用任何被 hook 的方法
    CHECK(BDTRItemTabNameImp == (IMP)TItemName);   // 名字依赖 IMP 已保存
    CHECK(BDTRActiveTabBarImp == (IMP)TActiveTabBarController);  // active root 读取器已保存
    CHECK(BDTRModelClass == gModelCls);
    CHECK(BDTRAppDelegateClass == gAppDelegateCls);
    CHECK(BDTROrigSetModels == (IMP)TSetModels);   // 先存原 IMP
    CHECK(BDTROrigCustomTabBar == (IMP)TCustomTabBar);
}

#pragma mark - 1 基准：5 项含 AI

static void TestCanonicalFive(void) {
    id tab = [[gTabCls alloc] init];
    id home = MakeModel("home_page", 0), file = MakeModel("file_page", 0);
    id ai = MakeModel("shenji_page", 1);
    id shared = MakeModel("shared_page", 0), mine = MakeModel("mine_page", 0);
    NSArray *in = @[home, file, ai, shared, mine];

    gSetCalls = 0; gLastModels = nil;
    SendModels(tab, in);

    CHECK(gSetCalls == 1);                       // 原 setter 只被调一次
    NSArray *out = (NSArray *)gLastModels;
    CHECK(out != in);                            // 过滤后是新数组
    CHECK(out.count == 4);
    CHECK(out[0] == home && out[1] == file && out[2] == shared && out[3] == mine);  // 同对象、同顺序

    NSArray *map = MapOf(tab);
    CHECK(map.count == 5);
    CHECK([map[0] intValue] == 0 && [map[1] intValue] == 1 && [map[2] intValue] == -1);
    CHECK([map[3] intValue] == 2 && [map[4] intValue] == 3);

    gFriends = 3; gMagic = 2; gFindSource = -1; gSetting = 4;
    gActiveRoot = tab;                             // 系统承认它是 active：下面这四个才按它的图换算
    CHECK(SendIndex("friendsIndex") == 2);       // 3 → 2
    CHECK(SendIndex("magicTrickIndex") == -1);   // 2 → -1（App 原生缺席语义）
    CHECK(SendIndex("findSourceIndex") == -1);   // -1 透传
    CHECK(SendIndex("settingIndex") == 3);       // 4 → 3
    gActiveRoot = nil;
}

#pragma mark - 2 AI 位置与类型判据

static void TestPositionsAndPredicates(void) {
    id tab = [[gTabCls alloc] init];
    gActiveRoot = tab;          // 本例的换算断言都以「tab 就是 active root」为前提

    // AI 在开头：4 项去掉 AI 后剩 3 项；老下标 3 映射到新 2
    id ai = MakeModel("shenji_page", 1), home = MakeModel("home_page", 0);
    id file = MakeModel("file_page", 0), shared = MakeModel("shared_page", 0);
    SendModels(tab, @[ai, home, file, shared]);
    NSArray *out = (NSArray *)gLastModels;
    CHECK(out.count == 3 && out[0] == home && out[1] == file && out[2] == shared);
    NSArray *map = MapOf(tab);
    CHECK([map[0] intValue] == -1 && [map[1] intValue] == 0);
    CHECK([map[2] intValue] == 1 && [map[3] intValue] == 2);
    gFriends = 3;
    CHECK(SendIndex("friendsIndex") == 2);

    // AI 在末尾：shared 的老下标 2 不变（仍是 2），末尾那条 AI 的老下标 3 变 -1
    SendModels(tab, @[home, file, shared, MakeModel("shenji_page", 1)]);
    out = (NSArray *)gLastModels;
    CHECK(out.count == 3 && out[2] == shared);
    CHECK([MapOf(tab)[2] intValue] == 2 && [MapOf(tab)[3] intValue] == -1);
    gFriends = 2;
    CHECK(SendIndex("friendsIndex") == 2);
    gMagic = 3;                                    // 老下标 3 = 末尾那条 AI
    CHECK(SendIndex("magicTrickIndex") == -1);     // 缺席语义：不是 2，也不是原值 3

    // 名字不精确匹配的不算 AI：shenji_page_2 只是长得像，三个保留项 identity 与顺序都不变
    id ai1 = MakeModel("shenji_page", 0), ai2 = MakeModel("shenji_page_2", 1);
    SendModels(tab, @[ai1, home, ai2, shared]);
    out = (NSArray *)gLastModels;
    CHECK(out.count == 3 && out[0] == home && out[1] == ai2 && out[2] == shared);
    CHECK([MapOf(tab)[0] intValue] == -1 && [MapOf(tab)[1] intValue] == 0);
    CHECK([MapOf(tab)[2] intValue] == 1 && [MapOf(tab)[3] intValue] == 2);

    // 真正的多命中：两条名字精确等于 shenji_page（type 还一 0 一 1）→ 两条都滤掉，map 两个 -1
    id twinA = MakeModel("shenji_page", 1), twinB = MakeModel("shenji_page", 0);
    SendModels(tab, @[home, twinA, file, twinB, shared]);
    out = (NSArray *)gLastModels;
    CHECK(out.count == 3 && out[0] == home && out[1] == file && out[2] == shared);
    NSArray *twinMap = MapOf(tab);
    CHECK(twinMap.count == 5);
    CHECK([twinMap[0] intValue] == 0 && [twinMap[1] intValue] == -1);
    CHECK([twinMap[2] intValue] == 1 && [twinMap[3] intValue] == -1);
    CHECK([twinMap[4] intValue] == 2);

    // 非 AI 的 type 0 页照留（名字不含 shenji）
    id vip = MakeModel("vip_page", 0), pmall = MakeModel("pmall_page", 0), yike = MakeModel("yike_page", 0);
    SendModels(tab, @[vip, pmall, yike]);
    out = (NSArray *)gLastModels;
    CHECK(out.count == 3 && out[0] == vip && out[1] == pmall && out[2] == yike);
    CHECK(MapOf(tab) == nil);                    // 没移除 → map 清除

    // itemType 不再参与判据：type 1 但名字不是 shenji_page，一律不移除
    // （这正是未登录 tab bar 把 type 1 赋给 shared_page 的那种形态）
    NSArray *typedOnes = @[MakeModel("shared_page", 1), MakeModel("vip_page", 1),
                           MakeModel("pmall_page", 1), MakeModel("yike_page", 1),
                           MakeModel("find_page", 1)];
    SendModels(tab, typedOnes);
    out = (NSArray *)gLastModels;
    CHECK(out == typedOnes);                     // 同一对象，没 copy
    CHECK(out.count == 5);
    CHECK(MapOf(tab) == nil);                    // 没移除 → map 清除
    gFriends = 3; gMagic = 2; gFindSource = 3; gSetting = 4;
    CHECK(SendIndex("friendsIndex") == 3 && SendIndex("magicTrickIndex") == 2);
    CHECK(SendIndex("findSourceIndex") == 3 && SendIndex("settingIndex") == 4);

    // 反向：type 0 但名字是 shenji_page，仍然移除（判据只看名字）
    id odd = MakeModel("shenji_page", 0);
    SendModels(tab, @[home, odd, shared]);
    out = (NSArray *)gLastModels;
    CHECK(out.count == 2 && out[0] == home && out[1] == shared);
    CHECK([MapOf(tab)[1] intValue] == -1 && [MapOf(tab)[2] intValue] == 1);
    gActiveRoot = nil;
}

#pragma mark - 3 没命中 / 会滤空 / 非法入参 / 意外元素

static void TestPassthroughCases(void) {
    id tab = [[gTabCls alloc] init];
    id home = MakeModel("home_page", 0), shared = MakeModel("shared_page", 0);
    NSArray *noAI = @[home, shared];

    gLastModels = nil;
    SendModels(tab, noAI);
    CHECK(gLastModels == noAI);                  // 同一对象，没 copy
    CHECK(MapOf(tab) == nil);
    gFriends = 3; gMagic = 2; gFindSource = -1; gSetting = 4;
    CHECK(SendIndex("friendsIndex") == 3 && SendIndex("magicTrickIndex") == 2);
    CHECK(SendIndex("settingIndex") == 4);

    // 只有 AI：不能滤空
    NSArray *onlyAI = @[MakeModel("shenji_page", 1)];
    SendModels(tab, onlyAI);
    CHECK(gLastModels == onlyAI);
    CHECK(MapOf(tab) == nil);

    // nil / 空 / 错误类型：原样透传，不发消息、不崩
    SendModels(tab, nil);
    CHECK(gLastModels == nil);
    SendModels(tab, @[]);
    NSArray *empty = (NSArray *)gLastModels;
    CHECK(empty != nil && empty.count == 0);
    SendModels(tab, (id)@"not-an-array");
    CHECK([gLastModels isKindOfClass:[NSString class]]);   // 错误类型用例按 id 检查

    // 意外元素（NSNumber / NSNull）不崩、原样保留，且各占一个 map 位
    id num = @42;
    id nul = [NSNull null];
    NSArray *mixed = @[MakeModel("home_page", 0), num, nul, MakeModel("shenji_page", 1), shared];
    SendModels(tab, mixed);
    NSArray *out = (NSArray *)gLastModels;
    CHECK(out.count == 4);
    CHECK(out[1] == num && out[2] == nul);
    CHECK(out[3] == shared);
    CHECK([MapOf(tab)[1] intValue] == 1 && [MapOf(tab)[2] intValue] == 2 && [MapOf(tab)[3] intValue] == -1);
}

#pragma mark - 4 开关、重复调用、实例切换、整组校验

static void TestGatesAndLifecycle(void) {
    id tab = [[gTabCls alloc] init];
    id ai = MakeModel("shenji_page", 1), home = MakeModel("home_page", 0), shared = MakeModel("shared_page", 0);
    NSArray *withAI = @[home, ai, shared];
    gFriends = 3;
    gEnabled = YES; gDumpOnly = NO; gRemoveAITab = YES;

    SendModels(tab, withAI);
    NSArray *out = (NSArray *)gLastModels;
    CHECK(out.count == 2 && MapOf(tab) != nil);

    // 恢复（同一 controller 再 set 一次无 AI 的数组）→ map 清除、getter 回原值
    SendModels(tab, @[home, shared]);
    CHECK(MapOf(tab) == nil);
    CHECK(SendIndex("friendsIndex") == 3);

    // 三个开关的组合：各自关掉都要原样透传
    gEnabled = NO;
    SendModels(tab, withAI);
    CHECK(gLastModels == withAI && SendIndex("friendsIndex") == 3);
    gEnabled = YES;

    gDumpOnly = YES;
    SendModels(tab, withAI);
    CHECK(gLastModels == withAI && SendIndex("friendsIndex") == 3);
    gDumpOnly = NO;

    gRemoveAITab = NO;
    SendModels(tab, withAI);
    CHECK(gLastModels == withAI && SendIndex("friendsIndex") == 3);
    gRemoveAITab = YES;

    // 两个 controller：稳态按 AppDelegate 认定的 active root 取图，与「谁最后进过 setter」无关。
    // A 的输入 4 项 [home, AI, shared, vip] → map [0,-1,1,2]
    id tabA = [[gTabCls alloc] init];
    SendModels(tabA, @[home, MakeModel("shenji_page", 0), shared, MakeModel("vip_page", 0)]);
    CHECK(MapOf(tabA) != nil);
    gMagic = 0;
    CHECK(SendIndex("magicTrickIndex") == 0);     // active 还没设 → 无 active root → 原值

    gActiveRoot = tabA;                           // 系统现在承认 A 是 active
    CHECK(SendIndex("magicTrickIndex") == 0);     // A: map[0] = 0

    // B 的输入是 3 项 [AI, home, shared] → map [-1,0,1]；A 的 map 是 [0,-1,1,2]。
    // 取两个 A/B 映射不同的老下标，值不同才看得出到底读的谁的图（老下标 2 两边都是 1，不可用）。
    id tabB = [[gTabCls alloc] init];
    SendModels(tabB, @[MakeModel("shenji_page", 0), home, shared]);
    CHECK(MapOf(tabB) != nil);
    gMagic = 0;
    CHECK(SendIndex("magicTrickIndex") == 0);     // 老 0：A→0，B→-1
    gFriends = 1;
    CHECK(SendIndex("friendsIndex") == -1);       // 老 1：A→-1，B→0

    // 切到「未登录 / 企业空间 / 青少年模式」那种没有 map 的 root → 原值，不落回 A 的图
    @autoreleasepool {
        id otherRoot = [[NSObject alloc] init];   // 别的 root 类型：不经过我们的 setter
        gActiveRoot = otherRoot;
        CHECK(gActiveRoot != nil);                 // 确认 weak 还指着它，下面的原值才是真透传
        gFriends = 3;
        CHECK(SendIndex("friendsIndex") == 3);     // 原值透传，不是 A 的 1
    }
    CHECK(tabA != nil);                           // 旧实例仍被强持有，也不该串图

    // 切回正常 root → 按自身图换算
    gActiveRoot = tabA;
    gFriends = 2;
    CHECK(SendIndex("friendsIndex") == 1);
    gActiveRoot = nil;

    // 重复安装：不动 IMP、不递归
    IMP before = class_getMethodImplementation(gTabCls, @selector(setTabBarItemModels:));
    BDTRInstallAll();
    CHECK(class_getMethodImplementation(gTabCls, @selector(setTabBarItemModels:)) == before);
    CHECK(BDTROrigSetModels == (IMP)TSetModels);
    CHECK(BDTROrigCustomTabBar == (IMP)TCustomTabBar);
    SendModels(tabA, @[home, MakeModel("shenji_page", 0), shared, MakeModel("vip_page", 0)]);
    out = (NSArray *)gLastModels;
    CHECK(out.count == 3);
}

#pragma mark - 5 整组校验不过就一个 IMP 都不写

static IMP gPhantomOrig = NULL;
static unsigned long long PhantomULong(id self, SEL _cmd) { (void)self; (void)_cmd; return 0; }
static void PhantomVoid(id self, SEL _cmd) { (void)self; (void)_cmd; }
static void PhantomWrap(id self, SEL _cmd) { ((void (*)(id, SEL))gPhantomOrig)(self, _cmd); }

static void TestGroupAllOrNothing(void) {
    Class bad = MakeClass("BDTRPhantomBadTarget", Nil);
    CHECK(class_addMethod(bad, sel_registerName("phantomIndex"), (IMP)PhantomVoid, "v16@0:8"));
    SEL sel = sel_registerName("phantomIndex");
    IMP before = class_getMethodImplementation(bad, sel);

    // 单条描述用本地一元素「指针数组」包装再传给 Group（形参是 BDFRSpec *const *）
    BDFRSpec badSpec = { "BDTRPhantomBadTarget", "phantomIndex", NO, "q16@0:8", 2,
                         (IMP)PhantomWrap, &gPhantomOrig, "phantom-bad-enc", NO };
    BDFRSpec *badArr[] = { &badSpec };

    // (a) encoding 不符
    CHECK(BDTRInstallGroup(badArr, 1, NULL, 0) == NO);
    CHECK(class_getMethodImplementation(bad, sel) == before);

    // (b) 方法不在本类自己的表里
    (void)MakeClass("BDTRPhantomBadChild", bad);
    BDFRSpec inherited = { "BDTRPhantomBadChild", "phantomIndex", NO, "v16@0:8", 2,
                          (IMP)PhantomWrap, &gPhantomOrig, "phantom-inherited", NO };
    BDFRSpec *inheritedArr[] = { &inherited };
    CHECK(BDTRInstallGroup(inheritedArr, 1, NULL, 0) == NO);
    CHECK(class_getMethodImplementation(bad, sel) == before);

    // (c) 依赖 encoding 不符（注册成小写 q，期望大写 Q）。selector 名随便取，
    //     这里只验证「依赖不过就整组不装」，与产品真实依赖名无关。
    Class badDep = MakeClass("BDTRPhantomBadDep", Nil);
    CHECK(class_addMethod(badDep, sel_registerName("phantomDepSel"), (IMP)PhantomULong, "q16@0:8"));
    BDFRSpec badDepSpec = { "BDTRPhantomBadDep", "phantomDepSel", NO, "Q16@0:8", 2,
                            NULL, NULL, "phantom-dep-bad-enc", NO };
    BDFRSpec *badDepArr[] = { &badDepSpec };
    BDFRSpec okSpec = { "BDTRPhantomBadTarget", "phantomIndex", NO, "v16@0:8", 2,
                        (IMP)PhantomWrap, &gPhantomOrig, "phantom-ok", NO };
    BDFRSpec *okArr[] = { &okSpec };
    CHECK(BDTRInstallGroup(okArr, 1, badDepArr, 1) == NO);
    CHECK(class_getMethodImplementation(bad, sel) == before);   // 依赖不过 → 目标也不装
    CHECK(gPhantomOrig == NULL);

    // (d) 依赖类不存在
    BDFRSpec missingDep = { "BDTRPhantomNoDepClass", "phantomDepSel", NO, "Q16@0:8", 2,
                            NULL, NULL, "phantom-dep-missing", NO };
    BDFRSpec *missingDepArr[] = { &missingDep };
    CHECK(BDTRInstallGroup(okArr, 1, missingDepArr, 1) == NO);
    CHECK(class_getMethodImplementation(bad, sel) == before);
    CHECK(gPhantomOrig == NULL);
}

// (a) 还没有任何 active root → 四 getter 原值透传（必须早于任何 setter 调用）
static void TestNoActiveRootYet(void) {
    CHECK(gActiveRoot == nil);
    gFriends = 3; gMagic = 2; gFindSource = 7; gSetting = 4;
    CHECK(SendIndex("friendsIndex") == 3);
    CHECK(SendIndex("magicTrickIndex") == 2);
    CHECK(SendIndex("findSourceIndex") == 7);
    CHECK(SendIndex("settingIndex") == 4);
}

// (b) active root 的 weak 生命周期：系统只弱持有 active，实例释放后应立刻回落成「无 root → 原值」。
//     不 retain controller 造假、不加 timer、不轮询，靠 ARC 作用域即可。
static void TestActiveRootWeakLifetime(void) {
    gActiveRoot = nil;
    gFriends = 5;
    CHECK(SendIndex("friendsIndex") == 5);          // 没有 active root → 原值透传

    @autoreleasepool {
        id tab = [[gTabCls alloc] init];
        SendModels(tab, @[MakeModel("home_page", 0), MakeModel("shenji_page", 0),
                          MakeModel("shared_page", 0)]);   // map [0,-1,1]
        gActiveRoot = tab;                           // 只弱持有，不额外 retain
        gFriends = 2;
        CHECK(SendIndex("friendsIndex") == 1);      // 按 tab 自己的图换算
    }
    CHECK(gActiveRoot == nil);                      // 释放后 weak 自动清空
    gFriends = 5;
    CHECK(SendIndex("friendsIndex") == 5);          // 原值不同才看得出是回落而不是残留
}

// 两个「有图、且映射不同」的 controller，用来判别读到的到底是谁的图：
//   A 的输入 3 项 [home, AI, shared]      → map [0,-1,1]
//   B 的输入 4 项 [AI, home, shared, vip]  → map [-1,0,1,2]
// 取老下标 1：A→-1、B→0、没有 root/没有 map→原值 1。三种结果互不相同，
// 任何一条判错都会得到别的值，不会「碰巧一样」而假通过。
static id MakeTabWithMapA(void) {
    id t = [[gTabCls alloc] init];
    SendModels(t, @[MakeModel("home_page", 0), MakeModel("shenji_page", 0),
                    MakeModel("shared_page", 0)]);
    return t;
}
static id MakeTabWithMapB(void) {
    id t = [[gTabCls alloc] init];
    SendModels(t, @[MakeModel("shenji_page", 0), MakeModel("home_page", 0),
                    MakeModel("shared_page", 0), MakeModel("vip_page", 0)]);
    return t;
}

// 每个 getter wrapper 都只调一次自己的原 IMP：四个各调一次，各计一次。
static void TestEachGetterCallsOriginalOnce(void) {
    id tab = MakeTabWithMapA();
    gActiveRoot = tab;
    gFriends = 2; gMagic = 0; gFindSource = 1; gSetting = 2;   // 都在 A 的 map 范围内
    gOrigFriendsCalls = gOrigMagicCalls = gOrigFindCalls = gOrigSettingCalls = 0;

    CHECK(SendIndex("friendsIndex") == 1);      // 2 → A map[2] = 1
    CHECK(SendIndex("magicTrickIndex") == 0);   // 0 → A map[0] = 0
    CHECK(SendIndex("findSourceIndex") == -1);  // 1 → A map[1] = -1
    CHECK(SendIndex("settingIndex") == 1);      // 2 → A map[2] = 1
    CHECK(gOrigFriendsCalls == 1 && gOrigMagicCalls == 1);
    CHECK(gOrigFindCalls == 1 && gOrigSettingCalls == 1);

    gActiveRoot = nil;
}

// 新 root 构造期：B 自己有图，但系统 active 还是旧 root（或根本没有）。
// customTabBar 内部必须按 B 的图解释，而不是 A 的、也不是原值。
static void TestNewRootConstructsWithOwnMap(void) {
    id tabA = MakeTabWithMapA();
    id tabB = MakeTabWithMapB();
    CHECK(MapOf(tabA) != nil && MapOf(tabB) != nil);

    gFriends = 1; gMagic = 2; gFindSource = 0; gSetting = 1;
    gCustomCalls = 0; gCustomThrows = NO; gNestedTarget = nil; gEnteredSignal = nil;

    // (a) 系统还没有 active root：B 构造中 → 按 B 图
    gActiveRoot = nil;
    CHECK(SendIndex("friendsIndex") == 1);      // 无 root → 原值
    SendCustomTabBar(tabB);
    CHECK(gCustomCalls == 1);                   // 原 customTabBar 只被调一次
    CHECK(gInsideFriends == 0);                 // B 的 map[1] = 0（不是原值 1）
    CHECK(BDTRContextController == NULL);       // 返回即清空
    CHECK(SendIndex("friendsIndex") == 1);      // 仍无 root → 原值

    // (b) active 仍是旧 root A：B 构造中 → 仍按 B 图，不是 A 图
    gActiveRoot = tabA;
    CHECK(SendIndex("friendsIndex") == -1);     // A 的 map[1] = -1
    SendCustomTabBar(tabB);
    CHECK(gCustomCalls == 2);
    CHECK(gInsideFriends == 0);                 // B 的图，不是 A 的 -1
    CHECK(BDTRContextController == NULL);
    CHECK(SendIndex("friendsIndex") == -1);     // 回到 A 的图

    // (c) B 自己没图时也不能回落去用 A 的图：原值 1，A 的图会给出 -1
    id tabC = [[gTabCls alloc] init];           // 没 SendModels → 无 map
    SendCustomTabBar(tabC);
    CHECK(gCustomCalls == 3);
    CHECK(gInsideFriends == 1);                 // 无 map → 原值，不是 A 的 -1
    CHECK(BDTRContextController == NULL);
    CHECK(SendIndex("friendsIndex") == -1);     // 仍是 A 的图

    gActiveRoot = nil;
}

// 嵌套：A 的 custom 里发一次 B 的 custom。判据是「嵌套返回后仍然读到 A」，
// 不是等整个 SendCustomTabBar 返回后再靠 active=A 间接说明。
static void TestCustomTabBarContext(void) {
    id tabA = MakeTabWithMapA();
    id tabB = MakeTabWithMapB();

    gActiveRoot = tabA;
    gFriends = 1; gMagic = 2; gFindSource = 0; gSetting = 1;
    gCustomThrows = NO; gEnteredSignal = nil;
    gCustomCalls = 0; gNestedCalls = 0; gOuterOriginalCalls = 0;
    gNestedTarget = nil; gCountedOuter = tabA;

    // 先单跑一次 A：ctx 就是 A
    SendCustomTabBar(tabA);
    CHECK(gCustomCalls == 1 && gOuterOriginalCalls == 1);
    CHECK(gInsideFriends == -1);                // A map[1]
    CHECK(gInsideMagic == 1);                  // A map[2]
    CHECK(gInsideFind == 0);                   // A map[0]
    CHECK(gInsideSetting == -1);               // A map[1]
    CHECK(BDTRContextController == NULL);

    // 嵌套：A → B，B 有不同的图
    gBeforeFriends = gAfterFriends = -99;
    gCtxAfterNested = NULL;
    NSInteger callsBefore = gCustomCalls;        // 1
    NSInteger outerBefore = gOuterOriginalCalls; // 1（上面那次）
    gNestedTarget = tabB;
    SendCustomTabBar(tabA);                      // 外层是 A

    CHECK(gNestedCalls == 1);                    // 只嵌一层
    CHECK(gCustomCalls == callsBefore + 2);      // 总共：外层 + 内层
    CHECK(gOuterOriginalCalls == outerBefore + 1);   // 外层 receiver 的原实现只跑了一次（内层是 B）
    CHECK(gBeforeFriends == -1);                 // 嵌套前是 A 的图
    CHECK(gAfterFriends == -1);                  // 嵌套返回后又是 A 的图（B 会给 0）
    CHECK(gCtxAfterNested == (__bridge void *)tabA);   // ctx 指针已还原成外层 receiver
    CHECK(BDTRContextController == NULL);        // 整体返回后清空

    // 抛异常：ctx 必须还原，异常不得被吞。active 仍是 A，用老下标 1 判别（A -1 / B 0）。
    gCustomThrows = YES;
    BOOL caught = NO;
    @try {
        SendCustomTabBar(tabB);
    } @catch (NSException *e) {
        caught = [[e name] isEqualToString:kTestExceptionName];
    }
    CHECK(caught);                              // 原异常原样透传
    CHECK(BDTRContextController == NULL);       // 异常路径也清空
    CHECK(SendIndex("friendsIndex") == -1);     // A 的图，不是 B 的 0，也不是原值 1
    gCustomThrows = NO;
    gCountedOuter = nil;

    gActiveRoot = nil;
}

// ctx 是线程局部的：后台线程压着 B 的 ctx 时，主线程读 getter 必须走 active=A 的图。
// 用 global queue + 信号量握手，保证「后台确实在 customTabBar 内部停着」，
// 并且主线程只在后台发信号之后才读共享结果（无竞态读，不用超时后继续跑）。
static void TestContextIsThreadLocal(void) {
    id tabA = MakeTabWithMapA();
    id tabB = MakeTabWithMapB();
    gActiveRoot = tabA;
    gFriends = 1; gMagic = 2; gFindSource = 0; gSetting = 1;
    gCustomThrows = NO; gNestedTarget = nil;

    dispatch_semaphore_t entered = dispatch_semaphore_create(0);
    dispatch_semaphore_t resume = dispatch_semaphore_create(0);
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    gEnteredSignal = entered;                    // fake 只暂停最外层那一层
    gResumeSignal = resume;
    gCtxOnBackground = NULL;

    __block NSInteger bgInside = -99, bgAfterCustom = -99;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        SendCustomTabBar(tabB);                 // 后台：ctx = B
        bgInside = gInsideFriends;               // 0（B 的 map[1]）
        bgAfterCustom = SendIndex("friendsIndex");   // ctx 已清 → active A → -1
        dispatch_semaphore_signal(finished);
    });

    dispatch_semaphore_wait(entered, DISPATCH_TIME_FOREVER);   // 后台此刻停在 customTabBar 内部
    CHECK(gCtxOnBackground == (__bridge void *)tabB);          // 后台压的确实是 B
    // 主线程此刻没有 ctx：必须走 active=A 的图（A -1），不能读到后台那个 B（0）
    CHECK(SendIndex("friendsIndex") == -1);

    dispatch_semaphore_signal(resume);
    dispatch_semaphore_wait(finished, DISPATCH_TIME_FOREVER);  // 后台已跑完并发布结果

    CHECK(bgInside == 0);                       // 后台 ctx 内按 B 的图
    CHECK(bgAfterCustom == -1);                 // 后台返回后也回到 A 的图
    CHECK(BDTRContextController == NULL);       // 主线程的 ctx 自始至终没被后台污染

    gEnteredSignal = nil; gResumeSignal = nil; gCtxOnBackground = NULL;
    gActiveRoot = nil;
}

int main(void) {
    @autoreleasepool {
        SetupFakes();
        TestNoActiveRootYet();          // 必须早于任何 setter 调用
        TestCanonicalFive();
        TestPositionsAndPredicates();
        TestPassthroughCases();
        TestGatesAndLifecycle();
        TestNewRootConstructsWithOwnMap();
        TestCustomTabBarContext();
        TestContextIsThreadLocal();
        TestEachGetterCallsOriginalOnce();
        TestActiveRootWeakLifetime();
        TestGroupAllOrNothing();

        if (gFailures == 0) {
            printf("tab_removal_test: PASS（机制测试，非真机路由验证）\n");
            return 0;
        }
        fprintf(stderr, "tab_removal_test: FAIL %d 项\n", gFailures);
        return 1;
    }
}