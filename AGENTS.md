# AGENTS.md

给接手这个仓库的 AI 代理看的工作说明。**只写项目简介、项目要求、当前任务；完成的任务立刻删除。**

---

## 项目简介

RideCPP 是一个轻量的 macOS 原生 C++ IDE，面向算法题和课程作业这类「单文件、写完就跑」的场景。

- 界面：**SwiftUI**
- 编辑内核：**AppKit `NSTextView`**（TextKit 1）
- 编译运行：直接调本机 `clang++` / `g++`，不经过终端
- 语义能力：接入 **clangd**（Xcode 自带，`/usr/bin/clangd`），用于补全、实时诊断、悬停、跳转定义

仓库：<https://github.com/JiangWanZhengChouYv/RideCPP>
分发：GitHub Releases，DMG 直装；未公证，首次打开需「仍要打开」。

---

## 项目要求

### 模块边界（必须遵守）

```
RideCPP        SwiftUI 应用层（App / Views / Console）
   ↓
EditorWindow   AppKit 视图层（NSTextView、补全面板、行号、高亮、主题）
   ↓
EditorCore     纯逻辑，禁止 import AppKit（语言、编辑、补全、符号、LSP）
   ↑
BuildKit       编译运行、工具链、进程、诊断解析、更新下载
```

依赖只能自上而下。**EditorCore 里出现 `import AppKit` 视为错误。**

### 开发规则

1. **不要碰 `/Applications`。**
   `make install` 默认只构建到 `build/`；替换已安装应用必须显式 `make install RELEASE=1`。
   开发和测试一律运行 `build/Build/Products/Debug/RideCPP.app`。

2. **重构前必须先向用户说明方案**，得到确认再动手。不要闷头在旧结构上继续加功能。

3. **改动必须验证**：
   - 单元测试 `make test`（EditorCore / EditorWindow / BuildKit）
   - 端到端自测 `RIDECPP_SELFTEST=/tmp/report.json build/Build/Products/Debug/RideCPP.app/Contents/MacOS/RideCPP`
   - 测试若通过临时打开文件，必须自己清理 `state.close(...)`，否则会污染后续检查

4. **不要虚报状态。** 徽章、注释、提交信息都必须与代码一致。

5. **提交前跑 SwiftLint**（`swiftlint lint`）。目标：1.3.0 之前 0 error（已达成）、0 warning（进行中）。

### 已知的构建约束

- 工程由 **XcodeGen** 生成：改 `project.yml` 后必须 `xcodegen generate`
- 编译需要 `OTHER_SWIFT_FLAGS: -Xfrontend -disable-sandbox`（本机宏插件沙箱限制）
- `xcodebuild test` 在本机会报 "Pseudo Terminal Setup Error"，改用
  `xcodebuild build-for-testing` + `xcrun xctest <bundle>`

---

## 当前任务

暂无。上一轮的四项（误报修复、悬停诊断、Problems 实时诊断、快速修复）均已完成并验证。

## 完成即删

新任务开始前先写进上面「当前任务」，完成并验证通过后立刻删除。
