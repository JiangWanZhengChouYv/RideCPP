# AGENTS.md

给接手这个仓库的 AI 代理看的工作说明。**只写项目简介、项目要求、当前任务；完成的任务立刻删除。**

---

## 项目简介

RideCPP 是一个轻量的 macOS 原生 C++ IDE，面向算法题和课程作业这类「单文件、写完就跑」的场景。

- 界面：**SwiftUI**
- 编辑内核：**AppKit `NSTextView`**（TextKit 1）
- 编译运行：直接调本机 `clang++` / `g++`，不经过终端
- 语义能力：接入 **clangd**（Xcode 自带，`/usr/bin/clangd`），用于补全、实时诊断、悬停、跳转定义
- 行内续写：可选**本地模型**（Ollama + `qwen2.5-coder:1.5b`，约 1GB，预热 0.02–0.16 秒），默认关闭

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

1. **不要碰用户的稳定版。**
   - 开发和自动化测试一律运行 `build/Build/Products/Debug/RideCPP.app`。
   - 给用户试用：`make install-test` → 装到 `/Applications/RideCpp-Test.app`。
     它是**独立应用**（bundle id `com.ridecpp.RideCPPTest`，名字 `RideCpp-Test`），
     与稳定版 `/Applications/RideCPP.app` 的设置、文件关联、自动更新完全隔离。
   - `make install` 默认拒绝写 `/Applications`；只有显式 `make install RELEASE=1`
     才会替换稳定版，**不要主动执行**。

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

暂无。

## 行内续写的设计约束（勿随意改动）

- **只有本地模型一个来源**。曾经的统计预测（从用户文件学整行写法）已删除：
  它的语料会混入当时打开的任何文件，包括测试文件里的错误，产生
  `cin>> ridecpp::version;` 这类垃圾。模型做得更好，不必维护两套。
- **默认关闭**。每次建议都是一次模型请求，耗电。由用户在设置里主动开启。
- **模型首选 1.5b**。实测：1.5b 预热 0.02–0.16 秒、986MB，输出干净；
  0.5b 会给答案加注释（`amespace std;  // This line is necessary...`），
  不能作为插入代码。`deepseek-r1:1.5b` 需 6.7 秒且输出思考过程，不可用。
  通用对话模型（qwen2.5、qwen3.5）会把 `f` 当单词前缀补成 `stream file`，
  只有 FIM 训练的 coder 模型正确。
- **必须用 FIM 格式**：`<|fim_prefix|>…<|fim_suffix|>…<|fim_middle|>`。
- **`num_ctx` 不能太小**。512 时模型看不到 include，会输出 `printf` 而不是本文件的 C++ 风格；2048 才正确。
- **建议必须静默失败**。超时、空结果、与已有文本重复、接不上正在打的词，一律不显示。
- **只预测当前行**，行尾是 `;` `{` `}` 就不预测（那行已经写完了）。
- 灰字**只画不插入**；Tab 接受走 `insertText`，一次撤销移除整段。

## 补全列表（clangd）

- clangd 的 `sortText` **就是作用域距离**（实测：局部变量 `3f8bfb0e` < 头文件 `4109f058`），
  必须按它排序，不要自己重新设计权重。
- 头文件符号的 label 带 `•` 前缀，解析名字时要跳过。
- Tab 走的是 `insertTab` 而不是 `keyDown`，补全面板的 Tab 处理必须在那里也检查。
- 不提供与正在输入的词完全相同的候选（那会吞掉一次按键且什么都不变）。

## 完成即删

新任务开始前先写进上面「当前任务」，完成并验证通过后立刻删除。
