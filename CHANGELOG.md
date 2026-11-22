# Changelog

本项目的所有 notable 变更都会记录在此文件中。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/)，版本号遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### 新增

- 应用图标：绿→橙红渐变的 GPU 芯片图标，随构建打包进 App（附无依赖图标生成脚本）。
- 进程列表新增 CPU 与内存两列：显示各进程的 CPU 占用率（按逻辑核心归一化）和常驻内存，CPU 超过 50% 以橙色标示。
  - 说明：受 macOS 权限限制，系统/root 进程的 CPU 与内存显示为「—」；CPU 占用率在首次看到进程时为空，需经过一次刷新间隔后显示。
- 进程列表表头排序：点击 PID / CPU / 内存 / 显卡状态 / 上下文详情 列可排序，再次点击切换升序/降序。

### 修复

- 补齐顶部应用主菜单：苹果图标右侧的应用菜单不再为空，`⌘Q` 退出、`⌘H` 隐藏、`⌘⇧G` 显示主面板等快捷键正常生效。

## [1.0.0] - 2026-11-22

### 新增

- 菜单栏实时显示当前活跃显卡、负载、温度和锁定独显进程数。
- 主面板双显卡仪表盘，展示 iGPU/dGPU 负载、温度、核心频率与显存占用。
- 进程列表与筛选，显著标记持有独显锁（OpenGL / Framebuffer）的进程。
- 单进程退出/强杀以及「一键退出可关闭的独显锁进程」，自动保护系统关键进程。
- 全局显卡切换：支持实时 mux 切换与 `pmset -a gpuswitch` 持久化策略。
- 自动刷新（2 秒）与手动刷新。
- 一键构建脚本 `build.sh`，生成 ad-hoc 签名的 `GPUGuardian.app`。
- 项目开源规范化：MIT 许可证、README、贡献指南与变更日志。

[1.0.0]: https://github.com/WaveBird/GPUGuardian/releases/tag/v1.0.0
