// BDNadBlock — 精准 feature hook：首页「推荐/创意」整块、我的页「游戏中心」区块、
// 首页金刚区去掉「求职 / 小说」
//
// 只覆盖四个确定的方法（三个类方法落在 metaclass 槽 + 一个实例方法）：
//   +[BHSettings isMSHSwitchTypeHomeRecommend]                      -> NO
//   -[BDPanNewMSHContentViewController tableView:numberOfRowsInSection:] -> 0
//   +[BDPanPersonalConfig gameCenterSwitch]                         -> NO
//   +[BDPanFeedHomeConfig cacheKingKongsConfigArray]                -> 去掉 kingKongId 13/6 的元素
//
// 约束（与本文件之外的调用方议定，改这里等于改行为）：
//   - 方法必须在该类**自己**的方法表里；继承来的 Method 属于父类，一律不动。
//   - 安装前核对完整 type encoding 与参数个数（含 self/_cmd）；不符就 skip，什么都不装。
//   - 金刚数组那条额外先**只读校验**依赖 -[BDPanFHKingKongsModel kingKongId]（类 + 自有方法
//     + q16@0:8 + argc 2）；依赖不过就整条跳过，数组 hook 也不装。依赖方法永远不 attach。
//   - 先保存原 IMP 再 method_setImplementation，绝不交换 IMP；透传时用匹配的 typed 指针与原 selector。
//   - 每次调用重新读 BDEnabled/BDDumpOnly/BDRemove...；只在首次真正抑制时打一行日志。
//   - 没有卸载逻辑（不需要）。
//
// 本文件被 Tweak.xm 与 tests/feature_removal_test.mm include，依赖同名的静态函数：
//   BDLog / BDEnabled / BDDumpOnly / BDRemoveRecommend / BDRemoveGameCenter / BDRemoveJobNovel
//
// 注意：本文件（以及任何被 Tweak.xm include 的文件）里不要出现连续的 斜杠星号 或 星号斜杠。

#ifndef BDNAD_FEATURE_REMOVAL_H
#define BDNAD_FEATURE_REMOVAL_H

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <string.h>

#pragma mark - 三个 typed 替换实现

// B 编码的返回在 macOS Intel 上并不等价于 BOOL（BOOL 可能是 signed char），
// 所以这两个 hook 与它们的函数指针都用内建 bool，与手写 encoding 对齐。
typedef bool (*BDFRBoolIMP)(id, SEL);
typedef NSInteger (*BDFRRowCountIMP)(id, SEL, id, NSInteger);

// 金刚数组：@16@0:8 返回 id；-kingKongId 是 q16@0:8，arm64 上 q 与 NSInteger 同宽同寄存器，
// 所以用 NSInteger 读（与上面 q32@0:8@16q24 同一处理）。
// 调用的是安装时从校验过的 Method 取出的 IMP，不经 objc_msgSend、不写 ivar 偏移。
typedef id (*BDFRKongArrayIMP)(id, SEL);
typedef NSInteger (*BDFRKongIDIMP)(id, SEL);

static IMP BDFROrigHomeRecommend;   // +[BHSettings isMSHSwitchTypeHomeRecommend]
static IMP BDFROrigHomeRowCount;    // -[BDPanNewMSHContentViewController tableView:numberOfRowsInSection:]
static IMP BDFROrigGameCenter;      // +[BDPanPersonalConfig gameCenterSwitch]
static IMP BDFROrigKingKongsCache;  // +[BDPanFeedHomeConfig cacheKingKongsConfigArray]

// 依赖的 accessor：安装时从校验过的 Method 取出的 IMP/类/selector，运行期直接用，
// 不再查字符串、不碰 ivar 偏移，也不往 NSObject 上加任何全局方法。
static IMP BDFRKingKongIDImp;
static Class BDFRKingKongModelCls;
static SEL BDFRKingKongIDSel;

static dispatch_once_t BDFRHitHomeRecommend;
static dispatch_once_t BDFRHitHomeRowCount;
static dispatch_once_t BDFRHitGameCenter;
static dispatch_once_t BDFRHitKingKongsCache;

// 真的抑制了才在首次打一行 hit 日志；每个 hook 一个 token，不会每帧刷。
static BOOL BDFRSuppressed(dispatch_once_t *once, const char *name, BOOL enabled) {
    if (!enabled) return NO;
    dispatch_once(once, ^{ BDLog(@"[BDNadFeature] hit %s（首次真正抑制）", name); });
    return YES;
}

static bool BDFRHomeRecommend(id self, SEL _cmd) {
    if (BDFRSuppressed(&BDFRHitHomeRecommend, "home-recommend",
                       BDEnabled() && !BDDumpOnly() && BDRemoveRecommend()))
        return false;
    return ((BDFRBoolIMP)BDFROrigHomeRecommend)(self, _cmd);
}

static NSInteger BDFRHomeRowCount(id self, SEL _cmd, id tableView, NSInteger section) {
    if (BDFRSuppressed(&BDFRHitHomeRowCount, "home-recommend-rows",
                       BDEnabled() && !BDDumpOnly() && BDRemoveRecommend()))
        return 0;
    return ((BDFRRowCountIMP)BDFROrigHomeRowCount)(self, _cmd, tableView, section);
}

static bool BDFRGameCenter(id self, SEL _cmd) {
    if (BDFRSuppressed(&BDFRHitGameCenter, "game-center",
                       BDEnabled() && !BDDumpOnly() && BDRemoveGameCenter()))
        return false;
    return ((BDFRBoolIMP)BDFROrigGameCenter)(self, _cmd);
}

// H4：首页金刚区去掉「求职 / 小说」。
// 该 getter 返回「服务端项 + 本地兜底项」合并后的最终数组（无网络时 defaultCacheKingKongsConfigArray
// 里同样含 id 6/13），首页新老 view、reload、金刚编辑页都读它一个来源，所以在返回前过滤即全覆盖。
// 判据只认 kingKongId 数值：13=求职 job_hunt，6=小说 novel。不按 name/type 文本判断。
static id BDFRKingKongsCache(id self, SEL _cmd) {
    NSArray *arr = ((BDFRKongArrayIMP)BDFROrigKingKongsCache)(self, _cmd);  // 原实现只调一次
    if (!(BDEnabled() && !BDDumpOnly() && BDRemoveJobNovel())) return arr;
    if (![arr isKindOfClass:[NSArray class]] || arr.count == 0) return arr;

    Class modelCls = BDFRKingKongModelCls;   // 安装时校验过的那一个类
    IMP idImp = BDFRKingKongIDImp;
    SEL idSel = BDFRKingKongIDSel;
    NSMutableArray *kept = [NSMutableArray arrayWithCapacity:arr.count];
    for (id m in arr) {
        // 只对真实 model 实例读 id；数组里混入别的对象（NSString/NSNull 等）时原样保留，不发消息。
        if (modelCls && idImp && idSel && [m isKindOfClass:modelCls]) {
            NSInteger kk = ((BDFRKongIDIMP)idImp)(m, idSel);
            if (kk == 13 || kk == 6) continue;
        }
        [kept addObject:m];
    }
    if (kept.count == arr.count) return arr;              // 没有真移除：返回同一个原数组，且不 hit
    BDFRSuppressed(&BDFRHitKingKongsCache, "home-kingkong-job-novel", YES);
    return [kept copy];                                   // immutable copy；全被过滤时是空数组，不是 nil
}

#pragma mark - 安装器

// 一条 hook 的静态描述。hook 是替换实现，orig 是保存原实现的槽（先存后换）。
typedef struct {
    const char *cls;            // 目标类名
    const char *sel;            // selector 名
    BOOL isClassMethod;         // YES = 类方法（装在 metaclass 槽）
    const char *enc;            // 期望的完整 type encoding，逐字节比对
    unsigned argc;              // 期望参数个数，含 self 与 _cmd（H1/H3 = 2，H2 = 4），用 runtime 的 method_getNumberOfArguments 核对
    IMP hook;                   // 替换实现
    IMP *orig;                  // 保存原实现
    const char *name;           // 日志名
    BOOL installed;             // 幂等标记
} BDFRSpec;

// 找目标类「自己」方法表里的 Method，不沿继承链；类方法看 metaclass。
static Method BDFRResolve(BDFRSpec *s) {
    Class host = objc_getClass(s->cls);
    if (!host) {
        BDLog(@"[BDNadFeature] skip %s: 类 %s 不存在", s->name, s->cls);
        return NULL;
    }
    Class target = s->isClassMethod ? object_getClass(host) : host;
    SEL want = sel_registerName(s->sel);
    Method found = NULL;
    unsigned n = 0;
    Method *list = class_copyMethodList(target, &n);
    for (unsigned i = 0; list && i < n; i++) {
        if (method_getName(list[i]) == want) { found = list[i]; break; }
    }
    if (list) free(list);
    if (!found) {
        BDLog(@"[BDNadFeature] skip %s: %s[%s %s] 不在本类自己的方法表里（缺失或只有继承实现），不动父类",
              s->name, s->isClassMethod ? "+" : "-", s->cls, s->sel);
        return NULL;
    }
    const char *enc = method_getTypeEncoding(found);
    if (!enc || strcmp(enc, s->enc) != 0) {
        BDLog(@"[BDNadFeature] skip %s: type encoding 不符，期望 %s 实际 %s",
              s->name, s->enc, enc ? enc : "(null)");
        return NULL;
    }
    // 参数个数用 runtime 自己算（含 self 与 _cmd），不自写 encoding parser。
    unsigned argc = method_getNumberOfArguments(found);
    if (argc != s->argc) {
        BDLog(@"[BDNadFeature] skip %s: 参数个数 %u != %u", s->name, argc, s->argc);
        return NULL;
    }
    return found;
}

// 能不能装：只读，不改任何东西。没有 Method，或「槽里已经就是本 hook」都不算可装。
static BOOL BDFRCanAttach(BDFRSpec *s, Method m) {
    if (!m) return NO;
    if (s->installed) return YES;                     // 已装过：幂等，重复调用不动 IMP
    if (method_getImplementation(m) == s->hook) {
        // 绝不把自己的 replacement 存成 original
        BDLog(@"[BDNadFeature] skip %s: 现 IMP 已是本 hook，未覆盖 original", s->name);
        return NO;
    }
    return YES;
}

// 先校验后安装（不是原子事务）：调用前必须已经通过 BDFRCanAttach。
static BOOL BDFRAttach(BDFRSpec *s, Method m) {
    if (s->installed) {
        BDLog(@"[BDNadFeature] already installed %s，跳过重复安装", s->name);
        return YES;
    }
    *s->orig = method_getImplementation(m);   // 先存原实现
    method_setImplementation(m, s->hook);     // 再替换，不交换 IMP
    s->installed = YES;
    BDLog(@"[BDNadFeature] installed %s: %s[%s %s] enc=%s",
          s->name, s->isClassMethod ? "+" : "-", s->cls, s->sel, s->enc);
    return YES;
}

static BOOL BDFRInstallSpec(BDFRSpec *s) {
    Method m = BDFRResolve(s);
    if (!m || !BDFRCanAttach(s, m)) return NO;
    return BDFRAttach(s, m);
}

// 两条一起：两个都通过校验才装；任一个不通过（含「槽已是本 hook」）就两个都不装。
static BOOL BDFRInstallPair(BDFRSpec *a, BDFRSpec *b) {
    Method ma = BDFRResolve(a);
    Method mb = BDFRResolve(b);
    if (!ma || !mb || !BDFRCanAttach(a, ma) || !BDFRCanAttach(b, mb)) {
        BDLog(@"[BDNadFeature] skip pair: %s / %s 未同时通过校验，两个都不安装",
              a->name, b->name);
        return NO;
    }
    BDFRAttach(a, ma);
    BDFRAttach(b, mb);
    return YES;
}

// 四个固定 slot：H1+H2 是首页推荐/创意整块（同一对校验），H3 是「我的」游戏中心，
// H4 是首页金刚区数组（H1~H3 独立校验）。H4 的依赖 accessor 是第 5 条，只读、永不 attach。
static BDFRSpec BDFRSpecHomeRecommend = {
    "BHSettings", "isMSHSwitchTypeHomeRecommend", YES, "B16@0:8", 2,
    (IMP)BDFRHomeRecommend, &BDFROrigHomeRecommend, "home-recommend", NO,
};
static BDFRSpec BDFRSpecHomeRowCount = {
    "BDPanNewMSHContentViewController", "tableView:numberOfRowsInSection:", NO, "q32@0:8@16q24", 4,
    (IMP)BDFRHomeRowCount, &BDFROrigHomeRowCount, "home-recommend-rows", NO,
};
static BDFRSpec BDFRSpecGameCenter = {
    "BDPanPersonalConfig", "gameCenterSwitch", YES, "B16@0:8", 2,
    (IMP)BDFRGameCenter, &BDFROrigGameCenter, "game-center", NO,
};
static BDFRSpec BDFRSpecKingKongsCache = {
    "BDPanFeedHomeConfig", "cacheKingKongsConfigArray", YES, "@16@0:8", 2,
    (IMP)BDFRKingKongsCache, &BDFROrigKingKongsCache, "home-kingkong-job-novel", NO,
};
// 依赖 accessor：hook / 依赖共用同一张解析器，只走 BDFRResolve 校验，绝不 attach。
static BDFRSpec BDFRSpecKingKongID = {
    "BDPanFHKingKongsModel", "kingKongId", NO, "q16@0:8", 2,
    NULL, NULL, "home-kingkong-id", NO,
};

// H4 的安装步骤，参数化是为了让测试能用假依赖描述驱动「校验不过就跳过」这条路径。
// 先校验依赖（类存在 + 自有方法 + 完整 q16@0:8 + argc 2），通过才装数组 hook。
// 依赖不过就整条跳过 —— 不 attach 依赖方法，也不改数组方法，两个 IMP 槽都不写。
static BOOL BDFRInstallKingKongsWith(BDFRSpec *dep, BDFRSpec *target) {
    // 先把依赖与目标**都**校验过（依赖 + 目标签名 + CanAttach），全过了才写依赖全局、才 attach。
    // 这样目标校验失败时不会留下半套依赖状态。
    Method md = BDFRResolve(dep);
    Method mt = BDFRResolve(target);
    if (!md || !mt || !BDFRCanAttach(target, mt)) {
        BDLog(@"[BDNadFeature] skip %s: 依赖 -[%s %s] 或目标自身校验不过，什么都不装",
              target->name, dep->cls, dep->sel);
        return NO;
    }
    BDFRKingKongModelCls = objc_getClass(dep->cls);
    BDFRKingKongIDSel = sel_registerName(dep->sel);
    BDFRKingKongIDImp = method_getImplementation(md);
    return BDFRAttach(target, mt);      // 仍是先存原 IMP 再 method_setImplementation，不交换
}

static BOOL BDFRInstallKingKongs(void) {
    return BDFRInstallKingKongsWith(&BDFRSpecKingKongID, &BDFRSpecKingKongsCache);
}

// 安装即完成；是否抑制在每次调用时按开关决定。
static void BDFRInstallAll(void) {
    BDFRInstallPair(&BDFRSpecHomeRecommend, &BDFRSpecHomeRowCount);
    BDFRInstallSpec(&BDFRSpecGameCenter);
    BDFRInstallKingKongs();
}

#endif
