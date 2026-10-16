// BDNadBlock — 底部「库库AI」tab 去除：数据源层过滤 + 索引坐标映射
//
// 做什么（一句话）：在原生可见 tab 数组的**唯一写入口**过滤掉 AI 那一条，
// 并把「老下标 → 新下标」的坐标变换记在当前 controller 上，供四个原生索引 getter 换算。
//
// 五条真实 hook（都是各自类自己方法表里的方法，encoding 逐字节可核）：
//   -[BDPanTabBarController setTabBarItemModels:]  v24@0:8@16  argc 3
//   +[BDTabViewController friendsIndex]            q16@0:8     argc 2
//   +[BDTabViewController magicTrickIndex]         q16@0:8     argc 2
//   +[BDTabViewController findSourceIndex]         q16@0:8     argc 2
//   +[BDTabViewController settingIndex]            q16@0:8     argc 2
// 两个只读依赖（不 attach，只校验并存下 IMP 直调）：
//   -[BDTabItemModel itemType]   Q16@0:8  argc 2
//   -[BDTabItemModel itemTabName] @16@0:8 argc 2
//
// 安装规则：五条 + 两个依赖**全部**校验通过才一起 attach；任一不过就整组不写 IMP。
// 复用 FeatureRemoval.h 里的 BDFRSpec / BDFRResolve / BDFRCanAttach / BDFRAttach / BDFRSuppressed，
// 不改那个共享 installer。
//
// 语义（改这里等于改行为）：
//   - 过滤判据只认两样，且只对 BDTabItemModel 实例读：itemType == 1，或 itemTabName == @"shenji_page"。
//     数组里混入的其它对象（NSNumber/NSNull 等）原样保留，不给它们发消息。
//   - 不复刻 canUseMagicTrick / AB 分桶 / iPad 判断表，也不 hook 全局 canUseMagicTrick：
//     原 getter 自己算出的「老下标」就是唯一输入，映射由它决定。
//   - 保留原对象 identity 与原顺序；不碰 model、VC、tabItemModelsInfo、totalTabItemModels。
//   - 真移除且 kept 非空：给原 setter 传 [kept copy]，并把 indexMap 关联到当前 controller。
//     没命中 / 开关关 / 入参非 NSArray 或空数组：清关联、原对象原样透传。
//     会把 kept 滤空：整次不滤、清关联、记一行 skip —— 不制造 count 0 的除法崩溃或空页面。
//   - 原 setter 每次调用只被调用一次；只有真的移除了才打一次 hit 日志。
//   - 四个 index wrapper：先调各自原 IMP，再做坐标换算。
//     总关 / 诊断开 / 独立开关关 / 当前实例不存在 / 没有有效 map / 老下标越界 → 透传原值。
//     否则返回 map[老下标]。原值 -1（App 原生缺席语义）会原样保持为 -1。
//   - map 只是「同一次过滤的坐标变换」，不是第二套 AB 配置，也不是可见列表的副本：
//     不缓存 pageName、不持久化、不加定时器/通知/重试；每次 setter 同步写入或清除。
//
// 当前实例怎么来：原生 setter 自己的 self（static __weak，调用原 setter 前记）。
// 不用 AppDelegate / UIKit：这里正是可见数组的写入口，初始化早期 ad_curTabBarController 还 nil 的时候
// 也已经有实例了。不额外依赖 UIKit，本文件 Foundation only。
//
// 依赖但不在本文件定义：BDLog / BDEnabled / BDDumpOnly / BDRemoveAITab（开关与日志，同名静态函数），
// 以及 FeatureRemoval.h 提供的 BDFRSpec 等。包含次序：FeatureRemoval.h → TabRemoval.h。
//
// 注意：本文件里不要出现连续的 斜杠星号 或 星号斜杠（Logos 预处理）。

#ifndef BDNAD_TAB_REMOVAL_H
#define BDNAD_TAB_REMOVAL_H

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <string.h>

static char kBDTRIndexMapKey;          // 唯一 key：本组件在 controller 上的 indexMap 关联槽

static __weak id BDTRCurrentController; // 只跟随本机这条原生 setter 的最后一次调用实例

#pragma mark - 依赖（原样保存 IMP，typed 直调，不发消息）

typedef unsigned long long (*BDTRItemTypeIMP)(id, SEL);   // Q16@0:8
typedef id (*BDTRItemNameIMP)(id, SEL);                   // @16@0:8
typedef void (*BDTRSetModelsIMP)(id, SEL, id);           // v24@0:8@16
typedef NSInteger (*BDTRIndexIMP)(id, SEL);               // q16@0:8

static Class BDTRModelClass;          // 校验过的 BDTabItemModel 真实类
static SEL BDTRItemTypeSel;
static SEL BDTRItemTabNameSel;
static IMP BDTRItemTypeImp;           // 保存后 typed 直调
static IMP BDTRItemTabNameImp;

static IMP BDTROrigSetModels;         // 五个 spec 各自的原 IMP 槽
static IMP BDTROrigFriendsIndex;
static IMP BDTROrigMagicTrickIndex;
static IMP BDTROrigFindSourceIndex;
static IMP BDTROrigSettingIndex;

static dispatch_once_t BDTRHitRemovedAI;   // 只在真的移除过至少一条时打一次

#pragma mark - map 读写

static void BDTRClearIndexMap(id controller) {
    if (controller) objc_setAssociatedObject(controller, &kBDTRIndexMapKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// 只在「开关生效 + 实例在 + map 有效 + 老下标在范围内」时换算，否则原值透传。
static NSInteger BDTRTranslateIndex(NSInteger oldIndex) {
    if (!(BDEnabled() && !BDDumpOnly() && BDRemoveAITab())) return oldIndex;
    id tab = BDTRCurrentController;
    if (!tab) return oldIndex;
    id map = objc_getAssociatedObject(tab, &kBDTRIndexMapKey);
    if (![map isKindOfClass:[NSArray class]] || ((NSArray *)map).count == 0) return oldIndex;
    NSInteger n = (NSInteger)((NSArray *)map).count;
    if (oldIndex < 0 || oldIndex >= n) return oldIndex;      // 含 -1：原生缺席语义原样保持
    return ((NSArray<NSNumber *> *)map)[(NSUInteger)oldIndex].integerValue;
}

#pragma mark - 过滤实现

// true = 这条 model 是 AI（该移出）；只对真实 BDTabItemModel 实例问。
static BOOL BDTRIsAIModel(id model) {
    if (!BDTRModelClass || ![model isKindOfClass:BDTRModelClass]) return NO;
    unsigned long long type = ((BDTRItemTypeIMP)BDTRItemTypeImp)(model, BDTRItemTypeSel);
    if (type == 1) return YES;
    id name = ((BDTRItemNameIMP)BDTRItemTabNameImp)(model, BDTRItemTabNameSel);
    if ([name isKindOfClass:[NSString class]] &&
        [(NSString *)name isEqualToString:@"shenji_page"])
        return YES;
    return NO;
}

static void BDTRSetTabBarItemModels(id self, SEL _cmd, id models) {
    BDTRCurrentController = self;                    // 弱引用，记本次原生写入口的实例

    BOOL gate = BDEnabled() && !BDDumpOnly() && BDRemoveAITab();
    BOOL usable = gate && [models isKindOfClass:[NSArray class]] && ((NSArray *)models).count > 0;
    if (!usable) {
        BDTRClearIndexMap(self);
        ((BDTRSetModelsIMP)BDTROrigSetModels)(self, _cmd, models);   // 原对象原样透传
        return;
    }

    NSArray *original = (NSArray *)models;
    NSMutableArray *kept = [NSMutableArray arrayWithCapacity:original.count];
    NSMutableArray<NSNumber *> *indexMap = [NSMutableArray arrayWithCapacity:original.count];
    NSUInteger removed = 0;
    for (id m in original) {
        if (BDTRIsAIModel(m)) {
            [indexMap addObject:@(-1)];
            removed++;
            continue;
        }
        [indexMap addObject:@((NSInteger)kept.count)];   // 保留项记新下标
        [kept addObject:m];
    }

    if (removed == 0) {
        BDTRClearIndexMap(self);
        ((BDTRSetModelsIMP)BDTROrigSetModels)(self, _cmd, original);
        return;
    }
    if (kept.count == 0) {                              // 会滤空：整次不过滤
        BDTRClearIndexMap(self);
        BDLog(@"[BDNadTab] skip filter: 去掉 AI 后可见 tab 为空，保持原数组不变");
        ((BDTRSetModelsIMP)BDTROrigSetModels)(self, _cmd, original);
        return;
    }

    objc_setAssociatedObject(self, &kBDTRIndexMapKey, [indexMap copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    BDFRSuppressed(&BDTRHitRemovedAI, "tab-remove-ai", YES);   // 只在真移除时首次记一行
    ((BDTRSetModelsIMP)BDTROrigSetModels)(self, _cmd, [kept copy]);
}

#pragma mark - 四个 index wrapper（先调原 IMP，再换算）

static NSInteger BDTRFriendsIndex(id self, SEL _cmd) {
    return BDTRTranslateIndex(((BDTRIndexIMP)BDTROrigFriendsIndex)(self, _cmd));
}
static NSInteger BDTRMagicTrickIndex(id self, SEL _cmd) {
    return BDTRTranslateIndex(((BDTRIndexIMP)BDTROrigMagicTrickIndex)(self, _cmd));
}
static NSInteger BDTRFindSourceIndex(id self, SEL _cmd) {
    return BDTRTranslateIndex(((BDTRIndexIMP)BDTROrigFindSourceIndex)(self, _cmd));
}
static NSInteger BDTRSettingIndex(id self, SEL _cmd) {
    return BDTRTranslateIndex(((BDTRIndexIMP)BDTROrigSettingIndex)(self, _cmd));
}

#pragma mark - 安装器（不改 FeatureRemoval.h 里那个共享的）

static BDFRSpec BDTRSpecModels = {
    "BDPanTabBarController", "setTabBarItemModels:", NO, "v24@0:8@16", 3,
    (IMP)BDTRSetTabBarItemModels, &BDTROrigSetModels, "tab-remove-models", NO,
};
static BDFRSpec BDTRSpecFriends = {
    "BDTabViewController", "friendsIndex", YES, "q16@0:8", 2,
    (IMP)BDTRFriendsIndex, &BDTROrigFriendsIndex, "tab-index-friends", NO,
};
static BDFRSpec BDTRSpecMagic = {
    "BDTabViewController", "magicTrickIndex", YES, "q16@0:8", 2,
    (IMP)BDTRMagicTrickIndex, &BDTROrigMagicTrickIndex, "tab-index-magic", NO,
};
static BDFRSpec BDTRSpecFindSource = {
    "BDTabViewController", "findSourceIndex", YES, "q16@0:8", 2,
    (IMP)BDTRFindSourceIndex, &BDTROrigFindSourceIndex, "tab-index-findsource", NO,
};
static BDFRSpec BDTRSpecSetting = {
    "BDTabViewController", "settingIndex", YES, "q16@0:8", 2,
    (IMP)BDTRSettingIndex, &BDTROrigSettingIndex, "tab-index-setting", NO,
};
// 依赖 accessor：走同一张 BDFRSpec 解析器做校验，绝不 attach。
static BDFRSpec BDTRDepItemType = {
    "BDTabItemModel", "itemType", NO, "Q16@0:8", 2,
    NULL, NULL, "tab-dep-item-type", NO,
};
static BDFRSpec BDTRDepItemTabName = {
    "BDTabItemModel", "itemTabName", NO, "@16@0:8", 2,
    NULL, NULL, "tab-dep-item-tab-name", NO,
};

static BDFRSpec * const BDTRSpecs[] = {
    &BDTRSpecModels, &BDTRSpecFriends, &BDTRSpecMagic,
    &BDTRSpecFindSource, &BDTRSpecSetting,
};
static const unsigned BDTRSpecCount =
    (unsigned)(sizeof(BDTRSpecs) / sizeof(BDTRSpecs[0]));
static BDFRSpec * const BDTRDeps[] = { &BDTRDepItemType, &BDTRDepItemTabName };
static const unsigned BDTRDepCount =
    (unsigned)(sizeof(BDTRDeps) / sizeof(BDTRDeps[0]));

// 全组一起：五条 spec + 两个依赖全过才写任何 IMP。参数化是为了测试能用假描述
// 驱动「任一不过就整组不写」这条路径（不改已安装 spec 的 runtime encoding，也不重置它的 installed）。
// specs/deps 是「指向 BDFRSpec 的指针数组」，元素本身就是指针 —— 不要当连续结构体数组传。
static BOOL BDTRInstallGroup(BDFRSpec *const *specs, unsigned specCount,
                             BDFRSpec *const *deps, unsigned depCount) {
    Method methods[8];
    Method depMethods[4];
    unsigned i = 0, j = 0;
    if (specCount == 0 || specCount > 8 || depCount > 4) return NO;

    for (i = 0; i < specCount; i++) {
        methods[i] = BDFRResolve(specs[i]);
        if (!methods[i] || !BDFRCanAttach(specs[i], methods[i])) {
            BDLog(@"[BDNadTab] skip group: %s 未通过校验，整组不安装", specs[i]->name);
            return NO;
        }
    }
    for (j = 0; j < depCount; j++) {
        depMethods[j] = BDFRResolve(deps[j]);
        if (!depMethods[j]) {
            BDLog(@"[BDNadTab] skip group: 依赖 %s 校验不过，整组不安装", deps[j]->name);
            return NO;
        }
    }
    // 校验全过之后才采集依赖并写 IMP。这里按描述里的 selector 名字判断是哪个依赖，
    // 实际取值用的是安装期保存的真实 SEL/IMP。
    for (j = 0; j < depCount; j++) {
        if (strcmp(deps[j]->sel, BDTRDepItemType.sel) == 0) {
            BDTRModelClass = objc_getClass(deps[j]->cls);
            BDTRItemTypeSel = sel_registerName(deps[j]->sel);
            BDTRItemTypeImp = method_getImplementation(depMethods[j]);
        } else if (strcmp(deps[j]->sel, BDTRDepItemTabName.sel) == 0) {
            BDTRModelClass = objc_getClass(deps[j]->cls);
            BDTRItemTabNameSel = sel_registerName(deps[j]->sel);
            BDTRItemTabNameImp = method_getImplementation(depMethods[j]);
        }
    }
    for (i = 0; i < specCount; i++) BDFRAttach(specs[i], methods[i]);
    return YES;
}

// 对外唯一入口：给 Tweak.xm 构造器调。幂等（重复调用不动 IMP）。
static inline void BDTRInstallAll(void) {
    BDTRInstallGroup(BDTRSpecs, BDTRSpecCount, BDTRDeps, BDTRDepCount);
}

#endif