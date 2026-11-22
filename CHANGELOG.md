# Changelog

本项目的所有 notable 变更都会记录在此文件中。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/)，版本号遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

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
