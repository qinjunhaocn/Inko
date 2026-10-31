/// 水印混合内核（唯一一份源码，照片 / 预览 / 视频导出共用同一套公式）。
///
/// 原 App 的实现（`libarvbmg.so` 中 `WatermarkProgram` 的片元着色器，
/// 反汇编取自 `.rodata` 0x18E8613）核心只有两行：
///
/// ```glsl
/// watermarkTexcoord = vec2((texcoord.x - left) / (right - left),
///                          (top - texcoord.y) / (top - bottom));
/// fragColor = vec4(mix(color.xyz, wm.xyz, vec3(wm.a)), color.w);
/// ```
///
/// 也就是**直通 alpha 的 source-over 混合**，没有预乘、加色或调色。因此：
///
/// * 照片 / 预览：Flutter Canvas 的 `BlendMode.srcOver` 数学上与之完全等价
///   （`out = src.rgb * a + dst.rgb * (1 - a)`），用 `drawImageRect` 即可。
/// * 视频导出：解码帧在 GPU 上是 external texture，只能交给原生 GL 做同样的混合，
///   所以把下面这段源码**原样传给原生侧编译**，保证两条路径同源。
library;

/// 视频导出用的片元着色器。
///
/// 约定（原生侧固定绑定，不可改名）：
/// * `uFrame`      —— 解码帧（external OES 纹理）
/// * `uWatermark`  —— 水印 PNG（直通 alpha 上传）
/// * `uResolution` —— 画面像素尺寸 `[W, H]`
/// * `uRect`       —— 水印矩形 `[left, top, width, height]`，像素，左上原点
/// * `uOpacity`    —— 不透明度倍数（1.0 = 与原 App 完全一致）
/// * `vSample`     —— 画面采样坐标（已乘 SurfaceTexture 变换矩阵 + 旋转）
///
/// 水印位置用 `gl_FragCoord` 计算（GL 里原点在左下），因此**与纹理朝向无关**：
/// 即使某台设备的解码纹理上下翻转，水印也不会跟着跑到另一边。
const String waterKernelFragmentShader = r'''
#extension GL_OES_EGL_image_external : require
precision mediump float;

uniform samplerExternalOES uFrame;
uniform sampler2D uWatermark;
uniform vec2 uResolution;
uniform vec4 uRect;
uniform float uOpacity;

varying vec2 vSample;

void main() {
    vec4 color = texture2D(uFrame, vSample);

    // gl_FragCoord 原点在左下，先换成左上原点的像素坐标
    vec2 p = vec2(gl_FragCoord.x, uResolution.y - gl_FragCoord.y);
    vec2 rel = (p - uRect.xy) / uRect.zw;

    // 水印矩形之外：原帧直通（原 App 同样在矩形外直接返回原色）
    if (rel.x < 0.0 || rel.x > 1.0 || rel.y < 0.0 || rel.y > 1.0) {
        gl_FragColor = color;
        return;
    }

    vec4 wm = texture2D(uWatermark, rel);
    // 采样结果是预乘 alpha，先还原成直通 alpha，才能与原 App 的 mix() 对齐
    vec3 wmRGB = wm.a > 0.0 ? wm.rgb / wm.a : wm.rgb;

    gl_FragColor = vec4(mix(color.rgb, wmRGB, wm.a * uOpacity), color.a);
}
''';

/// 顶点着色器（原生侧固定使用）。
///
/// 四边形铺满裁剪空间；`uTexMatrix` 只作用在**解码帧的采样坐标**上，
/// 因此旋转元数据、纹理翻转都不会影响水印排版。
const String waterKernelVertexShader = r'''
attribute vec4 aPosition;
attribute vec2 aTexCoord;
uniform mat4 uTexMatrix;
varying vec2 vSample;

void main() {
    gl_Position = aPosition;
    vSample = (uTexMatrix * vec4(aTexCoord, 0.0, 1.0)).xy;
}
''';
