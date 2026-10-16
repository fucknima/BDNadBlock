// SearchDataRemoval.h — 搜索框轮播词的数据层清理（Foundation only）
//
// 目标：首页搜索框的服务端轮播词（推广词 + AI 功能提示词）整体去掉。
// 用户已明确选择「全部轮播词都去掉」，因此不做 sourceType 分类，也不做文本匹配。
//
// 唯一 hook：
//   -[BDPanSearchManager setStaticWordList:]   v24@0:8@16   argc 3
// 该方法是 -_staticWordList（ivar offset 0x40）的唯一写入口：
// 服务端 /recommend/searchbox/bottom 的词先经 storeRequestStaticWordList: 落盘，
// 再由 staticWordManager_setupStaticWordList 组装后写进来；搜索框轮播与点击取词
// 都只读 -searchStaticWordList，所以在这里清空即对所有消费方一致生效。
//
// 行为约定：
//   - 开关开（总开 && !诊断 && BDRemoveSearchPromo）且入参是非空 NSArray -> 交给原 setter 一个 @[]。
//   - nil / 空数组 / 非数组 / 任一开关关闭 -> 原对象原样透传，参数与调用次数都不变。
//   - 原 setter 每个入参调用一次，绝不交换 IMP，绝不递归。
//   - 只在「真的把非空列表清空」时打一行首次 hit 日志。
//   - 不写偏好、不写 App 缓存、不碰 storeRequestStaticWordList: 的落盘数据。
//
// 依赖（本文件被 Tweak.xm 与 tests/search_data_test.mm include，需要同名静态函数）：
//   BDLog / BDEnabled / BDDumpOnly / BDRemoveSearchPromo
// 其中 BDRemoveSearchPromo 由 Tweak.xm 定义为
//   static BOOL BDRemoveSearchPromo(void) { return BDNadPrefsActive(@"BDRemoveSearchPromo"); }
// 读的是进程启动时的只读快照，不热改。
//
// 安装器（BDFRSpec / BDFRResolve / BDFRCanAttach / BDFRAttach / BDFRInstallSpec /
// BDFRSuppressed）复用 FeatureRemoval.h，本文件不复制；include 时必须放在 FeatureRemoval.h 之后。
//
// 注意：本文件（以及任何被 Tweak.xm include 的文件）里不要出现连续的 斜杠星号 或 星号斜杠，
// 哪怕在 // 行注释里也不行 —— Theos 的 Logos 预处理器会把它当块注释，吞掉后面的代码。

#ifndef BDNAD_SEARCH_DATA_REMOVAL_H
#define BDNAD_SEARCH_DATA_REMOVAL_H

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#pragma mark - typed 替换实现

// v24@0:8@16 的替换实现用 void 返回（v 编码），与手写 encoding 对齐。
typedef void (*BDSRSetWordsIMP)(id, SEL, id);

static IMP BDSROrigSetStaticWordList;      // -[BDPanSearchManager setStaticWordList:]
static dispatch_once_t BDSRHitStaticWordList;

static void BDSRSetStaticWordList(id self, SEL _cmd, id words) {
    // 门与入参检查都在这里做：只处理「非空 NSArray」这一种情况，其余全部原样透传。
    if (BDEnabled() && !BDDumpOnly() && BDRemoveSearchPromo() &&
        [words isKindOfClass:[NSArray class]] && ((NSArray *)words).count > 0) {
        words = @[];                       // immutable 空数组，交给原 setter
        BDFRSuppressed(&BDSRHitStaticWordList, "search-promo-staticword", YES);
    }
    ((BDSRSetWordsIMP)BDSROrigSetStaticWordList)(self, _cmd, words);
}

#pragma mark - spec 与安装器

static BDFRSpec BDSRSpecStaticWordList = {
    "BDPanSearchManager", "setStaticWordList:", NO, "v24@0:8@16", 3,
    (IMP)BDSRSetStaticWordList, &BDSROrigSetStaticWordList, "search-promo-staticword", NO,
};

// 接线：Tweak.xm 在 FeatureRemoval.h 之后 include 本文件，并在启动安装阶段调一次。
static void BDSRInstallData(void) {
    BDFRInstallSpec(&BDSRSpecStaticWordList);
}

#endif // BDNAD_SEARCH_DATA_REMOVAL_H