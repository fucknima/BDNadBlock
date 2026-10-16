// BDNadBlock — 设置内菜单（UIKit only，系统控件，不造自定义设计系统）
//
// 只有一个类 BDNadBlockSettingsViewController（UITableViewStyleInsetGrouped），
// 分组/标题/默认值全部来自 Preferences.h 的规格表 —— 这里不再抄一份默认值。
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
@end

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
    return (NSInteger)BDNadPrefsGroupDiagnostics + 1;
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
    BDNadPrefsGroup group = (BDNadPrefsGroup)section;
    NSUInteger n = [self bdSwitchRowCountInGroup:group];
    if (group == BDNadPrefsGroupDiagnostics) n += 1;   // 多一行：分享诊断日志
    return (NSInteger)n;
}

- (NSString * _Nullable)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    return BDNadPrefsGroupTitle((BDNadPrefsGroup)section);
}

- (NSString * _Nullable)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
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

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
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
