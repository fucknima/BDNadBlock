#!/usr/bin/env python3
"""核对 selector 的存在与返回类型；不证明回调、布局或业务状态安全。

用法:
    python3 scripts/verify_selectors.py /path/to/netdisk_iPhone

App 升级后重跑一次。退出码非 0 表示有 selector 失效、返回类型不安全，或 feature hook 的
类/encoding 变了，必须先更新 Tweak.xm 的 BDHookMap() 与 FeatureRemoval.h 的 BDFRSpec 表再发版。

做法（不依赖 LIEF，纯 struct 解析 Mach-O）:
    __objc_classlist[i] -> class_t
    class_t + 32        -> class_ro_t*   (低 3 位是 flag，要清掉)
    class_ro_t + 24     -> 类名
    class_ro_t + 32     -> method_list_t
    class_t + 0         -> metaclass（类方法自己的方法表，即 + 的实现所在）
    method_list_t       -> {entsizeAndFlags, count, entries...}
      entsizeAndFlags & 0x80000000 -> 相对 method list，每项 3 个 int32 偏移
      否则                         -> 绝对指针，每项 3 个 uint64
    每项的 name/types 都是相对/绝对 C 字符串指针
"""
import struct
import sys
import mmap

# 与 Tweak.xm 的 BDHookMap() 保持一致
HOOK_MAP = {
    "BDNCSplashAdvertiseWindow": [
        "showSplashWithActivityModel:",
        "showSplashWithImageURL:protocol:showAdWarn:",
    ],
    "BDNCSplashAdvertiseViewController": [
        "addSplashAdvertiseWithAdvertiseModel:",
        "addSplashWithActivityModel:",
        "addSplashWithImageURL:protocol:showAdWarn:",
        "showDetailSplashAdvertise",
    ],
    "BDNCBUAdsSplashAD": ["showAdWithViewController:"],
    "BDNCBrandSplashAd": ["showSplashViewInRootViewController:"],
    "BDNCBuAdsRewardVideoAD": ["showAd:"],
    "BDNCRewardVideoAdBaseTask": ["showAdvertise"],
    "BDNCNativeAdBaseTask": ["handleShow:"],
    "ABUSplashAd": ["showInWindow:", "showInWindowWithBlock:"],
    "ABUInterstitialAd": ["showAdFromRootViewController:"],
    "ABUInterstitialProAd": ["showAdFromRootViewController:extraInfos:"],
    "ABURewardedVideoAd": [
        "showAdFromRootViewController:",
        "showAdFromRootViewController:extraInfos:",
        "showAdFromRootViewController:extroInfos:",
    ],
}

# 精准 feature hook：替换实现，必须编码逐字节一致才装。
# encoding 一律照抄各组件的 spec 表（FeatureRemoval.h / SearchDataRemoval.h /
# SearchViewRemoval.h / MenuEntry.h），不在这里另猜；App 升级后连 spec 表一起核对。
# (类名, +/- , selector, 完整 type encoding)；+ 表示类方法，方法必须落在 metaclass 自己的方法表里。
FEATURE_HOOKS = [
    ("BHSettings", "+", "isMSHSwitchTypeHomeRecommend", "B16@0:8"),
    ("BDPanNewMSHContentViewController", "-", "tableView:numberOfRowsInSection:", "q32@0:8@16q24"),
    ("BDPanPersonalConfig", "+", "gameCenterSwitch", "B16@0:8"),
    # 首页金刚区去掉求职(13)/小说(6)：包装 +cacheKingKongsConfigArray 的最终数组。
    ("BDPanFeedHomeConfig", "+", "cacheKingKongsConfigArray", "@16@0:8"),
    # 搜索框数据层：清空服务端轮播词（唯一写入口，argv 3）。
    ("BDPanSearchManager", "-", "setStaticWordList:", "v24@0:8@16"),
    # 搜索框 UI 层：三条 post-hook，整组校验通过才装。
    ("BDPanNewMSHSearchView", "-", "setupView", "v16@0:8"),
    ("BDPanNewMSHSearchView", "-", "searchPlaceholderUpdated:", "v24@0:8@16"),
    ("BDPanNewMSHSearchView", "-", "updateConstraintsWithProgress:", "v24@0:8d16"),
    # 设置页入口按钮：两个候选类各自一条 -viewDidLoad，互不依赖。
    ("SettingConfigViewController", "-", "viewDidLoad", "v16@0:8"),
    ("SettingViewController", "-", "viewDidLoad", "v16@0:8"),
    # 底部「库库AI」tab：可见数组写入口 + 构造期上下文 + 四个索引 getter（类方法走 metaclass）。
    ("BDPanTabBarController", "-", "setTabBarItemModels:", "v24@0:8@16"),
    ("BDPanTabBarController", "-", "customTabBar", "v16@0:8"),
    ("BDTabViewController", "+", "friendsIndex", "q16@0:8"),
    ("BDTabViewController", "+", "magicTrickIndex", "q16@0:8"),
    ("BDTabViewController", "+", "findSourceIndex", "q16@0:8"),
    ("BDTabViewController", "+", "settingIndex", "q16@0:8"),
    # 「我的」活动轮播：类方法（metaclass）、B16@0:8、argc 2。
    ("BDPanPersonalConfig", "+", "bannerSwitch", "B16@0:8"),
    # 「我的」续费卡去按钮：三个 header view 各自一条 -vipButton（@16@0:8）。
    ("BDPanPersonNewVipCardHeaderView", "-", "vipButton", "@16@0:8"),
    ("BDPanPersonVipHeaderView", "-", "vipButton", "@16@0:8"),
    ("BDPanPersonAdvanceVIPHeaderView", "-", "vipButton", "@16@0:8"),
    # 「我的」推广入口整排收起：两个 section 各自的 -heightForView。
    # **double 返回（d）**，写成 @ / q 都会被判成签名不符而整条放弃。
    ("BDPanPersonalWalletSection", "-", "heightForView", "d16@0:8"),
    ("BDPanPersonalCenterWalletSection", "-", "heightForView", "d16@0:8"),
    # 「我的」积分卡：两个 section 各自的 -layoutViews（post-hook 里再摘 pointsCard）。
    ("BDPanPersonalSpaceAndPointSection", "-", "layoutViews", "v16@0:8"),
    ("BDPanPersonalSpaceSection", "-", "layoutViews", "v16@0:8"),
    # 热启动空白开屏：只改「该不该展示」这一步的 bool。自有实例方法，
    # self/_cmd + q + @ + @（argc 5，运行期仍由 installer 用 method_getNumberOfArguments 兜底）。
    ("BDNCUIAdvertisesManage", "-", "needToShowSplashWithLaunchType:launchUrl:launchOptions:",
     "B40@0:8q16@24@32"),
    # 传输页推广：一刻相册 gate 有两个宿主类（各自独立安装），下载小游戏引导在 manager 上；
    # 三条都是 B16@0:8、argc 2 的自有实例方法。
    ("BDPanTransViewController", "-", "canShowYikeBanner", "B16@0:8"),
    ("BDPanTransferFileTransListViewController", "-", "canShowYikeBanner", "B16@0:8"),
    ("BDPanTransIdleGameManager", "-", "canTransIdleGameWidgetShow", "B16@0:8"),
]

# **依赖** accessor：hook 自己不发消息，是安装前只读校验的对象（校验不过就整条跳过）。
# 同样要求完整 encoding 一致 —— 它变了，过滤逻辑就会按错误布局读 id 或错调清空路径。
FEATURE_DEPS = [
    # H4 的依赖：-kingKongId 是 q16@0:8。
    ("BDPanFHKingKongsModel", "-", "kingKongId", "q16@0:8"),
    # 搜索框三条 post-hook 的 getter 依赖：全部 @16@0:8（id 返回）。
    ("BDPanNewMSHSearchView", "-", "searchButton", "@16@0:8"),
    ("BDPanNewMSHSearchView", "-", "scrollLabel", "@16@0:8"),
    ("BDPanNewMSHSearchView", "-", "scrollLabelConfig", "@16@0:8"),
    ("BDPanNewMSHSearchView", "-", "genflowButton", "@16@0:8"),
    ("BDPanNewMSHSearchView", "-", "genflowAnimationView", "@16@0:8"),
    ("BDPanNewMSHSearchView", "-", "cameraButton", "@16@0:8"),
    ("BDPanNewMSHSearchView", "-", "cameraButtonAnimateBackground", "@16@0:8"),
    # 轮播清理的清空路径：这两个是 **void 返回**（v24@0:8@16），不是 @ 返回 ——
    # 写成 @ 返回会误判成「宿主签名不符」而整组放弃。
    ("BDPanVerticalScrollLableViewConfig", "-", "setTexts:", "v24@0:8@16"),
    ("BDPanVerticalScrollLableView", "-", "configWithLabelConfig:", "v24@0:8@16"),
    # 底部 tab 过滤的判据依赖：只读 itemTabName。itemType 已从判据里去掉
    # （它不是 AI 专属：未登录 tab bar 就把 1 赋给了 shared_page），所以不再作为依赖校验。
    ("BDTabItemModel", "-", "itemTabName", "@16@0:8"),
    # 稳态取图用的 active root 读取器：类方法在 metaclass 上，@16@0:8、argc 2。
    # 不校验就等于对第三方类裸 objc_msgSend，宿主升级改名会直接崩。
    ("AppDelegate", "+", "ad_curTabBarController", "@16@0:8"),
    # 积分卡 post-hook 的 getter 依赖：两个 section 各自的 -pointsCard（@16@0:8）。
    ("BDPanPersonalSpaceAndPointSection", "-", "pointsCard", "@16@0:8"),
    ("BDPanPersonalSpaceSection", "-", "pointsCard", "@16@0:8"),
]

# no-op 只保证 x0 有效。返回结构体/浮点/复数的方法调用方会读 s0/x1/v0 —— 垃圾。
SAFE_RETURN = set("v@#:BcCsSiIlLqQ^*")

LC_SEGMENT_64 = 0x19


def entry_addresses(mm, fileoff, vmaddr, flags, u64):
    if flags & 0x80000000:
        name_offset, type_offset = struct.unpack_from('<ii', mm, fileoff)
        name_ptr = vmaddr + name_offset
        if not flags & 0x40000000:
            name_ptr = u64(name_ptr) or 0
        return name_ptr, vmaddr + 4 + type_offset
    return u64(vmaddr), u64(vmaddr + 8)


def method_list(mm, vm2off, u32, u64, cstr, ml):
    """读一个 method_list_t -> {selector: type encoding}。"""
    out = {}
    if not ml:
        return out
    ef, cnt = u32(ml), u32(ml + 4)
    if ef is None or cnt is None or cnt > 20000:
        return out
    # objc4 method_list_t::smallMethodListFlag；低两位是 fixup 标记。
    entsize, relative = ef & 0xFFFC, bool(ef & 0x80000000)
    for k in range(cnt):
        ep = ml + 8 + k * entsize
        po = vm2off(ep)
        if po is None:
            continue
        if relative and entsize >= 12:
            name_ptr, type_ptr = entry_addresses(mm, po, ep, ef, u64)
        elif entsize >= 24:
            name_ptr, type_ptr = entry_addresses(mm, po, ep, ef, u64)
        else:
            continue
        sel, enc = cstr(name_ptr), cstr(type_ptr)
        if sel:
            out[sel] = enc
    return out


def class_ro(u64, cls):
    data = u64(cls + 32)
    return (data & ~0x7) if data else 0


def class_name(u64, cstr, cls):
    ro = class_ro(u64, cls)
    return cstr(u64(ro + 24) or 0) if ro else None


def own_methods(mm, vm2off, u32, u64, cstr, cls):
    """class_t **自己**（不沿继承链）的方法 -> {selector: encoding}。

    类方法要传 metaclass（class_t + 0 是 isa）：本脚本核对的就是运行时
    class_copyMethodList 看到的那张表，继承来的实现不在这里。
    """
    ro = class_ro(u64, cls)
    return method_list(mm, vm2off, u32, u64, cstr, u64(ro + 32)) if ro else {}


def selftest():
    data = bytearray(256)
    struct.pack_into('<ii', data, 32, 64, 92)
    struct.pack_into('<Q', data, 96, 192)
    read_pointer = lambda p: struct.unpack_from('<Q', data, p)[0]
    assert entry_addresses(data, 32, 32, 0x8000000C, read_pointer) == (192, 128)
    assert entry_addresses(data, 32, 32, 0xC000000C, read_pointer) == (96, 128)
    struct.pack_into('<QQ', data, 32, 192, 128)
    assert entry_addresses(data, 32, 32, 24, read_pointer) == (192, 128)
    print('method_list_t 相对/直接/绝对三种解析检查通过')

    # class_t -> ro -> 自己方法表（绝对编码），外加 class_t.isa 上的 metaclass 及其自己的方法表。
    # 本测试里地址即偏移；所有字符串都用等长 slice 写入并带 \0，避免改变 bytearray 长度。
    img = bytearray(1024)
    rd_u32 = lambda a: struct.unpack_from('<I', img, a)[0]
    rd_u64 = lambda a: struct.unpack_from('<Q', img, a)[0]
    def rd_cstr(a):
        end = img.find(b'\0', a)
        return img[a:end].decode() if end >= 0 else None
    def vm2off(a):
        return a if 0 <= a < len(img) else None
    struct.pack_into('<Q', img, 64, 320)               # class_t.isa -> metaclass
    struct.pack_into('<Q', img, 64 + 32, 128 | 3)      # class_t.data = ro | flag
    struct.pack_into('<Q', img, 128 + 24, 512)         # ro.name
    struct.pack_into('<Q', img, 128 + 32, 176)         # ro.baseMethodList
    struct.pack_into('<II', img, 176, 24, 1)           # 绝对表，entsize 24，1 项
    struct.pack_into('<QQQ', img, 184, 528, 544, 0)    # name / type / imp
    struct.pack_into('<Q', img, 320 + 32, 384 | 3)     # metaclass.data = ro | flag
    struct.pack_into('<Q', img, 384 + 24, 560)         # metaclass ro.name
    struct.pack_into('<Q', img, 384 + 32, 432)         # metaclass ro.baseMethodList
    struct.pack_into('<II', img, 432, 24, 1)
    struct.pack_into('<QQQ', img, 440, 576, 592, 0)
    img[512:522] = b'BDFRFake\0\0'
    img[528:536] = b'bsel\0\0\0\0'
    img[544:554] = b'B16@0:8\0\0\0'
    img[560:570] = b'BDFRMeta\0\0'
    img[576:584] = b'mbool\0\0\0'
    img[592:602] = b'B16@0:8\0\0\0'
    assert len(img) == 1024                            # 等长写入，地址没有漂移
    assert class_ro(rd_u64, 64) == 128
    assert class_name(rd_u64, rd_cstr, 64) == 'BDFRFake'
    assert own_methods(img, vm2off, rd_u32, rd_u64, rd_cstr, 64) == {'bsel': 'B16@0:8'}
    meta = rd_u64(64)                                  # class_t.isa
    assert class_name(rd_u64, rd_cstr, meta) == 'BDFRMeta'
    assert own_methods(img, vm2off, rd_u32, rd_u64, rd_cstr, meta) == {'mbool': 'B16@0:8'}
    print('class_t/class_ro_t/自己方法表（含 class_t.isa 上的 metaclass 方法表）解析检查通过')


def main(path):
    f = open(path, "rb")
    mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
    fsize = len(mm)

    if struct.unpack_from("<I", mm, 0)[0] != 0xFEEDFACF:
        sys.exit("不是 64 位 little-endian Mach-O")

    sections, off = [], 32
    for _ in range(struct.unpack_from("<I", mm, 16)[0]):
        cmd, cmdsize = struct.unpack_from("<II", mm, off)
        if cmd == LC_SEGMENT_64:
            for i in range(struct.unpack_from("<I", mm, off + 64)[0]):
                p = off + 72 + i * 80
                sections.append((mm[p:p + 16].split(b"\0")[0].decode(),
                                 struct.unpack_from("<Q", mm, p + 32)[0],
                                 struct.unpack_from("<Q", mm, p + 40)[0],
                                 struct.unpack_from("<I", mm, p + 48)[0]))
        off += cmdsize

    def vm2off(addr):
        for _n, va, sz, fo in sections:
            if va <= addr < va + sz:
                return fo + (addr - va)
        return None

    def u32(a):
        p = vm2off(a)
        return struct.unpack_from("<I", mm, p)[0] if p is not None else None

    def u64(a):
        p = vm2off(a)
        return struct.unpack_from("<Q", mm, p)[0] if p is not None else None

    def cstr(a):
        p = vm2off(a)
        if p is None:
            return None
        e = mm.find(b"\0", p, min(p + 1024, fsize))
        return mm[p:e].decode("utf-8", "replace") if e >= 0 else None

    secmap = {}
    for n, va, sz, fo in sections:
        secmap.setdefault(n, (va, sz, fo))
    if "__objc_classlist" not in secmap:
        sys.exit("找不到 __objc_classlist —— 可能被加固剥离了 ObjC 元数据")

    # 一次扫完 classlist，收集两边要用的类（不引入第二个解析器）。
    need = set(HOOK_MAP) | {h[0] for h in FEATURE_HOOKS} | {h[0] for h in FEATURE_DEPS}
    classes = {}
    _va, size, foff = secmap["__objc_classlist"]
    for i in range(size // 8):
        cls = struct.unpack_from("<Q", mm, foff + i * 8)[0]
        if not cls:
            continue
        name = class_name(u64, cstr, cls)
        if name in need:
            classes[name] = cls

    got = {n: own_methods(mm, vm2off, u32, u64, cstr, c)
           for n, c in classes.items() if n in HOOK_MAP}

    bad = 0
    print(f"{'返回类型':<11} {'判定':<5} 类 / selector")
    print("-" * 76)
    for cls, sels in HOOK_MAP.items():
        for sel in sels:
            enc = (got.get(cls) or {}).get(sel)
            if enc is None:
                print(f"{'—':<11} {'缺失':<5} {cls}  -{sel}")
                bad += 1
                continue
            ok = enc[0] in SAFE_RETURN
            if not ok:
                bad += 1
            print(f"{enc[:10]:<11} {'OK' if ok else '不安全':<5} {cls}  -{sel}")

    # feature hook：要替换实现，所以只认「本类自己的方法表 + 完整 encoding 一致」。
    print()
    print("feature hook（替换实现；+ 走 metaclass 自己的方法表，继承来的不算）")
    print("-" * 76)
    for cls, kind, sel, enc in FEATURE_HOOKS:
        target = classes.get(cls)
        if target is None:
            actual = "类缺失"
        else:
            # 类方法的实现落在 metaclass：class_t + 0 是 isa
            actual = own_methods(mm, vm2off, u32, u64, cstr,
                                 u64(target) if kind == "+" else target).get(sel)
            if actual is None:
                actual = "不在本类自己的方法表"
        ok = actual == enc
        if not ok:
            bad += 1
        print(f"{kind}{cls}  {sel}")
        print(f"{'':<2}{'OK' if ok else '不一致':<6} 期望 {enc} 实际 {actual}")

    # feature hook 的依赖 accessor：只读校验，同样要求完整 encoding 一致。
    print()
    print("feature hook 依赖（安装前只读校验；hook 自己不发消息，依赖不符整条跳过）")
    print("-" * 76)
    for cls, kind, sel, enc in FEATURE_DEPS:
        target = classes.get(cls)
        if target is None:
            actual = "类缺失"
        else:
            actual = own_methods(mm, vm2off, u32, u64, cstr,
                                 u64(target) if kind == "+" else target).get(sel)
            if actual is None:
                actual = "不在本类自己的方法表"
        ok = actual == enc
        if not ok:
            bad += 1
        print(f"{kind}{cls}  {sel}")
        print(f"{'':<2}{'OK' if ok else '不一致':<6} 期望 {enc} 实际 {actual}")

    print("-" * 76)
    total = sum(len(v) for v in HOOK_MAP.values())
    print(f"{total} 个广告 selector + {len(FEATURE_HOOKS)} 个 feature hook"
          f" + {len(FEATURE_DEPS)} 个依赖，{bad} 个有问题")
    return 1 if bad else 0


if __name__ == "__main__":
    if sys.argv[1:] == ['--selftest']:
        selftest()
        sys.exit(0)
    if len(sys.argv) != 2:
        sys.exit(f"用法: {sys.argv[0]} /path/to/netdisk_iPhone")
    sys.exit(main(sys.argv[1]))
