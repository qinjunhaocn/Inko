#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Inko · 水印资源目录生成器
=========================

输入（全部来自 Insta360 2.32.1 APK，逆向所得）
  assets_src/share_config/Watermark_Config_Table.txt        视频水印位置表（7650 行）
  assets_src/share_config/Image_Watermark_Config_Table.txt  照片水印位置表（1181 行）
  assets/watermark/*.png                                    水印图层（160 张）

输出
  assets/config/watermark_catalog.json

配置表键格式： "机型##样式##比例##位置"
配置表值格式： "水印宽度##水印横坐标##水印纵坐标"
    三者均为归一化值；横坐标自左向右，纵坐标自下向上（左下原点）。
    样式带 -CN / -TW 后缀者为对应语言的独立条目。

图层解析规则（对应 ParamsUtils#getWatermarkResourcesPathForVideo / ForImage）：
    语言后缀  简体 _cn / 繁体 _hk / 其它 无后缀
    照片图层  视频图层基名 + "_image"
    位置切分  自适应色调 / GO Ultra 默认图层按位置取 _left / _center / _right
"""

import json
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PNG_DIR = os.path.join(ROOT, "assets", "watermark")
OUT = os.path.join(ROOT, "assets", "config", "watermark_catalog.json")
SRC = os.path.join(os.path.dirname(ROOT), "assets_src", "share_config")

MODELS = [
    dict(id="X4",        rect_key="X4",        name="X4",         family="X4 系列"),
    dict(id="X5",        rect_key="X5",        name="X5",         family="X5 系列"),
    dict(id="X6",        rect_key="X6",        name="X6",         family="X6 系列"),
    dict(id="X4 Air",    rect_key="X4 Air",    name="X4 Air",     family="X4 系列"),
    dict(id="X3",        rect_key="X3",        name="X3",         family="X3 系列"),
    dict(id="X2",        rect_key="X2",        name="X2",         family="X3 系列"),
    dict(id="OneX",      rect_key="OneX",      name="ONE X",      family="ONE 系列"),
    dict(id="OneR",      rect_key="OneR",      name="ONE R",      family="ONE 系列"),
    dict(id="OneRS",     rect_key="OneRS",     name="ONE RS",     family="ONE 系列"),
    dict(id="Go2",       rect_key="Go2",       name="GO 2",       family="GO 系列"),
    dict(id="Go3",       rect_key="Go3",       name="GO 3",       family="GO 系列"),
    dict(id="Go3S",      rect_key="Go3S",      name="GO 3S",      family="GO 系列"),
    dict(id="Go Ultra",  rect_key="Go Ultra",  name="GO Ultra",   family="GO 系列"),
    dict(id="Luna Ultra",rect_key="Luna Ultra",name="Luna Ultra", family="Luna 系列"),
    dict(id="Luna Pro",  rect_key="Luna Pro",  name="Luna Pro",   family="Luna 系列"),
    dict(id="Flow",      rect_key="Flow",      name="Flow",       family="Flow 系列"),
    dict(id="Flow Pro",  rect_key="Flow Pro",  name="Flow Pro",   family="Flow 系列"),
    dict(id="Flow 2",    rect_key="Flow 2",    name="Flow 2",     family="Flow 系列"),
    dict(id="Flow 2 Pro",rect_key="Flow 2 Pro",name="Flow 2 Pro", family="Flow 系列"),
    dict(id="Ace",       rect_key="Ace",       name="Ace",        family="Ace 系列"),
    dict(id="Ace Pro",   rect_key="AcePro",    name="Ace Pro",    family="Ace 系列"),
    dict(id="Ace Pro 2", rect_key="AcePro2",   name="Ace Pro 2",  family="Ace 系列"),
    dict(id="Insta360",  rect_key="Insta360",  name="Insta360",   family="通用"),
    dict(id="Sphere",    rect_key="Sphere",    name="Sphere",     family="通用"),
    dict(id="Go",        rect_key="Go",        name="GO",         family="GO 系列"),
]

BASE_VIDEO = {
    "X4": "ic_watermark_x4",
    "X5": "ic_watermark_x5",
    "X6": "ic_watermark_x6",
    "X4 Air": "ic_watermark_x4air",
    "X3": "ic_watermark_x3",
    "X2": "ic_watermark_onex2",
    "OneX": "ic_watermark_onex",
    "OneR": "ic_watermark_oner",
    "OneRS": "ic_watermark_oners",
    "Go2": "ic_watermark_go2",
    "Go3": "ic_watermark_go3",
    "Go3S": "ic_watermark_go3s",
    "Go Ultra": "ic_watermark_go_ultra",
    "Luna Ultra": "ic_watermark_luna_ultra",
    "Luna Pro": "ic_watermark_luna_pro",
    "Flow": "ic_watermark_flow",
    "Flow Pro": "ic_watermark_flow_pro",
    "Flow 2": "ic_watermark_flow2",
    "Flow 2 Pro": "ic_watermark_flow2_pro",
    "Ace": "ic_watermark_iac1",
    "Ace Pro": "ic_watermark_iac2",
    "Ace Pro 2": "ic_watermark_iac3",
    "Insta360": "ic_watermark_default",
    "Sphere": "ic_watermark_default",
    "Go": "ic_watermark_default",
}

BASE_IMAGE_OVERRIDE = {"X4 Air": "ic_watermark_x4_air_image"}

STYLE_VIDEO = {
    "Leica": {"OneR": "ic_watermark_oner_leica", "OneRS": "ic_watermark_oners_leica"},
    "Minions": {"Go2": "ic_watermark_go2_minions"},
    "retro": {"Go3S": "ic_watermark_go3s_retro"},
    "pogacar": {"Go Ultra": "ic_watermark_go_ultra_pogacar"},
    "hellokitty": {"Go Ultra": "ic_watermark_go_ultra_hellokitty"},
    "hellokitty-cat": {"Go Ultra": "ic_watermark_go_ultra_hellokitty"},
    "momentpro-common": {"Insta360": "ic_watermark_momentsPro"},
    "adaptivetone": {
        "X5": "ic_watermark_adaptivetone",
        "X6": "ic_watermark_x6_adaptivetone",
        "X4 Air": "ic_watermark_x4air_adaptivetone",
        "Go Ultra": "ic_watermark_go_ultra",
    },
}

IMAGE_LANG_LOCKED = {"Flow", "Flow Pro", "Flow 2", "Flow 2 Pro"}

STYLE_LABELS = {
    "Normal": "标准",
    "Leica": "徕卡", "Leica-horse": "徕卡 · 马年", "Leica-newyear": "徕卡 · 新年",
    "Minions": "小黄人", "retro": "复古",
    "horse": "马年", "newyear": "新年", "valentine": "情人节",
    "babyboy": "男宝", "babygirl": "女宝",
    "pogacar": "波加查", "hellokitty": "Hello Kitty", "hellokitty-cat": "Hello Kitty",
    "adaptivetone": "自适应色调",
    "BMWmotorrad": "BMW Motorrad", "CFmoto": "CFMOTO",
    "momentpro-common": "Moment Pro", "P3": "P3", "ZStyle": "Z 风格",
    "goforlove-border": "为爱出发", "capturelove-border": "定格爱",
    "youaremyace-border": "我的王牌", "valentine-border": "情人节",
}

LANG_ORDER = ["en", "cn", "hk"]
LANG_SUFFIX = {"en": "", "cn": "_cn", "hk": "_hk"}
RATIO_ORDER = ["16:9", "9:16", "1:1", "4:3", "3:4", "3:2", "2:3",
               "47:20", "20:47", "27:10", "10:27", "235:100", "100:235",
               "3:1", "1:3", "4:1", "1:4", "39:18", "18:39", "2:1", "1:2"]
POSITIONS = ["BottomRight", "BottomLeft", "TopRight", "TopLeft", "BottomCenter"]

_exist_cache = {}


def exists(name):
    if name not in _exist_cache:
        _exist_cache[name] = os.path.exists(os.path.join(PNG_DIR, name + ".png"))
    return _exist_cache[name]


def png_size(name):
    path = os.path.join(PNG_DIR, name + ".png")
    if not os.path.exists(path):
        return None
    with open(path, "rb") as f:
        head = f.read(26)
    if head[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    return list(struct.unpack(">II", head[16:24]))


def base_style(key):
    for suffix in ("-CN", "-TW"):
        if key.endswith(suffix):
            return key[: -len(suffix)]
    return key


def reshape(raw):
    out = {}
    for key, val in raw.items():
        parts = key.split("##")
        if len(parts) != 4:
            continue
        try:
            nums = [float(x) for x in val.split("##")]
        except ValueError:
            continue
        if len(nums) != 3:
            continue
        model, style, ratio, pos = parts
        out.setdefault(model, {})[f"{style}##{ratio}##{pos}"] = nums
    return out


def resolve(base, lang, positional=False, side=""):
    """解析实际存在的 PNG 基名，返回 (name or None, degraded)"""
    suffix = LANG_SUFFIX[lang]
    mid = f"_{side}" if positional else ""
    target = base + mid + suffix
    if exists(target):
        return target, False
    fallback = base + mid
    if exists(fallback):
        return fallback, True
    return None, False


def main():
    with open(os.path.join(SRC, "Watermark_Config_Table.txt"), encoding="utf-8") as f:
        video_tbl = reshape(json.load(f))
    with open(os.path.join(SRC, "Image_Watermark_Config_Table.txt"), encoding="utf-8") as f:
        photo_tbl = reshape(json.load(f))

    all_ratios = set()
    for table in (video_tbl, photo_tbl):
        for rows in table.values():
            for key in rows:
                all_ratios.add(key.split("##")[1])
    ratios = [r for r in RATIO_ORDER if r in all_ratios]
    ratios += sorted(r for r in all_ratios if r not in ratios)

    models_out = []
    for model in MODELS:
        mid = model["id"]
        vrows = video_tbl.get(model["rect_key"], {})
        prows = photo_tbl.get(model["rect_key"], {})
        if not vrows and not prows:
            print(f"  ! {mid}: 配置表无条目，跳过", file=sys.stderr)
            continue

        groups = {}
        for table in (vrows, prows):
            for key in table:
                style = key.split("##")[0]
                groups.setdefault(base_style(style), set()).add(style)

        styles_out = []
        for name in sorted(groups, key=lambda n: (0 if n == "Normal" else 1, n)):
            variants = groups[name]
            base_video = STYLE_VIDEO.get(name, {}).get(mid) or BASE_VIDEO[mid]
            base_image = BASE_IMAGE_OVERRIDE.get(mid) or (base_video + "_image")
            positional = name == "adaptivetone" or (mid == "Go Ultra" and name == "Normal")

            lang_map = {}
            dims = {}
            for lang in LANG_ORDER:
                if lang == "en":
                    rect_key = name if name in variants else None
                else:
                    rect_key = f"{name}-CN" if f"{name}-CN" in variants else (
                        name if name in variants else None)
                if rect_key is None:
                    continue

                png, degraded = resolve(base_video, lang, positional, "center")
                if png is None:
                    continue
                # 中文必须有 _cn 图层、繁体必须有 _hk 图层，否则对该语言隐藏此样式
                if lang == "cn" and "_cn" not in png:
                    continue
                if lang == "hk" and "_hk" not in png:
                    continue

                img_lang = "en" if mid in IMAGE_LANG_LOCKED else lang
                img, _ = resolve(base_image, img_lang)
                lang_map[lang] = {"rect": rect_key, "image": img, "degraded": degraded}

                for candidate in (base_video, base_image):
                    sides = ("left", "center", "right") if positional else ("",)
                    for s in sides:
                        probe = candidate + (f"_{s}" if s else "") + LANG_SUFFIX[lang]
                        size = png_size(probe)
                        if size:
                            dims[probe] = size

            if not lang_map:
                continue

            styles_out.append({
                "id": name,
                "label": STYLE_LABELS.get(name, name),
                "positional": positional,
                "videoBase": base_video,
                "imageBase": base_image,
                "langs": lang_map,
                "dims": dims,
            })

        if not styles_out:
            continue

        models_out.append({
            "id": mid,
            "name": model["name"],
            "family": model["family"],
            "styles": styles_out,
            "rectsVideo": vrows,
            "rectsPhoto": prows,
        })

    catalog = {
        "schema": 1,
        "source": "Insta360 2.32.1 · assets/share_config + assets/watermark",
        "languages": LANG_ORDER,
        "languageNames": {"en": "English", "cn": "简体中文", "hk": "繁體中文"},
        "positions": POSITIONS,
        "photoPosition": "BottomCenter",
        "ratios": ratios,
        "models": models_out,
    }

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(catalog, f, ensure_ascii=False, separators=(",", ":"))

    print(f"机型 {len(models_out)} / 比例 {len(ratios)} / 目录 {os.path.getsize(OUT)/1024:.0f} KB")
    for model in models_out:
        tags = " ".join(f"{s['id']}[{''.join(sorted(s['langs']))}]" for s in model["styles"])
        print(f"  {model['id']:11s} 行 {len(model['rectsVideo']):4d}/{len(model['rectsPhoto']):3d}  {tags}")


if __name__ == "__main__":
    main()
