# Inko

给照片和视频加上 **Insta360 机型水印** 的 Android 应用。

水印图层、尺寸公式、混合方式全部取自 Insta360 官方 App（2.32.1）本身，
默认参数下与原 App 逐像素对齐；在此之上允许自由换机型、换样式、改位置、微调大小。

---

## 一、和原 App 对齐的三件事

### 1. 图层是原 App 的原始资源

`assets/watermark/` 下 160 张 PNG 全部来自官方 App 的 `assets/watermark/`，
没有重绘、没有压缩、没有改色。中文版（`_cn`）、繁体版（`_hk`）、
联名版（徕卡 / 小黄人 / 复古 / 波加查 / Hello Kitty）都是原图。

### 2. 位置与尺寸用原 App 的公式

配置表 `Watermark_Config_Table.txt`（7650 行）与
`Image_Watermark_Config_Table.txt`（1181 行）已转成
`assets/config/watermark_catalog.json`，运行时直接查表。

对应原生方法 `WatermarkUtilsKt#getWatermarkRectReal`：

```
w = round2(r[0] * 画面宽)          // 水印宽度
h = round2(w * PNG高 / PNG宽)      // 高度由宽高比推出，永不变形
x = round2(r[1] * 画面宽)          // 左边缘
y = round2(r[2] * 画面高)          // 距画面底部的距离（指向水印下边缘）
top = 画面高 - y - h
round2(v) = (round(v) / 2) * 2     // Java 整数除法：四舍五入后向下取偶
```

要点：**配置表的纵坐标以画面左下角为原点**，指向水印矩形的**下边缘**。
列坐标不自底向上换算，就会整体偏移一个水印高度。

例：X4 · 16:9 · 右下 `0.109##0.858##0.059`，3840×2160 得到
`418×58 @ (3294, 1976)`，下边距 126px，右边缘 3712px。

### 3. 混合方式与原 App 同源

原 App 的 `watermark_filter` 滤镜在 `libarvbmg.so` 里是一段片元着色器：

```glsl
watermarkTexcoord = vec2((texcoord.x - left) / (right - left),
                         (top - texcoord.y) / (top - bottom));
fragColor = vec4(mix(color.xyz, wm.xyz, vec3(wm.a)), color.w);
```

就是直通 alpha 的 source-over，没有预乘、没有加色。所以：

* **照片 / 预览**：用 Flutter Canvas 的 `drawImageRect`，数学上与上面两行完全等价；
* **视频导出**：解码帧在 GPU 上是 external texture，只能交给原生 GL，
  于是把 `lib/render/water_kernel.dart` 里的着色器**原样传给原生编译**——
  两条路径共用同一份源码，不是两份实现。

---

## 二、能做什么

| 项目 | 范围 |
|---|---|
| 机型 | 25 个：X4 / X5 / X6 / X4 Air / X3 / X2 / ONE X / ONE R / ONE RS / GO 2 / GO 3 / GO 3S / GO Ultra / Luna Ultra / Luna Pro / Flow 系列 / Ace 系列 / Insta360 / Sphere / GO |
| 样式 | 标准、徕卡、小黄人、复古、波加查、Hello Kitty、自适应色调，以及各机型的联名变体 |
| 图层语言 | 简体中文 / 繁體中文 / English（按实际存在的图层开放） |
| 比例 | 配置表里真实存在的 18 种，默认按画面宽高比自动吸附 |
| 位置 | 右下 / 左下 / 右上 / 左上 / 底部居中（照片与原 App 一致，固定底部居中） |
| 微调 | 缩放 40%–200%、不透明度 10%–100%，默认 100% 即与原 App 一致 |

视频导出保留原分辨率与帧率，音轨原样搬运不重编码。

---

## 三、代码结构

```
lib/
  data/catalog.dart        配置表加载、比例吸附、图层解析
  data/settings.dart       当前选择
  render/geometry.dart     水印矩形计算（round2 / 左下原点）
  render/compositor.dart   照片合成与编码
  render/water_kernel.dart 混合着色器（唯一源码，照片/预览/视频共用）
  platform/media_bridge.dart  与原生通信
  ui/                      首页、编辑器、机型选择器
android/app/src/main/kotlin/com/voxyn/Inko/
  MainActivity.kt          MethodChannel / EventChannel
  MediaSaver.kt            写入系统相册（MediaStore）
  VideoPipeline.kt         MediaCodec 解码 → GL 混合 → 编码，音轨直通
tools/build_catalog.py     从原 App 的配置表 + PNG 生成 watermark_catalog.json
assets/
  watermark/               160 张原始水印图层
  config/watermark_catalog.json
```

原生侧只做“搬运”：解码、上传纹理、按 Dart 给的矩形和着色器画一帧、编码。
排版、比例、像素换算、混合公式一行都不在 Kotlin 里。

---

## 四、构建

本地不需要构建。推送到 `dev` 分支后由 GitHub Actions 编译：

* `dev` → 产出 pre-release APK（debug 签名，可直接覆盖安装）
* `main` → 产出正式 release（待启用正式签名）

手动构建：`flutter build apk --release`

---

## 五、已知限制

* 视频统一转码为 **H.264**（源若是 HEVC 会重新编码一次），音轨不解码。
* 原 App 里 `BMWmotorrad` / `CFmoto` / `horse` / `newyear` / `valentine` /
  `babyboy` / `babygirl` 属于**云端下发**样式，本地没有独立图层，
  这里只能沿用机型基础图层 + 对应配置表坐标，效果与联网下载的版本会不一样。
* 时间水印（美摄字幕）不在本应用范围内，只做机型水印。
* 水印图层与配置表版权归 Arashi Vision 所有，本项目仅供个人学习与研究使用。
