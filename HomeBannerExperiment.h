// BDNadBlock — 【实验】首页顶部横幅容器隐藏（BDPanNewMSHTopOperationView 自己的 _bannerView）
//
// 前置契约（与 PersonalViewRemoval.h 同一约定）：
//   1) 调用方**先** #import <UIKit/UIKit.h>（本 header 用真实的 UIView 类型与 isHidden/superview/
//      isDescendantOfView:，但**不**自己 import UIKit，避免新增依赖）；再 include FeatureRemoval.h
//   2) 调用方提供 BDEnabled / BDDumpOnly / BDExperimentHideHomeBanner（后者读**唯一一个新 Prefs 键**，
//      本文件不定义、不抄默认值）。本版默认 NO，用户在菜单手动开并冷启动生效，关掉后冷启动回退。
//   3) 本 header 只用 Foundation + objc/runtime + string.h，不新增任何第三方或 UIKit 依赖。
//
// 语义（实验，效果未知；与调用方议定，改这里等于改行为）：
//   - 目标：`-[BDPanNewMSHTopOperationView setupView]`（`v16@0:8` argc2）与
//     `-[BDPanNewMSHTopOperationView bannerView]`（`@16@0:8` argc2），都是该类**自有**方法，
//     两条都是 **post-hook**：原实现照旧调用一次（参数/返回/副作用全保留），之后才做本实验动作。
//   - 候选 = 该类**自有** object ivar `_bannerView`（`object_getIvar` 只读，不调懒 getter、不创建）。
//     必须同时满足：是 UIView、≠ host、`view.superview == host`（直接子视图）。
//   - 运行期保护（**只查这 9 个已知正常控件字段**，逐个 `object_getIvar` 只读、**绝不调用它们的懒
//     getter**）：`_searchView` `_transferButton` `_plusButton` `_signButton` `_transferNumLabel`
//     `_transStartView` `_transLoadingView` `_transDoneView` `_searchBgView`。
//     任一 == 候选、或是候选的后代 ⇒ 放弃（fail-closed，保留容器）；
//     任一非 nil 但**不是 UIView** ⇒ 同样放弃（fail-closed，不猜它是安全的）。
//   - **初始化期间不隐藏**：setup 执行期间（含它内部对 bannerView 的调用）不做隐藏；只有最外层 setup
//     完成后才允许动作。为此在**该 host 实例**上用关联对象记一个深度状态（nil=从未经过本实验 setup，
//     positive=setup 正在执行，0=已完成）；嵌套/重复 setup 用深度而非布尔，不会提前 ready。
//     该状态**只在“总开 && 非诊断 && 实验开 && 主线程”时读写**；关闭或后台调用只透传、不写状态。
//   - 只有「原 `isHidden` 为 NO 且本次确实置为 YES」才首次记一行 hit；已隐藏则不动、不重复记。
//   - 总关 / 诊断 / 实验关 / 非主线程：**纯透传**，不读候选、不读/写关联状态、不创建任何视图。
//   - 不改 frame / 约束 / 高度 / 导航，不 nil 构造器、不清数据、不写 App 偏好、不全局 hook、
//     不按尺寸或文字匹配；允许留白，也可能命中不了用户看到的对象（本版不声称已命中）。
//   - 安装：两条 spec 必须**同一个类**、都 resolve 通过、都 CanAttach，且 host 的**自己 ivar 表**里
//     10 个字段都存在且都是 object 类型；任一不满足 ⇒ 整组 skip（fail-closed），不写任何 IMP 槽、
//     不改已装的缓存，只记一行原因（无地址/无文件/无账号/无屏幕文字）。
//   - 先存原 IMP 再 method_setImplementation，绝不交换；重复调用幂等；不动父类槽。
//
// 注意：本文件（以及任何被 Tweak.xm include 的文件）里不要出现连续的 斜杠星号 或 星号斜杠，
// 哪怕在 // 行注释里也不行 —— Theos 的 Logos 预处理器会把它当块注释。

#ifndef BDNAD_HOME_BANNER_EXPERIMENT_H
#define BDNAD_HOME_BANNER_EXPERIMENT_H

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <string.h>

#pragma mark - 本地 typedef 与常量

typedef void (*BDHBVoidIMP)(id, SEL);
typedef id (*BDHBObjectIMP)(id, SEL);

static const char *const BDHBCandidateIvarName = "_bannerView";
static const char *const BDHBProtectedIvarNames[] = {
    "_searchView", "_transferButton", "_plusButton", "_signButton", "_transferNumLabel",
    "_transStartView", "_transLoadingView", "_transDoneView", "_searchBgView",
};
#define BDHB_PROTECTED_COUNT (sizeof(BDHBProtectedIvarNames) / sizeof(BDHBProtectedIvarNames[0]))

static IMP BDHBOrigSetupView;          // -[BDPanNewMSHTopOperationView setupView]
static IMP BDHBOrigBannerGetter;       // -[BDPanNewMSHTopOperationView bannerView]

static dispatch_once_t BDHBHitHide;
static dispatch_once_t BDHBSkipMeta;            // 安装期：类/字段元数据不齐
static dispatch_once_t BDHBSkipCandidate;       // 运行期：候选为空/非 UIView/等于 host
static dispatch_once_t BDHBSkipNotChild;        // 运行期：候选不是 host 的直接子视图
static dispatch_once_t BDHBSkipProtected;       // 运行期：命中了正常控件
static dispatch_once_t BDHBSkipProtectedType;   // 运行期：正常控件字段值不是 UIView（fail-closed）

static Ivar BDHBCandidateIvar;                  // 全部由校验过的元数据取得，不硬编码偏移
static Ivar BDHBProtectedIvars[BDHB_PROTECTED_COUNT];

static char BDHBDepthKey;                       // 关联到每个 host 实例的 setup 深度状态

#pragma mark - 只读工具

static void BDHBSkipOnce(dispatch_once_t *once, const char *reason) {
    dispatch_once(once, ^{ BDLog(@"[BDNadFeature] skip home-banner-experiment: %s（保留容器）", reason); });
}

static BOOL BDHBIsObjectIvar(Ivar iv) {
    const char *enc = iv ? ivar_getTypeEncoding(iv) : NULL;
    return enc && enc[0] == '@';
}

// 只看 host **自己**的 ivar 表（不向父类找）：名字命中且类型是 object 才返回它的 Ivar。
static Ivar BDHBOwnObjectIvar(Class host, const char *name) {
    unsigned count = 0;
    Ivar *list = class_copyIvarList(host, &count);
    Ivar found = NULL;
    for (unsigned i = 0; list && i < count; i++) {
        const char *n = ivar_getName(list[i]);
        if (n && strcmp(n, name) == 0) { found = list[i]; break; }
    }
    if (list) free(list);
    return BDHBIsObjectIvar(found) ? found : NULL;
}

// 安装期：10 个字段必须都在 host 自己的 ivar 表里且是 object 类型。全过才写缓存。
static BOOL BDHBCacheIvars(Class host) {
    Ivar cand = BDHBOwnObjectIvar(host, BDHBCandidateIvarName);
    if (!cand) {
        BDHBSkipOnce(&BDHBSkipMeta, "候选字段不在本类自己的 object ivar 表");
        return NO;
    }
    Ivar list[BDHB_PROTECTED_COUNT];
    for (unsigned i = 0; i < BDHB_PROTECTED_COUNT; i++) {
        Ivar iv = BDHBOwnObjectIvar(host, BDHBProtectedIvarNames[i]);
        if (!iv) {
            BDHBSkipOnce(&BDHBSkipMeta, "正常控件字段不在本类自己的 object ivar 表");
            return NO;
        }
        list[i] = iv;
    }
    BDHBCandidateIvar = cand;
    for (unsigned i = 0; i < BDHB_PROTECTED_COUNT; i++) BDHBProtectedIvars[i] = list[i];
    return YES;
}

// 总开 && 非诊断 && 实验开 && 主线程 —— 只有满足它才读候选、读写关联状态、动 UI。
static BOOL BDHBExperimentActive(void) {
    return BDEnabled() && !BDDumpOnly() && BDExperimentHideHomeBanner() && [NSThread isMainThread];
}

#pragma mark - 动作（两条 hook 共用；调用前必须先过 BDHBExperimentActive）

static void BDHBHideCandidate(id host, id candidate) {
    if (!BDHBCandidateIvar) return;                       // 未装/未缓存：不做任何事
    UIView *view = [candidate isKindOfClass:[UIView class]] ? (UIView *)candidate : nil;
    if (!view || (id)view == host) {
        BDHBSkipOnce(&BDHBSkipCandidate, "候选为空/非 UIView/等于 host");
        return;
    }
    if (view.superview != (UIView *)host) {
        BDHBSkipOnce(&BDHBSkipNotChild, "候选还不是 host 的直接子视图");
        return;
    }
    for (unsigned i = 0; i < BDHB_PROTECTED_COUNT; i++) {
        id v = object_getIvar(host, BDHBProtectedIvars[i]);     // 只读现有值：不调懒 getter、不创建
        if (!v) continue;
        if (v == view) {
            BDHBSkipOnce(&BDHBSkipProtected, "候选本身就是某个正常控件");
            return;
        }
        if (![v isKindOfClass:[UIView class]]) {
            BDHBSkipOnce(&BDHBSkipProtectedType, "正常控件字段的值不是 UIView");
            return;
        }
        if ([(UIView *)v isDescendantOfView:view]) {
            BDHBSkipOnce(&BDHBSkipProtected, "候选包含某个正常控件");
            return;
        }
    }
    if (view.hidden) return;                              // 已经隐藏：不动、不重复记 hit
    view.hidden = YES;
    BDFRSuppressed(&BDHBHitHide, "home-banner-experiment", YES);   // 真正从可见变隐藏才首次记一行
}

#pragma mark - 两条 post-hook

// setupView：先（在生效时）把该 host 的深度 +1，原实现恰好一次，再回落；只有最外层完成才允许动作。
static void BDHBSetupView(id self, SEL _cmd) {
    BOOL active = BDHBExperimentActive();
    NSInteger depth = 0;
    if (active) {
        NSNumber *cur = objc_getAssociatedObject(self, &BDHBDepthKey);
        depth = cur ? cur.integerValue : 0;
        objc_setAssociatedObject(self, &BDHBDepthKey, @(depth + 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    ((BDHBVoidIMP)BDHBOrigSetupView)(self, _cmd);          // 原实现一次：参数/返回/副作用全保留
    if (!active) return;                                   // 关闭/后台：纯透传，不写状态也不动作
    if (depth == 0) {
        objc_setAssociatedObject(self, &BDHBDepthKey, @(0), OBJC_ASSOCIATION_RETAIN_NONATOMIC);  // ready
        id candidate = BDHBCandidateIvar ? object_getIvar(self, BDHBCandidateIvar) : nil;
        BDHBHideCandidate(self, candidate);
    } else {
        objc_setAssociatedObject(self, &BDHBDepthKey, @(depth), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// bannerView：原实现一次并原样返回；只有该 host 的 setup 已完成（ready == 0）才允许动作。
static id BDHBBannerView(id self, SEL _cmd) {
    id view = ((BDHBObjectIMP)BDHBOrigBannerGetter)(self, _cmd);
    if (!BDHBExperimentActive()) return view;               // 关/后台：不读状态、不动
    NSNumber *ready = objc_getAssociatedObject(self, &BDHBDepthKey);
    if (!ready || [(NSNumber *)ready integerValue] != 0) return view;   // 从未 setup 或 setup 进行中
    // 契约落实：只动**本类自有 ivar** 指向的那个直接子视图；原 getter 返回别的对象时保留它。
    id candidate = BDHBCandidateIvar ? object_getIvar(self, BDHBCandidateIvar) : nil;
    if (!candidate || candidate != view) {
        BDHBSkipOnce(&BDHBSkipCandidate, "getter 返回值不是本类自有 _bannerView");
        return view;
    }
    BDHBHideCandidate(self, candidate);
    return view;
}

#pragma mark - spec 表与安装

static BDFRSpec BDHBspecSetupView = {
    "BDPanNewMSHTopOperationView", "setupView", NO, "v16@0:8", 2,
    (IMP)BDHBSetupView, &BDHBOrigSetupView, "home-banner-experiment", NO,
};
static BDFRSpec BDHBspecBannerView = {
    "BDPanNewMSHTopOperationView", "bannerView", NO, "@16@0:8", 2,
    (IMP)BDHBBannerView, &BDHBOrigBannerGetter, "home-banner-experiment", NO,
};

// 两条一起：必须同一个类、都 resolve 过、都 CanAttach、且字段元数据（自有 + object 类型）全过，
// 才写任何 IMP 槽与缓存（先存后换，不交换）。参数化只为让测试用假类/假 spec 驱动“任一步不过整组 skip”。
static BOOL BDHBInstallWith(BDFRSpec *setupSpec, BDFRSpec *getterSpec) {
    if (strcmp(setupSpec->cls, getterSpec->cls) != 0) {
        BDLog(@"[BDNadFeature] skip home-banner-experiment: 两条 spec 的类不一致，都不安装");
        return NO;
    }
    Method mSetup = BDFRResolve(setupSpec);
    Method mGetter = BDFRResolve(getterSpec);
    if (!mSetup || !mGetter || !BDFRCanAttach(setupSpec, mSetup) || !BDFRCanAttach(getterSpec, mGetter)) {
        BDLog(@"[BDNadFeature] skip home-banner-experiment: 两个方法未同时通过校验，都不安装");
        return NO;
    }
    Class host = objc_getClass(setupSpec->cls);
    if (!host || !BDHBCacheIvars(host)) return NO;          // 字段元数据不过：fail-closed
    BDFRAttach(setupSpec, mSetup);
    BDFRAttach(getterSpec, mGetter);
    return YES;
}

static void BDHBInstallAll(void) {
    BDHBInstallWith(&BDHBspecSetupView, &BDHBspecBannerView);
}

#endif