# GPU Guardian

> 一个用于 macOS 双显卡（Intel 核显 + AMD/NVIDIA 独显）机型的实时 GPU 监控与切换工具，兼容 OpenCore Legacy Patcher (OCLP) 环境。

GPU Guardian 通过 IOKit 直接读取硬件与进程状态，在菜单栏实时显示当前使用的显卡、负载、温度和显存占用，并允许你查看、退出占用独显的进程，或在「仅核显 / 自动切换 / 仅独显」之间切换全局显卡策略。

## 功能特性

- **实时状态栏**：菜单栏图标实时显示当前活跃显卡、负载、温度及锁定独显的进程数量。
- **双显卡仪表盘**：主面板分别展示核显（iGPU）与独显（dGPU）的负载、温度、核心频率、显存占用。
- **进程监控**：列出所有持有 GPU user client 的进程，显著标出锁定独显（OpenGL / Framebuffer）的进程，并显示各进程的 CPU 占用率与常驻内存。
- **进程管理**：对可安全退出的进程发送退出或强杀信号；自动保护 WindowServer、Finder 等系统关键进程。
- **全局显卡切换**：通过 `AppleGraphicsControl` 进行实时 mux 切换，并可选通过 `pmset -a gpuswitch` 持久化系统策略（需管理员授权）。
- **自动刷新**：默认每 2 秒刷新一次状态，可手动刷新或关闭自动刷新。

## 兼容性

| 项目 | 要求 |
| --- | --- |
| 操作系统 | macOS 10.15 及以上 |
| 架构 | x86_64（当前构建脚本目标为 Intel Mac） |
| 显卡 | Intel 核显 + AMD/NVIDIA 独显的 MacBook Pro 等双显卡机型 |
| 环境 | 已在 OCLP（OpenCore Legacy Patcher）环境下使用 |

> 提示：切换显卡策略涉及系统底层接口，部分机型或 macOS 版本可能不支持实时 mux 切换；此时可勾选「写入系统 pmset」以使用系统级策略。执行相关操作需要管理员权限。

## 构建

本项目不依赖 Xcode 工程，使用 macOS 自带的 `clang` 与 `swiftc` 即可编译。

**依赖：**

- Xcode 命令行工具（`xcode-select --install`）
- macOS 10.15+ SDK

**编译：**

```bash
git clone https://github.com/WaveBird/GPUGuardian.git
cd GPUGuardian
./build.sh
```

构建脚本会：

1. 编译 C 语言 IOKit 桥接层 `Sources/GPUMux.c`
2. 编译 Swift 源码并与 C 目标文件链接
3. 生成 `GPUGuardian.app` 并进行 ad-hoc 签名
4. 输出到项目根目录的 `GPUGuardian.app`

构建产物（`build/`、`*.app/`）已被 `.gitignore` 忽略，不会提交到仓库。

## 使用

1. 双击或在终端打开 `open GPUGuardian.app` 启动应用。
2. 应用启动后会在菜单栏显示 🌿 iGPU 或 🔥 dGPU 图标。
3. 点击菜单栏图标可查看简要状态或通过子菜单切换显卡模式。
4. 点击「显示主面板」（快捷键 `⌘⇧G`）打开完整仪表盘：
   - 使用顶部三个按钮切换全局显卡模式。
   - 勾选「写入系统 pmset」可将切换策略持久化（会弹出管理员授权）。
   - 在进程列表中可单独退出/强杀进程，或使用「一键退出可关闭的独显锁进程」。
   - 点击表头的 PID / CPU / 内存 / 显卡状态 / 上下文详情 可排序，再次点击切换升序/降序。
   - 按住 `Control` 键可暂停自动刷新，方便查看某一时刻的快照（松开后恢复，手动刷新仍可用）。
5. 通过「关于 GPU Guardian」查看版本与功能说明；通过「退出 GPU Guardian」关闭应用。

## 项目结构

```text
GPUGuardian/
├── Sources/
│   ├── GPUMux.h / .c              # IOKit 底层：硬件状态读取、进程收集、mux 切换
│   ├── GPUGuardian-Bridging-Header.h
│   ├── GPUProcessMonitor.swift    # 进程与硬件状态封装、模式切换、进程终止
│   ├── MainPanelController.swift  # 主面板 UI 与交互逻辑
│   ├── AppDelegate.swift          # 菜单栏、菜单与生命周期
│   └── main.swift                 # 应用入口
├── Assets/
│   ├── GPUGuardian.icns           # 应用图标（绿=核显 → 橙红=独显）
│   └── generate_icon.py/.sh       # 无依赖图标生成器（可重新生成 icns）
├── Resources/Info.plist           # 应用 Bundle 配置
├── build.sh                       # 一键构建脚本
├── LICENSE                        # MIT 许可证
└── README.md
```

## 贡献

欢迎提交 Issue 和 Pull Request。提交前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)，并遵循常规的开源协作礼仪：保持提交聚焦、说明改动动机与测试方式。

## 版本历史

参见 [CHANGELOG.md](CHANGELOG.md)。

## 许可证

本项目基于 [MIT License](LICENSE) 开源，Copyright © 2026 Jame。

>  disclaimer：本项目涉及系统级显卡切换与进程终止操作，请自行评估风险。使用本软件造成的任何损失由使用者自行承担。
