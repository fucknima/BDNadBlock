// BDNadBlock — 设置内菜单（UIKit only，系统控件，不造自定义设计系统）
//
// 只有一个类 BDNadBlockSettingsViewController（UITableViewStyleInsetGrouped），
// 分组/标题/默认值全部来自 Preferences.h 的规格表 —— 这里不再抄一份默认值。
// 「关于」组是纯展示（免责声明 + 群链接），没有开关 key；另外首次进入本页会弹一次免责声明，
// 其“已读”记录走 Preferences.h 的独立元数据 key：不占 21 个净化键、不进快照/待生效判断。
// 开关只写规格表里的 owned key；写的是 NSUserDefaults，冷启动才生效。
//
// 入口：BDPresentPurificationSettings(host, logURL)
//   - host 正在展示任何模态（presentedViewController 非空）-> 直接返回，不动栈、不重复弹；
//   - 否则 host 有 navigationController -> push（返回键回退，不加“完成”）；
//   - 没有 -> present 包一层 UINavigationController，右上角“完成”；
//   - 同一菜单已在栈里 -> popToViewController 回到它，不堆叠；
//   - 只从主线程的 UIKit 按钮调用；不加延时/锁/重试。
//
// 被 Tweak.xm 单一 TU include（含 Preferences.h），所以这里用 static 入口函数。
// 注意：本文件里不要出现连续的 斜杠星号 或 星号斜杠（Logos 预处理）。

#ifndef BDNAD_SETTINGS_MENU_H
#define BDNAD_SETTINGS_MENU_H

#import <UIKit/UIKit.h>
#import "Preferences.h"

// 审计区域：以下未标注的指针一律按 nonnull 理解；
// 真正可空的那几个（logURL 入参、分享行的 cell、规格查询返回、footer 文案、
// 入口的 host/logURL）显式标 _Nullable，与实现保持一致。
NS_ASSUME_NONNULL_BEGIN

#pragma mark - 菜单

@interface BDNadBlockSettingsViewController : UITableViewController
// 诊断日志文件（主会话传 Documents/BDNadBlock-dump.txt）。
// 只读分享：不上传、不复制整份文件、不删除原日志。无日志时菜单本身照常可用。
@property (nonatomic, copy, nullable) NSURL *logURL;
- (instancetype)initWithLogURL:(NSURL * _Nullable)logURL;
@end

@interface BDNadBlockSettingsViewController ()
- (void)bdSwitchChanged:(UISwitch *)sender;
- (void)bdDone;
- (void)bdShareLogFromCell:(UITableViewCell * _Nullable)cell;
- (NSUInteger)bdSwitchRowCountInGroup:(BDNadPrefsGroup)group;
- (const BDNadPrefsSpec * _Nullable)bdSpecAtRow:(NSInteger)row inGroup:(BDNadPrefsGroup)group;
- (UITableViewCell *)bdAboutCellForRow:(NSInteger)row;
- (void)bdShowDisclaimer;
- (void)bdPresentDisclaimerFirstUse:(BOOL)firstUse;
- (void)bdOpenGroupLink;
@end

#pragma mark - 关于（固定展示，不读不写任何 key）

// 群链接唯一来源：副标题与外链都引用这一份，不要在别处再抄一遍。
static NSString *const BDNadAboutGroupURLString = @"https://t.me/fuckAd1024";

// 免责声明的固定文案：「关于」条目与首次进入提示共用同一份，不要在别处再抄一遍。
// 只展示/知悉，不构成授权，也不是电子签名；有实质改动时同步升级 Preferences.h 的版本常量。
static NSString *const BDNadAboutDisclaimerText =
    @"免责声明：\n\n"
    @"本项目仅供个人学习、技术研究与交流使用，不以商业盈利或侵犯第三方合法权益为目的。\n\n"
    @"本项目为非官方第三方插件，与百度及百度网盘不存在任何关联。\n\n"
    @"请自觉遵守相关法律法规及软件服务条款。如不具备合法使用条件，请勿下载、安装、使用或传播；如已获取，请立即停止使用并删除相关文件。\n\n"
    @"本项目按现状提供，不对其兼容性、稳定性及适用性作出任何保证。\n\n"
    @"如相关权利人对本项目存在异议，可联系项目维护者沟通处理。";

// 视图已上屏且所在场景/应用在前台活跃：有 windowScene 时必须以自己那个场景为准
// （scene 化的 applicationState 不能代替当前窗口所在场景），无 scene 的老系统才退回 app state。
static inline BOOL BDNadMenuActiveAndVisible(UIView * _Nullable view) {
    UIWindow *window = view.window;
    if (!window) return NO;
    UIScene *scene = window.windowScene;
    if (scene) return scene.activationState == UISceneActivationStateForegroundActive;
    return UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
}

// 关于组的固定坐标：最后一组；两行只展示，原 21 个开关的 tag 与诊断分享行索引都不受影响。
enum {
    BDNadAboutSection = BDNadPrefsGroupDiagnostics + 1,
    BDNadAboutRowDisclaimer = 0,
    BDNadAboutRowGroup = 1,
    BDNadAboutRowCount = 2,
};

@implementation BDNadBlockSettingsViewController

- (instancetype)initWithLogURL:(NSURL * _Nullable)logURL {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _logURL = [logURL copy];
        self.title = @"净化设置";
    }
    return self;
}

#pragma mark 数据源

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return (NSInteger)BDNadAboutSection + 1;   // 规格表分组 + 最后的「关于」展示组
}

- (NSUInteger)bdSwitchRowCountInGroup:(BDNadPrefsGroup)group {
    NSUInteger n = 0;
    for (NSUInteger i = 0; i < BDNadPrefsSpecCount; i++)
        if (BDNadPrefsSpecs[i].group == group) n++;
    return n;
}

- (const BDNadPrefsSpec * _Nullable)bdSpecAtRow:(NSInteger)row inGroup:(BDNadPrefsGroup)group {
    if (row < 0) return NULL;
    NSUInteger seen = 0;
    for (NSUInteger i = 0; i < BDNadPrefsSpecCount; i++) {
        if (BDNadPrefsSpecs[i].group != group) continue;
        if (seen == (NSUInteger)row) return &BDNadPrefsSpecs[i];
        seen++;
    }
    return NULL;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if (section == (NSInteger)BDNadAboutSection) return BDNadAboutRowCount;   // 关于：固定两行，先分流
    BDNadPrefsGroup group = (BDNadPrefsGroup)section;
    NSUInteger n = [self bdSwitchRowCountInGroup:group];
    if (group == BDNadPrefsGroupDiagnostics) n += 1;   // 多一行：分享诊断日志
    return (NSInteger)n;
}

- (NSString * _Nullable)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    if (section == (NSInteger)BDNadAboutSection) return @"关于";
    return BDNadPrefsGroupTitle((BDNadPrefsGroup)section);
}

- (NSString * _Nullable)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section == (NSInteger)BDNadAboutSection) return nil;   // 关于组只展示：不借总开关的提示
    if (section != (NSInteger)BDNadPrefsGroupMaster) return nil;
    NSString *note = @"保存后请彻底退出后台并重开百度网盘生效，不会自动退出；当前页面不热更新。";
    return BDNadPrefsHasPendingChanges() ? [@"有改动待生效。" stringByAppendingString:note] : note;
}

#pragma mark cell

- (UITableViewCell *)bdSwitchCellForSpec:(const BDNadPrefsSpec *)spec {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"BDNadPrefsSwitch"];
    if (!cell)
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:@"BDNadPrefsSwitch"];
    UIListContentConfiguration *cfg = [UIListContentConfiguration cellConfiguration];
    cfg.text = @(spec->title);
    cell.contentConfiguration = cfg;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    UISwitch *sw = (UISwitch *)cell.accessoryView;
    if (![sw isKindOfClass:[UISwitch class]]) {
        sw = [[UISwitch alloc] init];
        [sw addTarget:self action:@selector(bdSwitchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
    }
    // tag = 规格表下标，action 里按 tag 反查 key（不引入额外映射表/配置类）。
    sw.tag = (NSInteger)(spec - BDNadPrefsSpecs);
    sw.accessibilityLabel = @(spec->title);
    sw.on = BDNadPrefsDesired([NSUserDefaults standardUserDefaults], @(spec->key));   // saved 值
    return cell;
}

- (UITableViewCell *)bdShareLogCell {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"BDNadPrefsShare"];
    if (!cell)
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:@"BDNadPrefsShare"];
    UIListContentConfiguration *cfg = [UIListContentConfiguration subtitleCellConfiguration];
    cfg.text = @"分享诊断日志";
    cfg.secondaryText = self.logURL.lastPathComponent ?: @"（未配置日志路径）";
    cell.contentConfiguration = cfg;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

// 关于组两行共用同一 builder；独立 reuse identifier，不碰开关/分享行的 cell 状态。
- (UITableViewCell *)bdAboutCellForRow:(NSInteger)row {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"BDNadAbout"];
    if (!cell)
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:@"BDNadAbout"];
    cell.accessoryView = nil;   // 防复用串上开关组的 UISwitch
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    UIListContentConfiguration *cfg = [UIListContentConfiguration subtitleCellConfiguration];
    cfg.textProperties.numberOfLines = 0;
    cfg.secondaryTextProperties.numberOfLines = 0;
    if (row == (NSInteger)BDNadAboutRowGroup) {
        cfg.text = @"Telegram 交流群";
        cfg.secondaryText = BDNadAboutGroupURLString;   // 与打开外链引用同一常量
    } else {
        cfg.text = @"免责声明";
    }
    cell.contentConfiguration = cfg;
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    if (indexPath.section == (NSInteger)BDNadAboutSection) return [self bdAboutCellForRow:indexPath.row];
    BDNadPrefsGroup group = (BDNadPrefsGroup)indexPath.section;
    const BDNadPrefsSpec *spec = [self bdSpecAtRow:indexPath.row inGroup:group];
    if (spec) return [self bdSwitchCellForSpec:spec];
    return [self bdShareLogCell];
}

#pragma mark 交互

- (void)bdSwitchChanged:(UISwitch *)sender {
    if (sender.tag < 0 || (NSUInteger)sender.tag >= BDNadPrefsSpecCount) return;   // 越界不动
    const BDNadPrefsSpec *spec = &BDNadPrefsSpecs[sender.tag];
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (!BDNadPrefsSetDesired(d, @(spec->key), sender.on)) {
        sender.on = BDNadPrefsDesired(d, @(spec->key));   // 只写 owned key，拒绝就回滚显示
        return;
    }
    // 刷新总开关分组的 footer（“有改动待生效”）。只动本菜单自己的表格。
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:(NSInteger)BDNadPrefsGroupMaster]
                  withRowAnimation:UITableViewRowAnimationNone];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == (NSInteger)BDNadAboutSection) {   // 关于组只走展示分支，绝不落到分享/开关路径
        if (indexPath.row == (NSInteger)BDNadAboutRowDisclaimer) [self bdShowDisclaimer];
        else if (indexPath.row == (NSInteger)BDNadAboutRowGroup) [self bdOpenGroupLink];
        return;   // 非法 row 什么都不做
    }
    if (indexPath.section != (NSInteger)BDNadPrefsGroupDiagnostics) return;
    if ((NSUInteger)indexPath.row != [self bdSwitchRowCountInGroup:BDNadPrefsGroupDiagnostics]) return;
    [self bdShareLogFromCell:[tableView cellForRowAtIndexPath:indexPath]];
}

- (void)bdShareLogFromCell:(UITableViewCell * _Nullable)cell {
    if (self.presentedViewController) return;   // 已经弹出分享/提示面板：不重复弹
    NSString *path = self.logURL.path;
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL usable = path.length > 0 && [fm fileExistsAtPath:path] && [fm isReadableFileAtPath:path];
    if (!usable) {
        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"无法分享诊断日志"
                                               message:[NSString stringWithFormat:
                                                            @"%@\n请先在网盘内正常使用一段时间后重试。",
                                                            path.length > 0 ? path : @"未配置日志文件路径"]
                                        preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    UIActivityViewController *share =
        [[UIActivityViewController alloc] initWithActivityItems:@[self.logURL] applicationActivities:nil];
    // iPad 必须给锚点，否则弹 popover 会崩。
    UIPopoverPresentationController *pop = share.popoverPresentationController;
    if (pop) {
        pop.sourceView = cell ?: self.view;
        pop.sourceRect = cell ? cell.bounds : self.view.bounds;
    }
    [self presentViewController:share animated:YES completion:nil];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // 首次进入本页才提示：这里只读元数据，不落确认；只有弹窗按钮的 handler 才写。
    if (BDNadPrefsDisclaimerAcknowledged([NSUserDefaults standardUserDefaults])) return;
    [self bdPresentDisclaimerFirstUse:YES];
}

// 首次提示与「关于 > 免责声明」共用同一正文和同一个 present 方法，不要抄两份正文。
- (void)bdPresentDisclaimerFirstUse:(BOOL)firstUse {
    if (self.presentedViewController) return;   // 已有面板：不叠第二个
    if (!BDNadMenuActiveAndVisible(self.viewIfLoaded)) return;   // 未上屏/不在前台：不弹
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:(firstUse ? @"免责声明与使用须知" : @"免责声明")
                                           message:BDNadAboutDisclaimerText
                                    preferredStyle:UIAlertControllerStyleAlert];
    if (firstUse) {
        // 唯一肯定按钮；未点它（离开/杀进程）就不算已读，下次进入会再次提示。
        [alert addAction:[UIAlertAction actionWithTitle:@"我已阅读并知悉"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            (void)action;
            BDNadPrefsAcknowledgeDisclaimer([NSUserDefaults standardUserDefaults]);
        }]];
    } else {
        // 手动查看：关闭不改首次“已读”元数据，也不强加同意。
        [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    }
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)bdShowDisclaimer {
    [self bdPresentDisclaimerFirstUse:NO];
}

- (void)bdOpenGroupLink {
    if (self.presentedViewController) return;   // 已有面板：不叠第二个
    NSURL *url = [NSURL URLWithString:BDNadAboutGroupURLString];   // 固定常量，正常不会失效
    if (!url) return;
    if (!BDNadMenuActiveAndVisible(self.viewIfLoaded)) return;   // 视图不在窗口/不在前台：不发起

    // 本次打开临时观察“离开前台”这一个事件：有 scene 只看自己那个场景，无 scene 的老系统
    // 才退回 UIApplication 的通知；block 只置一个 __block BOOL，不捕获 VC，也不常驻观察。
    UIScene *scene = self.viewIfLoaded.window.windowScene;
    __block BOOL leftForeground = NO;
    id observer = [NSNotificationCenter.defaultCenter
        addObserverForName:(scene ? UISceneWillDeactivateNotification : UIApplicationWillResignActiveNotification)
                    object:(scene ? (id)scene : nil)
                     queue:nil
                usingBlock:^(NSNotification *note) {
        (void)note;
        leftForeground = YES;
    }];

    __weak BDNadBlockSettingsViewController *weakSelf = self;   // 系统回调不延长本 VC 生命周期
    [UIApplication.sharedApplication openURL:url
                                     options:@{}
                           completionHandler:^(BOOL success) {
        [NSNotificationCenter.defaultCenter removeObserver:observer];   // 每次打开一枚临时 observer：先撤掉
        // 已交给系统浏览器的这次请求，哪怕回到前台才收到 false，也不补“无法打开”框；
        // leftForeground 只表示期间离开过前台，不表示链接或群加载成功。
        if (success || leftForeground) return;
        // 文档：该 block 在主线程异步回调。只有从头到尾都在前台、仍是当前可见菜单且真的 false 才提示。
        BDNadBlockSettingsViewController *vc = weakSelf;
        if (!vc || vc.presentedViewController) return;   // 已离开或已有面板：不越级 present
        if (!BDNadMenuActiveAndVisible(vc.viewIfLoaded)) return;
        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"无法打开群组链接"
                                               message:BDNadAboutGroupURLString
                                        preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"复制链接"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            (void)action;
            UIPasteboard.generalPasteboard.string = BDNadAboutGroupURLString;   // 只有点这个按钮才写剪贴板
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
        [vc presentViewController:alert animated:YES completion:nil];
    }];
}

- (void)bdDone {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

#pragma mark - 入口

static inline void BDPresentPurificationSettings(UIViewController * _Nullable host, NSURL * _Nullable logURL) {
    if (!host || ![NSThread isMainThread]) return;   // 只从主线程的 UIKit 按钮调用

    // host 已经在展示东西（本菜单或别的模态）：不 push、不 present、不 dismiss 别的模态，
    // 避免从被遮挡的 host 改导航栈或叠第二层模态。
    if (host.presentedViewController) return;

    UINavigationController *nav = host.navigationController;
    if (nav) {
        for (UIViewController *vc in nav.viewControllers) {
            if ([vc isKindOfClass:[BDNadBlockSettingsViewController class]]) {
                [nav popToViewController:vc animated:YES];   // 已在栈里：回到它，不堆叠
                return;
            }
        }
        BDNadBlockSettingsViewController *vc = [[BDNadBlockSettingsViewController alloc] initWithLogURL:logURL];
        [nav pushViewController:vc animated:YES];
        return;
    }

    BDNadBlockSettingsViewController *vc = [[BDNadBlockSettingsViewController alloc] initWithLogURL:logURL];
    vc.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:vc
                                                      action:@selector(bdDone)];
    UINavigationController *wrap = [[UINavigationController alloc] initWithRootViewController:vc];
    [host presentViewController:wrap animated:YES completion:nil];
}

NS_ASSUME_NONNULL_END

#endif
