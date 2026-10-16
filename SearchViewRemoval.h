// SearchViewRemoval.h — 首页搜索框的 UI 层清理（UIKit only）
//
// 两个独立开关，各管一件事，互不影响：
//   BDRemoveSearchPromo -> 清掉搜索框的轮播占位词，并恢复普通提示文案
//   BDRemoveSearchAI    -> 隐藏搜索框内的 AI 图标与右侧 AI 识别按钮，并收回为它们预留的 inset
//
// 三条 post-hook（全部先调原实现，保留原生命周期、回调、滚动联动）：
//   -[BDPanNewMSHSearchView setupView]                     v16@0:8     argc 2
//   -[BDPanNewMSHSearchView searchPlaceholderUpdated:]     v24@0:8@16  argc 3
//   -[BDPanNewMSHSearchView updateConstraintsWithProgress:] v24@0:8d16 argc 3
//
// 安装策略（三条一组，失败一个就一个都不装）：
//   1. 先对三条 hook 全部做只读 BDFRResolve + BDFRCanAttach；
//   2. 再对全部依赖 getter / setTexts: / configWithLabelConfig: 做只读 BDFRResolve
//      （只取 Method 与 IMP，不 attach、不发消息；缺类或签名不符就整组放弃）；
//   3. 全部通过才依次 BDFRAttach。
//   不允许出现「只装了滚动刷新那条、没装首帧那条」的半套状态 —— 那样静止时搜索框仍有空档。
//
// 轮播清理的具体做法（只用原实现自己的清除路径）：
//   cfg.texts = @[] -> [scrollLabel configWithLabelConfig: cfg]
//   -[BDPanVerticalScrollLableView configWithLabelConfig:] 实测 encoding 是 v24@0:8@16（void 返回，
//   主二进制两套解法一致），它会在 labels.count != texts.count 时执行 setLabels:@[] +
//   removeAllSubviews + cancleTimer，
//   即由原实现负责清 label、移除 subview、停轮播定时器；我们只负责把 texts 交成空数组。
//   然后用 App 官方的本地化 fallback 恢复搜索框普通标题：
//   [NSBundle.mainBundle localizedStringForKey:@"SearchPlaceholder" value:@"" table:nil]
//   （不用 -searchPlaceholder：它可能仍保留上一轮轮播词。）
//   不调用 setText: / setAttributedTitle:，因此不碰用户正在输入的内容，也不碰搜索历史。
//
// 三条额外的自我约束：
//   - getter 的 encoding 返回 @ 不代表运行时对象就是那个类：cfg / scroll 在调用点还要
//     isKindOfClass: 复核安装期记下的 Class，不符合就跳过该步（不给别的类套本类布局，
//     也不拿 nil 顶替）。
//   - hit 日志只在「确实对合法对象做了事」时打：轮播 = 真的 apply 了 config 或真的恢复了
//     合法 UIButton 的标题；AI = 真的有 view 从可见变隐藏，或 inset 确实与目标值不同。
//     installed / skip 与命中分开记，installed 不算命中。
//   - 三条 post-hook 都是先调原实现，再用 [NSThread isMainThread] 守住本组件新增的 UI 修改；
//     非主线程只打一行首次 skip 日志，不 dispatch 延时、不碰后台 UIKit。
//
// AI 隐藏的具体做法：
//   隐藏且只隐藏四个真实视图：genflowButton、genflowAnimationView、cameraButton、
//   cameraButtonAnimateBackground；再把 searchButton 的 contentEdgeInsets 收回为 (0, 8, 0, 12)
//   （原实现是 (0, 26+16+8, 0, 24+12)，8/12 是原实现自己扣掉图标后的基础留白）。
//   不改任何约束、不改 frame、不加定时器/延时/重试；setupView 后与每次滚动刷新后各应用一次。
//   contentEdgeInsets 是被 hook 的旧式原生 UIButton 用的属性（该类没有 UIButtonConfiguration），
//   只在这一处兼容调用周围关掉 -Wdeprecated-declarations，不做全局 -Wno。
//   customSearchPlaceholder 特殊页面分支不在本次范围，未验证。
//
// 依赖（本文件被 Tweak.xm include，需要同名静态函数）：
//   BDLog / BDEnabled / BDDumpOnly / BDRemoveSearchPromo
//   BDRemoveSearchAI —— 由 Tweak.xm 定义，契约：
//       static BOOL BDRemoveSearchAI(void) { return BDNadPrefsActive(@"BDRemoveSearchAI"); }
//       与 BDRemoveSearchPromo 同形，读同一份进程启动快照，不热改、不写偏好。
//
// BDFRSpec / BDFRResolve / BDFRCanAttach / BDFRAttach / BDFRSuppressed 复用 FeatureRemoval.h，
// 本文件不复制；include 时必须放在 FeatureRemoval.h 之后。
//
// 注意：本文件（以及任何被 Tweak.xm include 的文件）里不要出现连续的 斜杠星号 或 星号斜杠，
// 哪怕在 // 行注释里也不行 —— Theos 的 Logos 预处理器会把它当块注释，吞掉后面的代码。

#ifndef BDNAD_SEARCH_VIEW_REMOVAL_H
#define BDNAD_SEARCH_VIEW_REMOVAL_H

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#pragma mark - typed 依赖（安装时从 runtime 取出；调用前已核对 encoding 与 argc）

typedef void (*BDSRVoidIMP)(id, SEL);
typedef void (*BDSRVoidArgIMP)(id, SEL, double);
typedef id (*BDSRGetterIMP)(id, SEL);
typedef void (*BDSRSetObjectIMP)(id, SEL, id);

// 原始 IMP（先存后换，绝不交换）
static IMP BDSROrigSetupView;                    // -[BDPanNewMSHSearchView setupView]
static IMP BDSROrigPlaceholderUpdated;           // -[... searchPlaceholderUpdated:]
static IMP BDSROrigUpdateConstraints;            // -[... updateConstraintsWithProgress:]

// 依赖 IMP：从 Method 槽里取出后用 typed 指针调用，不经过未声明的 objc_msgSend。
static BDSRGetterIMP BDSRImpSearchButton;
static BDSRGetterIMP BDSRImpScrollLabel;
static BDSRGetterIMP BDSRImpScrollLabelConfig;
static BDSRGetterIMP BDSRImpGenflowButton;
static BDSRGetterIMP BDSRImpGenflowAnimationView;
static BDSRGetterIMP BDSRImpCameraButton;
static BDSRGetterIMP BDSRImpCameraButtonAnimateBackground;
static BDSRSetObjectIMP BDSRImpConfigSetTexts;       // -setTexts:             v24@0:8@16
static BDSRSetObjectIMP BDSRImpScrollApplyConfig;     // -configWithLabelConfig: v24@0:8@16（void）

// 安装期一并记下的宿主类：getter 的 encoding 返回 @ 不等于运行时对象一定是它，
// 用这些 Class 在调用点做 isKindOfClass: 复核；不符合就跳过该步，不给别的类套用本类布局。
static Class BDSRScrollLabelConfigClass;               // BDPanVerticalScrollLableViewConfig
static Class BDSRScrollLabelClass;                     // BDPanVerticalScrollLableView

static dispatch_once_t BDSRHitPromoView;         // 轮播清理首次真正生效
static dispatch_once_t BDSRHitAIView;            // AI 隐藏首次真正生效
static dispatch_once_t BDSRHitOffMainSkipped;    // 非主线程跳过本组件 UI 修改（首次一行）

#pragma mark - 两个动作（都只在实际对合法对象做了事时才打 hit 日志）

// 轮播清理：交空 texts 让原实现清干净，再恢复普通标题。
// 返回 YES 表示这一步确实动了合法对象（决定要不要打首次 hit）。
static BOOL BDSRClearSearchCarousel(id self) {
    BOOL didSomething = NO;

    id cfg = BDSRImpScrollLabelConfig(self, @selector(scrollLabelConfig));
    id scroll = BDSRImpScrollLabel(self, @selector(scrollLabel));
    BOOL cfgOK = cfg && BDSRScrollLabelConfigClass &&
                 [cfg isKindOfClass:BDSRScrollLabelConfigClass];
    BOOL scrollOK = scroll && BDSRScrollLabelClass &&
                    [scroll isKindOfClass:BDSRScrollLabelClass];
    if (cfgOK) {
        BDSRImpConfigSetTexts(cfg, @selector(setTexts:), @[]);
        didSomething = YES;
    }
    if (cfgOK && scrollOK) BDSRImpScrollApplyConfig(scroll, @selector(configWithLabelConfig:), cfg);

    id button = BDSRImpSearchButton(self, @selector(searchButton));
    if ([button isKindOfClass:[UIButton class]]) {
        // App 官方本地化 fallback（zh-Hans: SearchPlaceholder = 搜索网盘文件）；
        // 不用 -searchPlaceholder，避免把旧轮播词又写回标题。
        [(UIButton *)button setTitle:[NSBundle.mainBundle localizedStringForKey:@"SearchPlaceholder"
                                                                         value:@""
                                                                         table:nil]
                           forState:UIControlStateNormal];
        didSomething = YES;
    }
    if (didSomething) BDFRSuppressed(&BDSRHitPromoView, "search-promo-view", YES);
    return didSomething;
}

// AI 隐藏：四个视图隐藏 + 收回 inset。只对真实 UIView / UIButton 发消息。
// 返回 YES 表示确实有一个 view 从可见变隐藏、或 inset 确实需要收回。
static BOOL BDSRHideSearchAIViews(id self) {
    BOOL didSomething = NO;

    id views[4];
    views[0] = BDSRImpGenflowButton(self, @selector(genflowButton));
    views[1] = BDSRImpGenflowAnimationView(self, @selector(genflowAnimationView));
    views[2] = BDSRImpCameraButton(self, @selector(cameraButton));
    views[3] = BDSRImpCameraButtonAnimateBackground(self, @selector(cameraButtonAnimateBackground));
    for (int i = 0; i < 4; i++) {
        if (![views[i] isKindOfClass:[UIView class]]) continue;
        if ([(UIView *)views[i] isHidden]) continue;
        [(UIView *)views[i] setHidden:YES];
        didSomething = YES;
    }

    id button = BDSRImpSearchButton(self, @selector(searchButton));
    if ([button isKindOfClass:[UIButton class]]) {
        // 被 hook 的是旧式原生 UIButton，本身就在用这个属性；只在这一段兼容，
        // 不替换成 UIButtonConfiguration（会改变原按钮风格）。
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        UIEdgeInsets current = [(UIButton *)button contentEdgeInsets];
        UIEdgeInsets want = UIEdgeInsetsMake(0.0, 8.0, 0.0, 12.0);
        if (!UIEdgeInsetsEqualToEdgeInsets(current, want)) {
            [(UIButton *)button setContentEdgeInsets:want];
            didSomething = YES;
        }
#pragma clang diagnostic pop
    }
    if (didSomething) BDFRSuppressed(&BDSRHitAIView, "search-ai-view", YES);
    return didSomething;
}

// 本组件只新增 UI 修改，所以只在自己确实是主线程时才动手；不 dispatch 延时、不碰后台 UIKit。
// 这不是去修 App 自己在后台改 UI 的行为，只是本组件不跟着改。
static BOOL BDSRCanTouchUI(void) {
    if ([NSThread isMainThread]) return YES;
    // 这里不是抑制、是「因为非主线程什么都没做」，所以不能用 BDFRSuppressed：
    // 它的文案是「首次真正抑制」，会把一次 skip 误报成命中。用自己的 token 打一行 skip。
    dispatch_once(&BDSRHitOffMainSkipped, ^{
        BDLog(@"[BDNadSearch] skip search-view UI 修改：非主线程（不补延时、不碰后台 UIKit）");
    });
    return NO;
}

#pragma mark - 三条 post-hook（先原后改）

static void BDSRSetupView(id self, SEL _cmd) {
    ((BDSRVoidIMP)BDSROrigSetupView)(self, _cmd);
    if (!(BDEnabled() && !BDDumpOnly() && BDSRCanTouchUI())) return;
    if (BDRemoveSearchPromo()) BDSRClearSearchCarousel(self);
    if (BDRemoveSearchAI()) BDSRHideSearchAIViews(self);
}

static void BDSRPlaceholderUpdated(id self, SEL _cmd, id note) {
    ((void (*)(id, SEL, id))BDSROrigPlaceholderUpdated)(self, _cmd, note);
    if (!(BDEnabled() && !BDDumpOnly() && BDSRCanTouchUI())) return;
    if (BDRemoveSearchPromo()) BDSRClearSearchCarousel(self);
}

static void BDSRUpdateConstraints(id self, SEL _cmd, double progress) {
    ((BDSRVoidArgIMP)BDSROrigUpdateConstraints)(self, _cmd, progress);
    if (!(BDEnabled() && !BDDumpOnly() && BDSRCanTouchUI())) return;
    if (BDRemoveSearchAI()) BDSRHideSearchAIViews(self);
}

#pragma mark - spec、依赖清单与安装器

static BDFRSpec BDSRViewHooks[3] = {
    {"BDPanNewMSHSearchView", "setupView",                     NO, "v16@0:8",     2,
     (IMP)BDSRSetupView,           &BDSROrigSetupView,         "search-view-setup",        NO},
    {"BDPanNewMSHSearchView", "searchPlaceholderUpdated:",     NO, "v24@0:8@16", 3,
     (IMP)BDSRPlaceholderUpdated,  &BDSROrigPlaceholderUpdated,"search-promo-placeholder", NO},
    {"BDPanNewMSHSearchView", "updateConstraintsWithProgress:",NO, "v24@0:8d16", 3,
     (IMP)BDSRUpdateConstraints,   &BDSROrigUpdateConstraints, "search-ai-constraints",     NO},
};

// 只读依赖：只用来核对「类在、方法在、本类自己实现、encoding 与 argc 都对」，不 attach。
static BDFRSpec BDSRDepSearchButton = {
    "BDPanNewMSHSearchView", "searchButton", NO, "@16@0:8", 2,
    NULL, NULL, "search-view-dep-searchButton", NO };
static BDFRSpec BDSRDepScrollLabel = {
    "BDPanNewMSHSearchView", "scrollLabel", NO, "@16@0:8", 2,
    NULL, NULL, "search-view-dep-scrollLabel", NO };
static BDFRSpec BDSRDepScrollLabelConfig = {
    "BDPanNewMSHSearchView", "scrollLabelConfig", NO, "@16@0:8", 2,
    NULL, NULL, "search-view-dep-scrollLabelConfig", NO };
static BDFRSpec BDSRDepGenflowButton = {
    "BDPanNewMSHSearchView", "genflowButton", NO, "@16@0:8", 2,
    NULL, NULL, "search-view-dep-genflowButton", NO };
static BDFRSpec BDSRDepGenflowAnimationView = {
    "BDPanNewMSHSearchView", "genflowAnimationView", NO, "@16@0:8", 2,
    NULL, NULL, "search-view-dep-genflowAnimationView", NO };
static BDFRSpec BDSRDepCameraButton = {
    "BDPanNewMSHSearchView", "cameraButton", NO, "@16@0:8", 2,
    NULL, NULL, "search-view-dep-cameraButton", NO };
static BDFRSpec BDSRDepCameraButtonAnimateBackground = {
    "BDPanNewMSHSearchView", "cameraButtonAnimateBackground", NO, "@16@0:8", 2,
    NULL, NULL, "search-view-dep-cameraButtonAnimateBackground", NO };
static BDFRSpec BDSRDepConfigSetTexts = {
    "BDPanVerticalScrollLableViewConfig", "setTexts:", NO, "v24@0:8@16", 3,
    NULL, NULL, "search-view-dep-config-setTexts", NO };
static BDFRSpec BDSRDepScrollApplyConfig = {
    "BDPanVerticalScrollLableView", "configWithLabelConfig:", NO, "v24@0:8@16", 3,
    NULL, NULL, "search-view-dep-scroll-configWithLabelConfig", NO };

#define BDSR_VIEW_HOOK_COUNT 3

static BOOL BDSRResolveViewHooks(Method *outMethods) {
    for (unsigned i = 0; i < BDSR_VIEW_HOOK_COUNT; i++) {
        Method m = BDFRResolve(&BDSRViewHooks[i]);          // 只读，自己会打 skip 日志
        if (!m || !BDFRCanAttach(&BDSRViewHooks[i], m)) {
            BDLog(@"[BDNadSearch] skip search-view 组：%s 未通过校验，三条都不安装",
                  BDSRViewHooks[i].name);
            return NO;
        }
        outMethods[i] = m;
    }
    return YES;
}

// 依赖里任何一个缺类 / 缺自有方法 / encoding 或 argc 不符 -> 整组放弃。
// 这里只读 Method、只取 IMP，永远不 attach，也不往任何类上注册方法。
static BOOL BDSRResolveViewDeps(void) {
    Method m = NULL;

    m = BDFRResolve(&BDSRDepSearchButton);
    if (!m) goto depFail;
    BDSRImpSearchButton = (BDSRGetterIMP)method_getImplementation(m);

    m = BDFRResolve(&BDSRDepScrollLabel);
    if (!m) goto depFail;
    BDSRImpScrollLabel = (BDSRGetterIMP)method_getImplementation(m);

    m = BDFRResolve(&BDSRDepScrollLabelConfig);
    if (!m) goto depFail;
    BDSRImpScrollLabelConfig = (BDSRGetterIMP)method_getImplementation(m);

    m = BDFRResolve(&BDSRDepGenflowButton);
    if (!m) goto depFail;
    BDSRImpGenflowButton = (BDSRGetterIMP)method_getImplementation(m);

    m = BDFRResolve(&BDSRDepGenflowAnimationView);
    if (!m) goto depFail;
    BDSRImpGenflowAnimationView = (BDSRGetterIMP)method_getImplementation(m);

    m = BDFRResolve(&BDSRDepCameraButton);
    if (!m) goto depFail;
    BDSRImpCameraButton = (BDSRGetterIMP)method_getImplementation(m);

    m = BDFRResolve(&BDSRDepCameraButtonAnimateBackground);
    if (!m) goto depFail;
    BDSRImpCameraButtonAnimateBackground = (BDSRGetterIMP)method_getImplementation(m);

    m = BDFRResolve(&BDSRDepConfigSetTexts);
    if (!m) goto depFail;
    BDSRImpConfigSetTexts = (BDSRSetObjectIMP)method_getImplementation(m);
    BDSRScrollLabelConfigClass = objc_getClass(BDSRDepConfigSetTexts.cls);

    m = BDFRResolve(&BDSRDepScrollApplyConfig);
    if (!m) goto depFail;
    BDSRImpScrollApplyConfig = (BDSRSetObjectIMP)method_getImplementation(m);
    BDSRScrollLabelClass = objc_getClass(BDSRDepScrollApplyConfig.cls);

    return YES;

depFail:
    BDLog(@"[BDNadSearch] skip search-view 组：依赖未通过校验（%s），三条都不安装",
          "见上面 BDFRResolve 的 skip 日志");
    return NO;
}

static void BDSRInstallView(void) {
    static Method methods[BDSR_VIEW_HOOK_COUNT];
    if (!BDSRResolveViewHooks(methods)) return;
    if (!BDSRResolveViewDeps()) return;
    for (unsigned i = 0; i < BDSR_VIEW_HOOK_COUNT; i++) BDFRAttach(&BDSRViewHooks[i], methods[i]);
}

#endif // BDNAD_SEARCH_VIEW_REMOVAL_H