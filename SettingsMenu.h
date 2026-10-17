// BDNadBlock — 设置内菜单（UIKit only，系统控件，不造自定义设计系统）
//
// 只有一个类 BDNadBlockSettingsViewController（UITableViewStyleInsetGrouped），
// 分组/标题/默认值全部来自 Preferences.h 的规格表 —— 这里不再抄一份默认值。
// 唯一例外是最后的「关于」组：纯展示（免责声明 + 群链接），没有 key、不读写 NSUserDefaults。
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
- (void)bdOpenGroupLink;
@end

#pragma mark - 关于（固定展示，不读不写任何 key）

// 群链接唯一来源：副标题与外链都引用这一份，不要在别处再抄一遍。
static NSString *const BDNadAboutGroupURLString = @"https://t.me/fuckAd1024";

// 免责声明的固定文案（只展示，不落盘、不要求同意）。
static NSString *const BDNadAboutDisclaimerText =
    @"本工具为非官方第三方插件，与百度无关联，仅供个人学习与技术研究。\n\n"
    @"不保证所有版本或设备兼容，使用可能造成界面异常、功能失效或数据风险，请事先备份重要数据。\n\n"
    @"请在法律允许且已获授权的范围内使用，遵守相关服务条款并自行评估风险；本声明不排除依法不可免除的责任。";

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

- (void)bdShowDisclaimer {
    if (self.presentedViewController) return;   // 已有面板：不叠第二个
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"免责声明"
                                           message:BDNadAboutDisclaimerText
                                    preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)bdOpenGroupLink {
    if (self.presentedViewController) return;   // 已有面板：不叠第二个
    NSURL *url = [NSURL URLWithString:BDNadAboutGroupURLString];   // 固定常量，正常不会失效
    if (!url) return;
    __weak BDNadBlockSettingsViewController *weakSelf = self;   // 系统回调不延长本 VC 生命周期
    [UIApplication.sharedApplication openURL:url
                                     options:@{}
                           completionHandler:^(BOOL success) {
        if (success) return;   // 已交给系统选择浏览器/Telegram：不弹框
        // 文档：该 block 在主线程异步回调。失败只提示，不重试、不换 scheme、不预先探测。
        BDNadBlockSettingsViewController *vc = weakSelf;
        if (!vc || vc.presentedViewController) return;   // 已离开或已有面板：不越级 present
        if (!vc.viewIfLoaded.window) return;             // 视图不在窗口：不弹
        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"无法打开群组链接"
                                               message:BDNadAboutGroupURLString
                                        preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
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
