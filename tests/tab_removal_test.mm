// tests/tab_removal_test.mm — TabRemoval.h 的 macOS host 机制测试
//
// 用动态 fake 类 + 真实同名 selector 跑真安装器；开关用内存里的假函数，
// 不碰 NSUserDefaults，不写任何文件，不连网。
//
// 测的是**机制**：AI 条被按 identity 过滤并生成坐标 map；四个 index getter 先调原 IMP 再换算；
// 没命中/开关关/滤空/非法入参时原样透传；整组校验不过就一个 IMP 都不写。
// **不测 App 真机路由**：页面跳转、点击、红点等仍需真机。
//
// 构建运行（macOS，无需 IPA，无需 Theos）：
//   clang++ -std=c++17 -fobjc-arc -fblocks -Wall -Wextra -Werror \
//     -framework Foundation -o /tmp/tab_removal_test tests/tab_removal_test.mm
//   /tmp/tab_removal_test

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
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

// fake model 的属性用关联对象存（不改 ivar 布局，也不改已注册方法的 encoding）
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

// 四个原索引 getter：返回值可配
static NSInteger gFriends = 3, gMagic = 2, gFindSource = -1, gSetting = 4;
static NSInteger TIndex(id self, SEL cmd) {
    (void)self;
    const char *n = sel_getName(cmd);
    if (strcmp(n, "friendsIndex") == 0) return gFriends;
    if (strcmp(n, "magicTrickIndex") == 0) return gMagic;
    if (strcmp(n, "findSourceIndex") == 0) return gFindSource;
    if (strcmp(n, "settingIndex") == 0) return gSetting;
    return -99;   // 未列出的 selector 不该被装
}

static void SendModels(id tab, id models) {
    SEL sel = @selector(setTabBarItemModels:);
    void (*imp)(id, SEL, id) =
        (void (*)(id, SEL, id))class_getMethodImplementation(gTabCls, sel);
    imp(tab, sel, models);
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

    gIndexCls = MakeClass("BDTabViewController", Nil);
    const char *names[] = {"friendsIndex", "magicTrickIndex", "findSourceIndex", "settingIndex"};
    for (unsigned i = 0; i < 4; i++)
        CHECK(class_addMethod(object_getClass(gIndexCls), sel_registerName(names[i]),
                              (IMP)TIndex, "q16@0:8"));

    BDFRInstallAll();     // FeatureRemoval 那套：这些类不存在，应整组 skip，不崩
    BDTRInstallAll();     // 本组件真实安装
    CHECK(gSetCalls == 0);                 // 安装阶段不该调用任何被 hook 的方法
    CHECK(BDTRItemTypeImp == (IMP)TItemType);      // 依赖 IMP 已保存
    CHECK(BDTRItemTabNameImp == (IMP)TItemName);
    CHECK(BDTRModelClass == gModelCls);
    CHECK(BDTROrigSetModels == (IMP)TSetModels);   // 先存原 IMP
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
    CHECK(SendIndex("friendsIndex") == 2);       // 3 → 2
    CHECK(SendIndex("magicTrickIndex") == -1);   // 2 → -1（App 原生缺席语义）
    CHECK(SendIndex("findSourceIndex") == -1);   // -1 透传
    CHECK(SendIndex("settingIndex") == 3);       // 4 → 3
}

#pragma mark - 2 AI 位置与类型判据

static void TestPositionsAndPredicates(void) {
    id tab = [[gTabCls alloc] init];

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

    // 两条 AI（不同判据各命中一条：type==1 与 name==shenji_page）
    SendModels(tab, @[MakeModel("genflow_alt", 1), home, MakeModel("shenji_page", 0), shared]);
    out = (NSArray *)gLastModels;
    CHECK(out.count == 2 && out[0] == home && out[1] == shared);
    CHECK([MapOf(tab)[0] intValue] == -1 && [MapOf(tab)[2] intValue] == -1);

    // 非 AI 的 type 0 页照留（名字不含 shenji）
    id vip = MakeModel("vip_page", 0), pmall = MakeModel("pmall_page", 0), yike = MakeModel("yike_page", 0);
    SendModels(tab, @[vip, pmall, yike]);
    out = (NSArray *)gLastModels;
    CHECK(out.count == 3 && out[0] == vip && out[1] == pmall && out[2] == yike);
    CHECK(MapOf(tab) == nil);                    // 没移除 → map 清除

    // type 1 但名字不同，仍然移除
    id odd = MakeModel("something_else", 1);
    SendModels(tab, @[home, odd, shared]);
    out = (NSArray *)gLastModels;
    CHECK(out.count == 2 && out[0] == home && out[1] == shared);
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

    // 两个 controller：只用最近一次进过原生 setter 的那个实例的 map
    // A 的输入是 4 项 [home, AI, shared, vip] → map [0,-1,1,2]，首项老下标 0 仍映射 0
    id tabA = [[gTabCls alloc] init];
    id tabB = [[gTabCls alloc] init];
    SendModels(tabA, @[home, MakeModel("shenji_page", 1), shared, MakeModel("vip_page", 0)]);
    CHECK(MapOf(tabA) != nil);
    gMagic = 0;
    CHECK(SendIndex("magicTrickIndex") == 0);     // A: map[0] = 0（home 还在原位）

    // B 的输入是 3 项 [AI, home, shared] → map [-1,0,1]：
    //   同一个合法老下标 0 现在映射成 -1 —— 若代码还在读 A 的旧 map，这里会得到 0
    SendModels(tabB, @[MakeModel("shenji_page", 1), home, shared]);
    CHECK(MapOf(tabB) != nil);
    gMagic = 0;
    CHECK(SendIndex("magicTrickIndex") == -1);    // 用的是 B 的 map，不是 A 的
    gFriends = 3;
    CHECK(SendIndex("friendsIndex") == 3);        // B 的 map 只有 3 项 → 老 3 越界 → 透传 3

    // 重复安装：不动 IMP、不递归
    IMP before = class_getMethodImplementation(gTabCls, @selector(setTabBarItemModels:));
    BDTRInstallAll();
    CHECK(class_getMethodImplementation(gTabCls, @selector(setTabBarItemModels:)) == before);
    CHECK(BDTROrigSetModels == (IMP)TSetModels);
    SendModels(tabA, @[home, MakeModel("shenji_page", 1), shared, MakeModel("vip_page", 0)]);
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

    // (c) 依赖 encoding 不符（注册成小写 q，期望大写 Q）
    Class badDep = MakeClass("BDTRPhantomBadDep", Nil);
    CHECK(class_addMethod(badDep, sel_registerName("itemType"), (IMP)PhantomULong, "q16@0:8"));
    BDFRSpec badDepSpec = { "BDTRPhantomBadDep", "itemType", NO, "Q16@0:8", 2,
                            NULL, NULL, "phantom-dep-bad-enc", NO };
    BDFRSpec *badDepArr[] = { &badDepSpec };
    BDFRSpec okSpec = { "BDTRPhantomBadTarget", "phantomIndex", NO, "v16@0:8", 2,
                        (IMP)PhantomWrap, &gPhantomOrig, "phantom-ok", NO };
    BDFRSpec *okArr[] = { &okSpec };
    CHECK(BDTRInstallGroup(okArr, 1, badDepArr, 1) == NO);
    CHECK(class_getMethodImplementation(bad, sel) == before);   // 依赖不过 → 目标也不装
    CHECK(gPhantomOrig == NULL);

    // (d) 依赖类不存在
    BDFRSpec missingDep = { "BDTRPhantomNoDepClass", "itemType", NO, "Q16@0:8", 2,
                            NULL, NULL, "phantom-dep-missing", NO };
    BDFRSpec *missingDepArr[] = { &missingDep };
    CHECK(BDTRInstallGroup(okArr, 1, missingDepArr, 1) == NO);
    CHECK(class_getMethodImplementation(bad, sel) == before);
    CHECK(gPhantomOrig == NULL);
}

// 弱引用生命周期：
// (a) 还没有任何 controller 进过原生 setter → 没有当前实例 → 四 getter 原值透传
static void TestNoCurrentInstanceYet(void) {
    CHECK(BDTRCurrentController == nil);
    gFriends = 3; gMagic = 2; gFindSource = 7; gSetting = 4;
    CHECK(SendIndex("friendsIndex") == 3);
    CHECK(SendIndex("magicTrickIndex") == 2);
    CHECK(SendIndex("findSourceIndex") == 7);
    CHECK(SendIndex("settingIndex") == 4);
}

// (b) 局部 @autoreleasepool 里建 controller、过滤、出作用域释放 → weak 变 nil → 原值透传。
//     不 retain controller 造假、不加 timer、不轮询，靠 ARC 作用域即可。
static void TestControllerReleasedPutsWeakNil(void) {
    @autoreleasepool {
        id tab = [[gTabCls alloc] init];
        SendModels(tab, @[MakeModel("home_page", 0), MakeModel("shenji_page", 1),
                          MakeModel("shared_page", 0)]);
        NSArray *out = (NSArray *)gLastModels;
        CHECK(out.count == 2);
        CHECK(BDTRCurrentController == tab);
        gFriends = 2;
        // 作用域内：map=[0,-1,1]，老下标 2 → 新下标 1（shared 前面的 AI 被移走了）
        CHECK(SendIndex("friendsIndex") == 1);
    }
    CHECK(BDTRCurrentController == nil);            // 释放后 weak 自动清空
    gFriends = 2;
    CHECK(SendIndex("friendsIndex") == 2);          // 没有实例 → 原值透传（恰好相同值）
    gFriends = 5;
    CHECK(SendIndex("friendsIndex") == 5);          // 原值不同才看得出是透传
}

int main(void) {
    @autoreleasepool {
        SetupFakes();
        TestNoCurrentInstanceYet();     // 必须早于任何 setter 调用
        TestCanonicalFive();
        TestPositionsAndPredicates();
        TestPassthroughCases();
        TestGatesAndLifecycle();
        TestControllerReleasedPutsWeakNil();
        TestGroupAllOrNothing();

        if (gFailures == 0) {
            printf("tab_removal_test: PASS（机制测试，非真机路由验证）\n");
            return 0;
        }
        fprintf(stderr, "tab_removal_test: FAIL %d 项\n", gFailures);
        return 1;
    }
}