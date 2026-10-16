// tests/preferences_test.mm — Preferences.h 的 macOS host 测试
//
// 只用 isolated NSUserDefaults suite（唯一 UUID 名），不碰 standardUserDefaults，
// 不写 App 真实域，不碰 plist 文件，不起 UIKit —— UI（菜单/开关/分享面板）
// 只能在真机或模拟器上看，这里不伪造。
//
// 覆盖：规格表键唯一与默认值（续费默认 NO、诊断默认 NO）、旧版 NSString 值被尊重、
// 不合适类型（容器/日期）退默认不崩、未知 key 读取 fail-closed 且写入被拒、desired 保存后
// 同一 suite 的新 defaults 实例（**同进程可见性**，不等于已验证真实进程重启/落盘恢复）
// 能读到、已建快照不随写入改变、下一次快照读到新值、总开关/诊断/独立选项可读、
// 传输页三个新键的默认值/独立保存/快照语义（含办卡键不再是无规格表的未接线键）；
// 首页横幅容器实验键默认 NO、保存后旧快照不变/新快照可见、与旧键互不影响；
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
    @"BDRemovePersonalBanner", @"BDRemoveTaskCard", @"BDRemoveRenewButton",
    @"BDNadBlockNetwork", @"BDNadBlockAdMethods",
    @"BDRemoveTransferYikePromo", @"BDRemoveTransferGamePromo", @"BDRemoveTransferCardPromo",
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
    CHECK(BDNadPrefsSpecForKey(@"BDNadBlockEnabled")->defaultValue == YES);
    CHECK(BDNadPrefsSpecForKey(@"BDRemoveRenewButton")->defaultValue == NO);    // 续费按钮默认保留
    CHECK(BDNadPrefsSpecForKey(@"BDNadBlockDumpOnly")->defaultValue == NO);     // 默认不做仅诊断
    // 用户反馈顶部实验已去掉年卡；仍保持默认关闭、首页分组和原存储键。
    CHECK(BDNadPrefsSpecForKey(@"BDExperimentHideHomeBanner")->defaultValue == NO);
    CHECK(BDNadPrefsSpecForKey(@"BDExperimentHideHomeBanner")->group == BDNadPrefsGroupHome);
    CHECK(BDNadPrefsSpecForKey(@"BDNadBlockAdMethods")->defaultValue == YES);
    // 传输页三个新键：显式核对默认 YES 与广告分组（位次已由上面的固定清单逐位校验）。
    CHECK(BDNadPrefsSpecForKey(@"BDRemoveTransferYikePromo")->defaultValue == YES);
    CHECK(BDNadPrefsSpecForKey(@"BDRemoveTransferGamePromo")->defaultValue == YES);
    CHECK(BDNadPrefsSpecForKey(@"BDRemoveTransferCardPromo")->defaultValue == YES);
    CHECK(BDNadPrefsSpecForKey(@"BDRemoveTransferYikePromo")->group == BDNadPrefsGroupAds);
    CHECK(BDNadPrefsSpecForKey(@"BDRemoveTransferGamePromo")->group == BDNadPrefsGroupAds);
    CHECK(BDNadPrefsSpecForKey(@"BDRemoveTransferCardPromo")->group == BDNadPrefsGroupAds);
    // 默认 NO 的三个例外：续费按钮、仅诊断、以及首页横幅容器实验项（默认关闭）。
    for (NSUInteger i = 0; i < BDNadPrefsSpecCount; i++) {
        NSString *k = @(BDNadPrefsSpecs[i].key);
        if ([k isEqualToString:@"BDRemoveRenewButton"] ||
            [k isEqualToString:@"BDNadBlockDumpOnly"] ||
            [k isEqualToString:@"BDExperimentHideHomeBanner"]) continue;
        CHECK(BDNadPrefsSpecs[i].defaultValue == YES);
    }
}

int main(void) {
    @autoreleasepool {
        TestSpecTable();
        TestDefaults();

        NSString *suiteName = [@"BDNadPreferencesTest-" stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:suiteName];
        CHECK(d != nil);

        // 空 suite = 全规格默认。
        CHECK(BDNadPrefsDesired(d, @"BDNadBlockEnabled") == YES);
        CHECK(BDNadPrefsDesired(d, @"BDRemoveRenewButton") == NO);
        CHECK(BDNadPrefsDesired(d, @"BDNadBlockDumpOnly") == NO);
        CHECK(BDNadPrefsDesired(d, @"BDRemoveSearchAI") == YES);
        CHECK(BDNadPrefsDesired(nil, @"BDNadBlockEnabled") == YES);       // 冻结的 defaults 参数也不崩
        CHECK(BDNadPrefsDesired(d, nil) == NO);                           // 未知/空 key fail-closed

        // 旧版用户值（NSString）必须被尊重。
        [d setObject:@"0" forKey:@"BDRemoveGameCenter"];
        [d setObject:@"1" forKey:@"BDNadBlockNetwork"];
        [d setObject:@"true" forKey:@"BDRemoveJobNovel"];
        CHECK(BDNadPrefsDesired(d, @"BDRemoveGameCenter") == NO);
        CHECK(BDNadPrefsDesired(d, @"BDNadBlockNetwork") == YES);
        CHECK(BDNadPrefsDesired(d, @"BDRemoveJobNovel") == YES);

        // 类型不合适：退规格默认，不崩（默认都是 YES，续费确实是 NO）。
        // 数组/字典/Data 是合法 plist 值但非标量；NSDate 也是合法 plist 值但不是 bool。
        [d setObject:@[@"x"] forKey:@"BDRemoveRecommend"];
        [d setObject:@{@"x": @1} forKey:@"BDRemoveTaskCard"];
        [d setObject:[NSData dataWithBytes:"ab" length:2] forKey:@"BDRemovePersonalBanner"];
        [d setObject:[NSDate dateWithTimeIntervalSince1970:0] forKey:@"BDNadBlockEnabled"];
        [d setObject:@[@1] forKey:@"BDRemoveRenewButton"];
        CHECK(BDNadPrefsDesired(d, @"BDRemoveRecommend") == YES);
        CHECK(BDNadPrefsDesired(d, @"BDRemoveTaskCard") == YES);
        CHECK(BDNadPrefsDesired(d, @"BDRemovePersonalBanner") == YES);
        CHECK(BDNadPrefsDesired(d, @"BDNadBlockEnabled") == YES);
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
        // 其余键不受影响：实验横幅键仍是默认 NO、续费仍是默认 NO、总开关仍是默认 YES。
        CHECK(BDNadPrefsSpecForKey(@"BDExperimentHideHomeBanner")->defaultValue == NO);
        CHECK(BDNadPrefsDesired(d, @"BDExperimentHideHomeBanner") == NO);
        CHECK(BDNadPrefsDesired(d, @"BDRemoveRenewButton") == NO);
        CHECK(BDNadPrefsDesired(d, @"BDNadBlockEnabled") == YES);

        // 写入 owned key 才成功。
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
        CHECK(BDNadPrefsDesired(reopened, @"BDRemoveJobNovel") == YES);
        CHECK(BDNadPrefsDesired(reopened, @"BDRemoveSearchPromo") == YES);
        CHECK(BDNadPrefsDesired(reopened, @"BDRemovePersonalPromotions") == YES);
        CHECK(BDNadPrefsDesired(reopened, @"BDNadBlockAdMethods") == YES);
        CHECK(BDNadPrefsDesired(reopened, @"BDRemoveAITab") == YES);

        // 传输页三个新广告键：未写过就是默认 YES，且三个互相独立。
        CHECK(BDNadPrefsDesired(reopened, @"BDRemoveTransferYikePromo") == YES);
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

        // 清理：只删本次测试 owned 的 suite，不碰真实域。
        [d removePersistentDomainForName:suiteName];
        CHECK(BDNadPrefsDesired(d, @"BDNadBlockDumpOnly") == NO);   // 删完回到规格默认（证明域确实被清）
        CHECK(BDNadPrefsDesired(d, @"BDNadBlockEnabled") == YES);
        CHECK(BDNadPrefsDesired(d, @"BDRemoveTransferYikePromo") == YES);   // 新键同样回到默认 YES
        CHECK(BDNadPrefsDesired(d, @"BDRemoveTransferCardPromo") == YES);
        CHECK(BDNadPrefsDesired(d, @"BDExperimentHideHomeBanner") == NO);   // 实验键删域后回默认「关闭」
    }

    if (gFailures == 0) {
        printf("preferences_test: all checks passed\n");
        return 0;
    }
    fprintf(stderr, "preferences_test: %d check(s) failed\n", gFailures);
    return 1;
}
