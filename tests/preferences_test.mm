// tests/preferences_test.mm — Preferences.h 的 macOS host 测试
//
// 只用 isolated NSUserDefaults suite（唯一 UUID 名），不碰 standardUserDefaults，
// 不写 App 真实域，不碰 plist 文件，不起 UIKit —— UI（菜单/开关/分享面板）
// 只能在真机或模拟器上看，这里不伪造。
//
// 覆盖：规格表键唯一与默认值（21 项默认全 NO，且不改动已保存值）、旧版 NSString 值被尊重、
// 不合适类型（容器/日期）退默认不崩、未知 key 读取 fail-closed 且写入被拒、desired 保存后
// 同一 suite 的新 defaults 实例（**同进程可见性**，不等于已验证真实进程重启/落盘恢复）
// 能读到、已建快照不随写入改变、下一次快照读到新值、总开关/诊断/独立选项可读、
// 传输/下载页底部五个新键（一刻相册 / 下载小游戏 / 免流办卡 / 数据包引导 / 加速试用促销）的
// 默认值、独立保存与快照语义（键位次由固定清单逐位校验，21 key / 21 switch）；
// 首页横幅容器实验键默认 NO、保存后旧快照不变/新快照可见、与旧键互不影响；
// 免责声明“已读”元数据（BDNadBlockDisclaimerAcknowledgedVersion）独立于 21 个净化键：
// 未确认/空/错类型/旧版本读 NO 且不清旧值，只在专用写函数里落当前版本，写后快照完全不变
// （只是同进程可见性，不是已验重启，也不构成任何法律证据）；
// 退役键（BDRemoveHomePromo）不在表里：读 fail-closed、写被拒、不进快照，旧值也不被本组件清理。
//
// 构建运行（macOS，无需 IPA，无需 Theos）：
//   clang++ -std=c++17 -fobjc-arc -fblocks -Wall -Wextra -Werror \
//     -framework Foundation -o /tmp/preferences_test tests/preferences_test.mm
//   /tmp/preferences_test

#import <Foundation/Foundation.h>
#include <stdio.h>

#include "../Preferences.h"

static int gFailures = 0;

#define CHECK(cond)                                                        \
    do {                                                                   \
        if (!(cond)) {                                                     \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
            gFailures++;                                                   \
        }                                                                  \
    } while (0)

// 测试用期望键（固定清单，防止规格表被悄悄改键）。
static NSString *const kExpectedKeys[] = {
    @"BDNadBlockEnabled",
    @"BDRemoveRecommend", @"BDRemoveAITab",
    @"BDRemoveJobNovel", @"BDRemoveSearchPromo", @"BDRemoveSearchAI",
    @"BDExperimentHideHomeBanner",
    @"BDRemoveGameCenter", @"BDRemovePersonalPromotions",
    @"BDRemovePersonalBanner", @"BDRemoveTaskCard", @"BDRemovePersonalSpaceCard", @"BDRemoveRenewButton",
    @"BDNadBlockNetwork", @"BDNadBlockAdMethods",
    @"BDRemoveTransferYikePromo", @"BDRemoveTransferGamePromo", @"BDRemoveTransferCardPromo",
    @"BDRemoveTransferDataPromo", @"BDRemoveTransferTrialPromo",
    @"BDNadBlockDumpOnly",
};

static void TestSpecTable(void) {
    CHECK(BDNadPrefsSpecCount == sizeof(kExpectedKeys) / sizeof(kExpectedKeys[0]));
    for (NSUInteger i = 0; i < BDNadPrefsSpecCount; i++) {
        const BDNadPrefsSpec *s = &BDNadPrefsSpecs[i];
        CHECK(s->key != NULL && s->key[0] != '\0');
        CHECK(s->title != NULL && s->title[0] != '\0');
        CHECK(s->group >= BDNadPrefsGroupMaster && s->group <= BDNadPrefsGroupDiagnostics);
        // 键唯一：查表必须回到同一个下标。
        CHECK([@(s->key) isEqualToString:kExpectedKeys[i]]);
        const BDNadPrefsSpec *found = BDNadPrefsSpecForKey(kExpectedKeys[i]);
        CHECK(found == s);
    }
    CHECK(BDNadPrefsSpecForKey(@"BDNadNotAKnownKey") == NULL);
    CHECK(BDNadPrefsSpecForKey(nil) == NULL);
    CHECK([BDNadPrefsGroupTitle(BDNadPrefsGroupMaster) isEqualToString:@"总开关"]);
    CHECK([BDNadPrefsGroupTitle(BDNadPrefsGroupHome) isEqualToString:@"首页"]);
    CHECK([BDNadPrefsGroupTitle(BDNadPrefsGroupPersonal) isEqualToString:@"我的"]);
    CHECK([BDNadPrefsGroupTitle(BDNadPrefsGroupAds) isEqualToString:@"广告"]);
    CHECK([BDNadPrefsGroupTitle(BDNadPrefsGroupDiagnostics) isEqualToString:@"诊断"]);
}

static void TestDefaults(void) {
    // 所有功能默认不开启：21 项规格表 defaultValue 一律 NO。
    for (NSUInteger i = 0; i < BDNadPrefsSpecCount; i++)
        CHECK(BDNadPrefsSpecs[i].defaultValue == NO);
    // 分组与个别键位次不变（key 固定清单已在 TestSpecTable 逐位校验）。
    CHECK(BDNadPrefsSpecForKey(@"BDExperimentHideHomeBanner")->group == BDNadPrefsGroupHome);
    CHECK(BDNadPrefsSpecForKey(@"BDRemovePersonalSpaceCard")->group == BDNadPrefsGroupPersonal);
    CHECK(BDNadPrefsSpecForKey(@"BDRemoveRenewButton")->group == BDNadPrefsGroupPersonal);
    CHECK(BDNadPrefsSpecForKey(@"BDRemoveTransferYikePromo")->group == BDNadPrefsGroupAds);
    CHECK(BDNadPrefsSpecForKey(@"BDRemoveTransferGamePromo")->group == BDNadPrefsGroupAds);
    CHECK(BDNadPrefsSpecForKey(@"BDRemoveTransferCardPromo")->group == BDNadPrefsGroupAds);
    CHECK(BDNadPrefsSpecForKey(@"BDRemoveTransferDataPromo")->group == BDNadPrefsGroupAds);
    CHECK(BDNadPrefsSpecForKey(@"BDRemoveTransferTrialPromo")->group == BDNadPrefsGroupAds);
    CHECK(BDNadPrefsSpecForKey(@"BDNadBlockDumpOnly")->group == BDNadPrefsGroupDiagnostics);
}

int main(void) {
    @autoreleasepool {
        TestSpecTable();
        TestDefaults();

        NSString *suiteName = [@"BDNadPreferencesTest-" stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:suiteName];
        CHECK(d != nil);

        // 空 suite = 全规格默认（21 项全 NO）：只读默认，且不自动往域里写任何值。
        NSDictionary<NSString *, NSNumber *> *freshSnapshot = BDNadPrefsSnapshot(d);
        CHECK(freshSnapshot.count == 21);
        for (NSUInteger i = 0; i < BDNadPrefsSpecCount; i++) {
            CHECK(BDNadPrefsDesired(d, @(BDNadPrefsSpecs[i].key)) == NO);
            CHECK(BDNadPrefsDesired(nil, @(BDNadPrefsSpecs[i].key)) == NO);
            CHECK(freshSnapshot[@(BDNadPrefsSpecs[i].key)].boolValue == NO);
            CHECK([d objectForKey:@(BDNadPrefsSpecs[i].key)] == nil);
        }
        CHECK(BDNadPrefsDesired(d, @"BDRemoveRenewButton") == NO);
        CHECK(BDNadPrefsDesired(d, @"BDNadBlockDumpOnly") == NO);
        CHECK(BDNadPrefsDesired(nil, @"BDNadBlockEnabled") == NO);       // 冻结的 defaults 参数也不崩，仍回规格默认
        CHECK(BDNadPrefsDesired(d, nil) == NO);                           // 未知/空 key fail-closed

        // 旧版用户值（NSString）必须被尊重。
        [d setObject:@"0" forKey:@"BDRemoveGameCenter"];
        [d setObject:@"1" forKey:@"BDNadBlockNetwork"];
        [d setObject:@"true" forKey:@"BDRemoveJobNovel"];
        CHECK(BDNadPrefsDesired(d, @"BDRemoveGameCenter") == NO);
        CHECK(BDNadPrefsDesired(d, @"BDNadBlockNetwork") == YES);
        CHECK(BDNadPrefsDesired(d, @"BDRemoveJobNovel") == YES);

        // 类型不合适：退规格默认（21 项现全为 NO），不崩。
        // 数组/字典/Data 是合法 plist 值但非标量；NSDate 也是合法 plist 值但不是 bool。
        [d setObject:@[@"x"] forKey:@"BDRemoveRecommend"];
        [d setObject:@{@"x": @1} forKey:@"BDRemoveTaskCard"];
        [d setObject:[NSData dataWithBytes:"ab" length:2] forKey:@"BDRemovePersonalBanner"];
        [d setObject:[NSDate dateWithTimeIntervalSince1970:0] forKey:@"BDNadBlockEnabled"];
        [d setObject:@[@1] forKey:@"BDRemoveRenewButton"];
        CHECK(BDNadPrefsDesired(d, @"BDRemoveRecommend") == NO);
        CHECK(BDNadPrefsDesired(d, @"BDRemoveTaskCard") == NO);
        CHECK(BDNadPrefsDesired(d, @"BDRemovePersonalBanner") == NO);
        CHECK(BDNadPrefsDesired(d, @"BDNadBlockEnabled") == NO);
        CHECK(BDNadPrefsDesired(d, @"BDRemoveRenewButton") == NO);

        // 未知 key：读取 fail-closed、写入拒绝（不留任何值）。
        CHECK(BDNadPrefsDesired(d, @"BDNadUnknownKey") == NO);
        CHECK(BDNadPrefsSetDesired(d, @"BDNadUnknownKey", YES) == NO);
        CHECK([d objectForKey:@"BDNadUnknownKey"] == nil);
        CHECK(BDNadPrefsSetDesired(d, nil, YES) == NO);
        CHECK(BDNadPrefsSetDesired(nil, @"BDNadBlockEnabled", YES) == NO);   // 没有隐式 standard 域写入
        // 不属于我们的键不允许写（不是“known key”）。
        CHECK(BDNadPrefsSetDesired(d, @"BDPanSomeAppKey", YES) == NO);
        CHECK([d objectForKey:@"BDPanSomeAppKey"] == nil);

        // 退役键 BDRemoveHomePromo（已被「顶部横幅容器·实验」取代）：本组件不认它、也不替用户清理它。
        [d setObject:@YES forKey:@"BDRemoveHomePromo"];            // 模拟旧版本留下的 saved YES
        CHECK(BDNadPrefsSpecForKey(@"BDRemoveHomePromo") == NULL);
        CHECK(BDNadPrefsDesired(d, @"BDRemoveHomePromo") == NO);   // 未知 key：读 fail-closed
        CHECK(BDNadPrefsActive(@"BDRemoveHomePromo") == NO);       // 不进启动快照
        CHECK(BDNadPrefsSnapshot(d)[@"BDRemoveHomePromo"] == nil);
        CHECK(BDNadPrefsSetDesired(d, @"BDRemoveHomePromo", NO) == NO);   // 写被拒绝
        CHECK([d objectForKey:@"BDRemoveHomePromo"] != nil);       // 旧值原样留着，没被删
        CHECK([d boolForKey:@"BDRemoveHomePromo"] == YES);
        // 其余键不受影响：实验横幅键仍是默认 NO；续费与总开关同为新默认（未保存 = NO）。
        CHECK(BDNadPrefsSpecForKey(@"BDExperimentHideHomeBanner")->defaultValue == NO);
        CHECK(BDNadPrefsDesired(d, @"BDExperimentHideHomeBanner") == NO);
        CHECK(BDNadPrefsDesired(d, @"BDRemoveRenewButton") == NO);
        CHECK(BDNadPrefsDesired(d, @"BDNadBlockEnabled") == NO);

        // 写入 owned key 才成功。
        // fixture：默认全 NO 之前用户已显式保存过 YES —— 新默认不得覆盖已保存值。
        CHECK(BDNadPrefsSetDesired(d, @"BDRemovePersonalSpaceCard", YES) == YES);
        CHECK(BDNadPrefsSetDesired(d, @"BDRemoveTaskCard", YES) == YES);
        // 容量管理卡与任务卡独立；保存后旧快照不变，下次快照才读取新值。
        NSDictionary<NSString *, NSNumber *> *spaceBefore = BDNadPrefsSnapshot(d);
        CHECK(spaceBefore[@"BDRemovePersonalSpaceCard"].boolValue == YES);
        CHECK(BDNadPrefsSetDesired(d, @"BDRemovePersonalSpaceCard", NO) == YES);
        CHECK(spaceBefore[@"BDRemovePersonalSpaceCard"].boolValue == YES);
        CHECK(BDNadPrefsSnapshot(d)[@"BDRemovePersonalSpaceCard"].boolValue == NO);
        CHECK(BDNadPrefsDesired(d, @"BDRemoveTaskCard") == YES);
        CHECK(BDNadPrefsSetDesired(d, @"BDRemoveTaskCard", NO) == YES);
        CHECK(BDNadPrefsSetDesired(d, @"BDRemovePersonalSpaceCard", YES) == YES);
        CHECK(BDNadPrefsDesired(d, @"BDRemoveTaskCard") == NO);
        NSUserDefaults *spaceReopened = [[NSUserDefaults alloc] initWithSuiteName:suiteName];
        CHECK(BDNadPrefsDesired(spaceReopened, @"BDRemovePersonalSpaceCard") == YES);
        CHECK(BDNadPrefsDesired(spaceReopened, @"BDRemoveTaskCard") == NO);
        CHECK(BDNadPrefsSetDesired(d, @"BDRemoveTaskCard", YES) == YES);
        CHECK(BDNadPrefsSetDesired(d, @"BDRemoveRenewButton", YES) == YES);
        CHECK([d objectForKey:@"BDRemoveRenewButton"] != nil);
        CHECK(BDNadPrefsDesired(d, @"BDRemoveRenewButton") == YES);
        CHECK(BDNadPrefsSetDesired(d, @"BDNadBlockEnabled", NO) == YES);
        CHECK(BDNadPrefsSetDesired(d, @"BDNadBlockDumpOnly", YES) == YES);
        CHECK(BDNadPrefsDesired(d, @"BDNadBlockEnabled") == NO);
        CHECK(BDNadPrefsDesired(d, @"BDNadBlockDumpOnly") == YES);

        // 快照：先建一份，再改值，旧快照不变。
        NSDictionary<NSString *, NSNumber *> *before = BDNadPrefsSnapshot(d);
        CHECK([before isKindOfClass:[NSDictionary class]]);
        CHECK(before.count == BDNadPrefsSpecCount);
        CHECK(before[@"BDNadBlockEnabled"].boolValue == NO);
        CHECK(before[@"BDRemoveRenewButton"].boolValue == YES);
        CHECK(BDNadPrefsSetDesired(d, @"BDNadBlockEnabled", YES) == YES);
        CHECK(BDNadPrefsSetDesired(d, @"BDRemoveRenewButton", NO) == YES);
        CHECK(before[@"BDNadBlockEnabled"].boolValue == NO);              // 旧快照是 immutable 的
        CHECK(before[@"BDRemoveRenewButton"].boolValue == YES);

        // 下一次构造快照（= 模拟“下一次冷启动”时 active 会读到什么）读到的才是新值。
        NSDictionary<NSString *, NSNumber *> *after = BDNadPrefsSnapshot(d);
        CHECK(after[@"BDNadBlockEnabled"].boolValue == YES);
        CHECK(after[@"BDRemoveRenewButton"].boolValue == NO);

        // 同一 suite 的新 defaults 实例在本进程内就能看到已保存值。
        // 这只证明 suite 的内存可见性，不代表已验证真实进程重启/落盘恢复（真机待测）。
        NSUserDefaults *reopened = [[NSUserDefaults alloc] initWithSuiteName:suiteName];
        CHECK(BDNadPrefsDesired(reopened, @"BDNadBlockEnabled") == YES);
        CHECK(BDNadPrefsDesired(reopened, @"BDRemoveRenewButton") == NO);
        CHECK(BDNadPrefsDesired(reopened, @"BDNadBlockDumpOnly") == YES);
        CHECK(BDNadPrefsSnapshot(reopened)[@"BDNadBlockDumpOnly"].boolValue == YES);

        // 独立选项 + 广告层键都可读（不该被总开关污染）。
        CHECK(BDNadPrefsDesired(reopened, @"BDRemoveJobNovel") == YES);   // 旧版 NSString "true"：已保存值仍被尊重
        // 未保存过的新默认是 NO；显式保存 YES 后照旧可读。
        CHECK(BDNadPrefsDesired(reopened, @"BDRemoveSearchPromo") == NO);
        CHECK(BDNadPrefsDesired(reopened, @"BDRemovePersonalPromotions") == NO);
        CHECK(BDNadPrefsDesired(reopened, @"BDNadBlockAdMethods") == NO);
        CHECK(BDNadPrefsDesired(reopened, @"BDRemoveAITab") == NO);
        CHECK(BDNadPrefsSetDesired(reopened, @"BDRemoveSearchPromo", YES) == YES);
        CHECK(BDNadPrefsSetDesired(reopened, @"BDRemovePersonalPromotions", YES) == YES);
        CHECK(BDNadPrefsSetDesired(reopened, @"BDNadBlockAdMethods", YES) == YES);
        CHECK(BDNadPrefsSetDesired(reopened, @"BDRemoveAITab", YES) == YES);
        CHECK(BDNadPrefsDesired(reopened, @"BDRemoveSearchPromo") == YES);
        CHECK(BDNadPrefsDesired(reopened, @"BDRemovePersonalPromotions") == YES);
        CHECK(BDNadPrefsDesired(reopened, @"BDNadBlockAdMethods") == YES);
        CHECK(BDNadPrefsDesired(reopened, @"BDRemoveAITab") == YES);
        // 总开关关掉也不动这些独立已保存值（新默认 NO 不覆盖 saved YES）。
        CHECK(BDNadPrefsSetDesired(reopened, @"BDNadBlockEnabled", NO) == YES);
        CHECK(BDNadPrefsDesired(reopened, @"BDRemoveSearchPromo") == YES);
        CHECK(BDNadPrefsDesired(reopened, @"BDRemovePersonalPromotions") == YES);
        CHECK(BDNadPrefsDesired(reopened, @"BDNadBlockAdMethods") == YES);
        CHECK(BDNadPrefsDesired(reopened, @"BDRemoveAITab") == YES);
        CHECK(BDNadPrefsSetDesired(reopened, @"BDNadBlockEnabled", YES) == YES);

        // 传输页三个新广告键：未写过 = 新默认 NO；显式保存 YES 作为 fixture，再验证三个互相独立。
        CHECK(BDNadPrefsDesired(reopened, @"BDRemoveTransferYikePromo") == NO);
        CHECK(BDNadPrefsDesired(reopened, @"BDRemoveTransferGamePromo") == NO);
        CHECK(BDNadPrefsDesired(reopened, @"BDRemoveTransferCardPromo") == NO);
        CHECK(BDNadPrefsSetDesired(reopened, @"BDRemoveTransferYikePromo", YES) == YES);
        CHECK(BDNadPrefsSetDesired(reopened, @"BDRemoveTransferGamePromo", YES) == YES);
        CHECK(BDNadPrefsSetDesired(reopened, @"BDRemoveTransferCardPromo", YES) == YES);
        CHECK(BDNadPrefsDesired(reopened, @"BDRemoveTransferYikePromo") == YES);   // saved YES 不被默认覆盖
        CHECK(BDNadPrefsDesired(reopened, @"BDRemoveTransferGamePromo") == YES);
        CHECK(BDNadPrefsDesired(reopened, @"BDRemoveTransferCardPromo") == YES);

        // 只把一刻相册那个关掉：小游戏与办卡都不受影响。
        CHECK(BDNadPrefsSetDesired(reopened, @"BDRemoveTransferYikePromo", NO) == YES);
        CHECK(BDNadPrefsDesired(reopened, @"BDRemoveTransferYikePromo") == NO);
        CHECK(BDNadPrefsDesired(reopened, @"BDRemoveTransferGamePromo") == YES);
        CHECK(BDNadPrefsDesired(reopened, @"BDRemoveTransferCardPromo") == YES);

        // 快照语义：已建的那份不变，下一次构造（= 下次冷启动的读法）才看到新值。
        NSDictionary<NSString *, NSNumber *> *transferBefore = BDNadPrefsSnapshot(reopened);
        CHECK(transferBefore[@"BDRemoveTransferYikePromo"].boolValue == NO);
        CHECK(transferBefore[@"BDRemoveTransferGamePromo"].boolValue == YES);
        CHECK(transferBefore[@"BDRemoveTransferCardPromo"].boolValue == YES);
        CHECK(BDNadPrefsSetDesired(reopened, @"BDRemoveTransferGamePromo", NO) == YES);
        CHECK(BDNadPrefsSetDesired(reopened, @"BDRemoveTransferCardPromo", NO) == YES);
        CHECK(transferBefore[@"BDRemoveTransferGamePromo"].boolValue == YES);   // 旧快照是 immutable 的
        CHECK(transferBefore[@"BDRemoveTransferCardPromo"].boolValue == YES);
        CHECK(transferBefore[@"BDRemoveTransferYikePromo"].boolValue == NO);
        NSDictionary<NSString *, NSNumber *> *transferAfter = BDNadPrefsSnapshot(reopened);
        CHECK(transferAfter[@"BDRemoveTransferYikePromo"].boolValue == NO);     // 上一次保存的值
        CHECK(transferAfter[@"BDRemoveTransferGamePromo"].boolValue == NO);
        CHECK(transferAfter[@"BDRemoveTransferCardPromo"].boolValue == NO);

        // 保存后同 suite 的新 defaults 实例读到已保存值（只证明同进程可见性，不是已验重启）。
        NSUserDefaults *transferReopened = [[NSUserDefaults alloc] initWithSuiteName:suiteName];
        CHECK(BDNadPrefsDesired(transferReopened, @"BDRemoveTransferYikePromo") == NO);
        CHECK(BDNadPrefsDesired(transferReopened, @"BDRemoveTransferGamePromo") == NO);
        CHECK(BDNadPrefsDesired(transferReopened, @"BDRemoveTransferCardPromo") == NO);

        // 首页横幅容器实验键：默认 NO；保存 YES 后旧快照不变，下一次快照（= 下次冷启动的读法）才看到。
        CHECK(BDNadPrefsDesired(reopened, @"BDExperimentHideHomeBanner") == NO);   // 未写过 = 默认关闭
        NSDictionary<NSString *, NSNumber *> *experimentBefore = BDNadPrefsSnapshot(reopened);
        CHECK(experimentBefore[@"BDExperimentHideHomeBanner"].boolValue == NO);
        CHECK(BDNadPrefsSetDesired(reopened, @"BDExperimentHideHomeBanner", YES) == YES);
        CHECK(experimentBefore[@"BDExperimentHideHomeBanner"].boolValue == NO);    // 旧快照是 immutable 的
        NSDictionary<NSString *, NSNumber *> *experimentAfter = BDNadPrefsSnapshot(reopened);
        CHECK(experimentAfter[@"BDExperimentHideHomeBanner"].boolValue == YES);
        // 实验键独立：它开/关都不动传输页那三个已保存的 NO。
        CHECK(experimentAfter[@"BDRemoveTransferYikePromo"].boolValue == NO);
        CHECK(experimentAfter[@"BDRemoveTransferGamePromo"].boolValue == NO);
        CHECK(experimentAfter[@"BDRemoveTransferCardPromo"].boolValue == NO);
        // 同 suite 新实例读到 YES（同进程可见性，不是已验重启）；再关回去只影响它自己。
        NSUserDefaults *experimentReopened = [[NSUserDefaults alloc] initWithSuiteName:suiteName];
        CHECK(BDNadPrefsDesired(experimentReopened, @"BDExperimentHideHomeBanner") == YES);
        CHECK(BDNadPrefsSetDesired(experimentReopened, @"BDExperimentHideHomeBanner", NO) == YES);
        CHECK(BDNadPrefsDesired(experimentReopened, @"BDExperimentHideHomeBanner") == NO);
        CHECK(BDNadPrefsDesired(experimentReopened, @"BDRemoveTransferYikePromo") == NO);
        CHECK(BDNadPrefsDesired(experimentReopened, @"BDRemoveTransferGamePromo") == NO);
        CHECK(BDNadPrefsDesired(experimentReopened, @"BDRemoveTransferCardPromo") == NO);

        // 底部 widget 两条新键（数据包/流量包引导 + 加速试用促销）：未写过 = 新默认 NO；
        // 显式保存 YES 后照旧走「互相独立、快照语义一致，且不影响旧键或用户已保存开启的顶部实验」回归。
        CHECK(BDNadPrefsSetDesired(experimentReopened, @"BDExperimentHideHomeBanner", YES) == YES);
        CHECK(BDNadPrefsDesired(experimentReopened, @"BDRemoveTransferDataPromo") == NO);
        CHECK(BDNadPrefsDesired(experimentReopened, @"BDRemoveTransferTrialPromo") == NO);
        CHECK(BDNadPrefsSetDesired(experimentReopened, @"BDRemoveTransferDataPromo", YES) == YES);
        CHECK(BDNadPrefsSetDesired(experimentReopened, @"BDRemoveTransferTrialPromo", YES) == YES);
        NSDictionary<NSString *, NSNumber *> *widgetBefore = BDNadPrefsSnapshot(experimentReopened);
        CHECK(widgetBefore[@"BDRemoveTransferDataPromo"].boolValue == YES);
        CHECK(widgetBefore[@"BDRemoveTransferTrialPromo"].boolValue == YES);
        CHECK(widgetBefore[@"BDExperimentHideHomeBanner"].boolValue == YES);
        CHECK(BDNadPrefsSetDesired(experimentReopened, @"BDRemoveTransferDataPromo", NO) == YES);
        CHECK(widgetBefore[@"BDRemoveTransferDataPromo"].boolValue == YES);   // 旧快照是 immutable 的
        CHECK(BDNadPrefsDesired(experimentReopened, @"BDRemoveTransferDataPromo") == NO);
        CHECK(BDNadPrefsDesired(experimentReopened, @"BDRemoveTransferTrialPromo") == YES);  // 另一条独立
        CHECK(BDNadPrefsSetDesired(experimentReopened, @"BDRemoveTransferTrialPromo", NO) == YES);
        NSDictionary<NSString *, NSNumber *> *widgetAfter = BDNadPrefsSnapshot(experimentReopened);
        CHECK(widgetAfter[@"BDRemoveTransferDataPromo"].boolValue == NO);
        CHECK(widgetAfter[@"BDRemoveTransferTrialPromo"].boolValue == NO);
        // 新键互不影响旧 flags 与顶部实验项
        CHECK(widgetAfter[@"BDExperimentHideHomeBanner"].boolValue == YES);
        CHECK(widgetAfter[@"BDRemoveTransferYikePromo"].boolValue == NO);     // 前面保存过 NO
        CHECK(widgetAfter[@"BDRemoveTransferGamePromo"].boolValue == NO);
        CHECK(widgetAfter[@"BDRemoveTransferCardPromo"].boolValue == NO);
        CHECK(widgetAfter[@"BDNadBlockEnabled"].boolValue == YES);
        CHECK(widgetAfter[@"BDRemoveRenewButton"].boolValue == NO);
        CHECK(widgetAfter[@"BDNadBlockDumpOnly"].boolValue == YES);
        // 同 suite 新实例读到新键已保存值（同进程可见性，不是已验重启）
        NSUserDefaults *widgetReopened = [[NSUserDefaults alloc] initWithSuiteName:suiteName];
        CHECK(BDNadPrefsDesired(widgetReopened, @"BDRemoveTransferDataPromo") == NO);
        CHECK(BDNadPrefsDesired(widgetReopened, @"BDRemoveTransferTrialPromo") == NO);
        CHECK(BDNadPrefsDesired(widgetReopened, @"BDExperimentHideHomeBanner") == YES);

        // 免责声明“已读”元数据：独立固定 key，不属于 21 个净化键，也不进快照/待生效判断。
        // 这里只验证同一进程内 isolated suite 的读写语义（不是跨重启实机验证，更不是法律证据）。
        CHECK(BDNadPrefsDisclaimerAcknowledged(nil) == NO);    // 没有 defaults：未确认
        CHECK(BDNadPrefsAcknowledgeDisclaimer(nil) == NO);     // 也不允许写
        CHECK(BDNadPrefsDisclaimerAcknowledged(d) == NO);      // 空 suite：未确认
        CHECK(BDNadPrefsSetDesired(d, @"BDNadBlockDisclaimerAcknowledgedVersion", YES) == NO);   // 不是净化键
        CHECK([d objectForKey:@"BDNadBlockDisclaimerAcknowledgedVersion"] == nil);
        [d setObject:@[@"x"] forKey:@"BDNadBlockDisclaimerAcknowledgedVersion"];   // 容器：未确认
        CHECK(BDNadPrefsDisclaimerAcknowledged(d) == NO);
        [d setObject:@1 forKey:@"BDNadBlockDisclaimerAcknowledgedVersion"];        // 数字：未确认
        CHECK(BDNadPrefsDisclaimerAcknowledged(d) == NO);
        [d setObject:@"" forKey:@"BDNadBlockDisclaimerAcknowledgedVersion"];       // 空串：未确认
        CHECK(BDNadPrefsDisclaimerAcknowledged(d) == NO);
        [d setObject:@"2026-10-18-v2" forKey:@"BDNadBlockDisclaimerAcknowledgedVersion"];   // 上一真实版本：未确认，且不清旧值
        CHECK(BDNadPrefsDisclaimerAcknowledged(d) == NO);
        CHECK([[d stringForKey:@"BDNadBlockDisclaimerAcknowledgedVersion"] isEqualToString:@"2026-10-18-v2"]);
        CHECK(BDNadPrefsSpecForKey(@"BDNadBlockDisclaimerAcknowledgedVersion") == NULL);
        NSDictionary<NSString *, NSNumber *> *metaBefore = BDNadPrefsSnapshot(d);
        CHECK(metaBefore.count == 21 && metaBefore.count == BDNadPrefsSpecCount);   // 元数据没混进规格
        CHECK(metaBefore[@"BDNadBlockDisclaimerAcknowledgedVersion"] == nil);
        CHECK(BDNadPrefsAcknowledgeDisclaimer(d) == YES);      // 首次提示确认按钮才走这里
        CHECK(BDNadPrefsDisclaimerAcknowledged(d) == YES);
        CHECK([[d stringForKey:@"BDNadBlockDisclaimerAcknowledgedVersion"] isEqualToString:BDNadBlockDisclaimerVersion]);
        NSUserDefaults *metaReopened = [[NSUserDefaults alloc] initWithSuiteName:suiteName];
        CHECK(BDNadPrefsDisclaimerAcknowledged(metaReopened) == YES);   // 同进程可见性（不是已验重启）
        CHECK([BDNadPrefsSnapshot(d) isEqual:metaBefore]);     // 快照完全不变：元数据不参与净化快照
        NSDictionary<NSString *, NSNumber *> *metaAfter = BDNadPrefsSnapshot(d);
        CHECK(metaAfter[@"BDNadBlockEnabled"].boolValue == YES);            // 前面显式保存的总开关 YES 仍被尊重
        CHECK(metaAfter[@"BDRemoveRenewButton"].boolValue == NO);
        CHECK(metaAfter[@"BDExperimentHideHomeBanner"].boolValue == YES);   // 顶部实验的用户 saved YES 仍在
        CHECK(BDNadPrefsDesired(d, @"BDRemoveHomePromo") == NO);            // 退役键语义不变
        CHECK([d boolForKey:@"BDRemoveHomePromo"] == YES);
        CHECK(BDNadPrefsDesired(d, @"BDNadUnknownKey") == NO);              // 未知键仍 fail-closed

        // 清理：只删本次测试 owned 的 suite，不碰真实域。
        [d removePersistentDomainForName:suiteName];
        for (NSUInteger i = 0; i < BDNadPrefsSpecCount; i++)
            CHECK(BDNadPrefsDesired(d, @(BDNadPrefsSpecs[i].key)) == NO);   // 删完 21 项全回新默认 NO（证明域确实被清）
        CHECK([d objectForKey:@"BDNadBlockEnabled"] == nil);                 // 已保存过的总开关也真的被删除
        CHECK(BDNadPrefsDisclaimerAcknowledged(d) == NO);                   // 阅读元数据随域清掉，读作未确认
    }

    if (gFailures == 0) {
        printf("preferences_test: all checks passed\n");
        return 0;
    }
    fprintf(stderr, "preferences_test: %d check(s) failed\n", gFailures);
    return 1;
}
