#!/usr/bin/env python3
"""核对 BDHookMap 里的每个 selector 是否真实存在、返回类型是否可安全 no-op。

用法:
    python3 scripts/verify_selectors.py /path/to/netdisk_iPhone

App 升级后重跑一次。退出码非 0 表示有 selector 失效或返回类型不安全，
必须先更新 Tweak.xm 的 BDHookMap 再发版。

做法（不依赖 LIEF，纯 struct 解析 Mach-O）:
    __objc_classlist[i] -> class_t
    class_t + 32        -> class_ro_t*   (低 3 位是 flag，要清掉)
    class_ro_t + 24     -> 类名
    class_ro_t + 32     -> method_list_t
    method_list_t       -> {entsizeAndFlags, count, entries...}
      entsizeAndFlags & 3 == 3 -> 相对 method list，每项 3 个 int32 偏移
      否则                     -> 绝对指针，每项 3 个 uint64
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

# no-op 只保证 x0 有效。返回结构体/浮点/复数的方法调用方会读 s0/x1/v0 —— 垃圾。
SAFE_RETURN = set("v@#:BcCsSiIlLqQ^*")

LC_SEGMENT_64 = 0x19


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

    want = {c: set(s) for c, s in HOOK_MAP.items()}
    got = {}
    _va, size, foff = secmap["__objc_classlist"]
    for i in range(size // 8):
        cls = struct.unpack_from("<Q", mm, foff + i * 8)[0]
        if not cls:
            continue
        data = u64(cls + 32)
        if not data:
            continue
        ro = data & ~0x7                      # 清掉低 3 位 flag
        name = cstr(u64(ro + 24) or 0)
        if name not in want:
            continue
        ml = u64(ro + 32)
        if not ml:
            continue
        ef, cnt = u32(ml), u32(ml + 4)
        if ef is None or cnt is None or cnt > 20000:
            continue
        entsize, relative = ef & 0xFFFC, (ef & 0x3) == 0x3
        for k in range(cnt):
            ep = ml + 8 + k * entsize
            po = vm2off(ep)
            if po is None:
                continue
            if relative and entsize >= 12:
                noff, toff = struct.unpack_from("<ii", mm, po)
                sel, enc = cstr(ep + noff), cstr(ep + toff)
            elif entsize >= 24:
                sel, enc = cstr(u64(ep)), cstr(u64(ep + 8))
            else:
                continue
            if sel in want[name]:
                got.setdefault(name, {})[sel] = enc

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

    print("-" * 76)
    total = sum(len(v) for v in HOOK_MAP.values())
    print(f"{total} 个 selector，{bad} 个有问题")
    return 1 if bad else 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(f"用法: {sys.argv[0]} /path/to/netdisk_iPhone")
    sys.exit(main(sys.argv[1]))
