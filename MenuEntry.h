// BDNadBlock — 设置页入口：给「设置」类页面导航条 append 一个「网盘净化」按钮
//
// 只做一件事：在两个已核实候选设置页**各自**的 -viewDidLoad 上装 post-hook，
// 先调原实现，再把自带 UIBarButtonItem **追加**到 self.navigationItem 的右侧按钮里。
//
// 目标类（两个都是各自方法表里自己的方法，encoding 都是 v16@0:8、argc 2）：
//   SettingConfigViewController  -viewDidLoad  v16@0:8  0x1072efc14
//   SettingViewController        -viewDidLoad  v16@0:8  0x107303144
// 二者互不依赖：任一个校验不过就只 skip 那一个，另一个照装。不做 pair 校验。
//
// 接线约定（顺序由 Tweak.xm 决定，本文件不 import 同伴头）：
//   Preferences.h → SettingsMenu.h（提供 BDPresentPurificationSettings）
//   → FeatureRemoval.h（提供 BDFRSpec / BDFRResolve / BDFRInstallSpec）→ MenuEntry.h
// 依赖但不在本文件定义的同名静态函数：BDLog / BDResolveLogPath / BDFRSpec /
//   BDFRInstallSpec。它们都在上面这些头或 Tweak.xm 里。
//
// 约束（改这里等于改行为）：
//   - 不要求 self.navigationController 已非 nil。viewDidLoad 早于 push 是常态；
//     UIViewController 的 navigationItem 本身就存在，按它追加，后续入栈自然可见。
//     不加延时、不加定时器、不补重试。
//   - 只 append，绝不覆盖左侧/右侧原按钮，也不重排原按钮顺序。
//   - 不碰 tableView 行数/索引，不碰 BDSettingViewController 的 configArray 持久化绑定。
//   - 不给宿主动态加 selector：action 落在本组件自己的 BDNadMenuEntryTarget 上。
//     target 由按钮的 associated object 强持有（唯一 static char key），
//     target 对宿主是 weak —— 没有循环引用，宿主释放后 host 自动为 nil。
//   - 幂等：追加前扫 rightBarButtonItems，命中「本组件 target 且 host == self」就跳过。
//   - 只在主线程装按钮；非主线程记录一行 skip，不补定时器。
//   - 不触发自动退出/重启/清缓存；总开关 BDNadBlockEnabled 关闭、
//     或 BDNadBlockDumpOnly 诊断开启时，入口照装（用户仍可进菜单）。
//
// 安装日志与「请求打开菜单」是两件事：前者由 BDFRInstallSpec 打 installed，
// 后者由本文件的 dispatch_once 打 menu-open-request（这里没用 BDFRSuppressed：
// 它的日志文案是「首次真正抑制」，用在打开菜单上会误导）。而 present 之前还有
// 主线程/modal 守卫，守卫拒绝时不会展示菜单，所以请求日志不等于展示成功。
//
// 注意：本文件里不要出现连续的 斜杠星号 或 星号斜杠（Logos 预处理）。

#ifndef BDNAD_MENU_ENTRY_H
#define BDNAD_MENU_ENTRY_H

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

@interface BDNadMenuEntryTarget : NSObject
// 弱引用宿主：不给宿主加 selector，也不 retain 宿主。
@property (nonatomic, weak, nullable) UIViewController *host;
- (void)open:(nullable id)sender;
@end

@implementation BDNadMenuEntryTarget

static char kBDNadMenuEntryTargetKey;   // 唯一 key：本组件在按钮上的强引用槽

- (void)open:(nullable id)sender {
    (void)sender;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 这行只是「首次请求打开」：下面 present 之前还有主线程/modal 守卫，
        // 守卫拒绝时菜单不会出现，所以不能读成「菜单已展示」。
        BDLog(@"[BDNadMenuEntry] menu-open-request: 首次请求打开净化菜单");
    });
    // BDResolveLogPath() 返回 NSString 路径，这里转成 NSURL 再传。
    BDPresentPurificationSettings(self.host,
                                  [NSURL fileURLWithPath:BDResolveLogPath()]);
}

@end

#pragma mark - 追加按钮

// 已经加过（按 target 身份认，不用字符串比对）就返回 YES。
static BOOL BDMEHasEntryOn(UIViewController *host) {
    NSArray<UIBarButtonItem *> * _Nullable existing = host.navigationItem.rightBarButtonItems;
    for (UIBarButtonItem *item in existing) {
        id t = objc_getAssociatedObject(item, &kBDNadMenuEntryTargetKey);
        if ([t isKindOfClass:[BDNadMenuEntryTarget class]] &&
            ((BDNadMenuEntryTarget *)t).host == host)
            return YES;
    }
    return NO;
}

static void BDMEAppendEntry(UIViewController *host) {
    if (![NSThread isMainThread]) {
        BDLog(@"[BDNadMenuEntry] skip append: 非主线程（不补定时器）");
        return;
    }
    if (BDMEHasEntryOn(host)) return;              // 重复进页面不叠加

    BDNadMenuEntryTarget *target = [BDNadMenuEntryTarget new];
    target.host = host;                            // weak

    UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithTitle:@"网盘净化"
                                                            style:UIBarButtonItemStylePlain
                                                           target:target
                                                           action:@selector(open:)];
    if (!item) return;                             // 不兜底重试
    objc_setAssociatedObject(item, &kBDNadMenuEntryTargetKey, target,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);   // 按钮强持有 target

    UINavigationItem *navItem = host.navigationItem;
    NSMutableArray<UIBarButtonItem *> *items = [NSMutableArray arrayWithCapacity:4];
    if (navItem.rightBarButtonItems.count) [items addObjectsFromArray:navItem.rightBarButtonItems];
    [items addObject:item];                        // 追加在末尾，保留原顺序
    navItem.rightBarButtonItems = items;
}

#pragma mark - 两个候选类的 post-hook

typedef void (*BDMEViewDidLoadIMP)(id, SEL);

// 每类一个 orig 槽：先存原 IMP、再换，实现里先调原实现。不交换 IMP。
static IMP BDMEOrigSettingConfig;
static IMP BDMEOrigSetting;

static void BDMEViewDidLoadSettingConfig(id self, SEL _cmd) {
    ((BDMEViewDidLoadIMP)BDMEOrigSettingConfig)(self, _cmd);
    BDMEAppendEntry((UIViewController *)self);
}

static void BDMEViewDidLoadSetting(id self, SEL _cmd) {
    ((BDMEViewDidLoadIMP)BDMEOrigSetting)(self, _cmd);
    BDMEAppendEntry((UIViewController *)self);
}

static BDFRSpec BDMESpecSettingConfig = {
    "SettingConfigViewController", "viewDidLoad", NO, "v16@0:8", 2,
    (IMP)BDMEViewDidLoadSettingConfig, &BDMEOrigSettingConfig, "menu-entry-setting-config", NO,
};
static BDFRSpec BDMESpecSetting = {
    "SettingViewController", "viewDidLoad", NO, "v16@0:8", 2,
    (IMP)BDMEViewDidLoadSetting, &BDMEOrigSetting, "menu-entry-setting", NO,
};

// 对外唯一入口：给 Tweak.xm 的构造器调。幂等（重复调用不动 IMP）。
static inline void BDMEInstallAll(void) {
    BDFRInstallSpec(&BDMESpecSettingConfig);   // 独立装：不过只 skip 自己
    BDFRInstallSpec(&BDMESpecSetting);
}

NS_ASSUME_NONNULL_END

#endif