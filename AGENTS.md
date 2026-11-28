# AGENTS.md

给接手这个仓库的 AI 代理看的工作说明。**只写项目简介、项目要求、当前任务；完成的任务立刻删除。**

---

## 项目简介

RideCPP 是一个轻量的 macOS 原生 C++ IDE，面向算法题和课程作业这类「单文件、写完就跑」的场景。

- 界面：**SwiftUI**
- 编辑内核：**AppKit `NSTextView`**（TextKit 1）
- 编译运行：直接调本机 `clang++` / `g++`，不经过终端
- 语义能力：接入 **clangd**（Xcode 自带，`/usr/bin/clangd`），用于补全、实时诊断、悬停、跳转定义
- 行内续写：可选**本地模型**（Ollama + `qwen2.5-coder:0.5b`，约 400MB，预热 0.19 秒），默认开启

仓库：<https://github.com/JiangWanZhengChouYv/RideCPP>
分发：GitHub Releases，DMG 直装；未公证，首次打开需「仍要打开」。

> **多代理并行时先读 `ax.md`**：这是 **dsh** 与 **wbd** 的协作板，写着谁在改哪些
> 文件、当前任务归属、构建/测试的串行规则。本文件只管项目规则，`ax.md` 管并行协调。
> 在 `ax.md` 里写字必须署自己的名（`[dsh]` / `[wbd]`），不要改对方署名的条目。

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
- **默认开启**，用户可在设置里关掉。每次建议都是一次模型请求，费电但省事；
  用户明确要求默认开着（2026-11-28）。
- **模型首选 0.5b**（`qwen2.5-coder:0.5b`，397MB，预热 0.19 秒）。用户明确要求
  只留 0.5b 以减小首次下载体积，1.5b 已从默认列表移除。
  1.5b 质量更好（986MB，0.15 秒），设置里若装了会出现在下拉里，但不是默认。
  `deepseek-r1:1.5b` 需 6.7 秒且输出思考过程，不可用。
  通用对话模型（qwen2.5、qwen3.5）会把 `f` 当单词前缀补成 `stream file`，
  只有 FIM 训练的 coder 模型正确。
- **必须用 FIM 格式**：`<|fim_prefix|>…<|fim_suffix|>…<|fim_middle|>`。
- **`num_ctx` 不能太小**。512 时模型看不到 include，会输出 `printf` 而不是本文件的 C++ 风格；2048 才正确。
- **建议必须静默失败**。超时、空结果、与已有文本重复、接不上正在打的词，一律不显示。
- **只预测当前行**，行尾是 `;` `{` `}` 就不预测（那行已经写完了）。
- 灰字续写**只画不插入**；Tab 接受走 `insertText`，一次撤销移除整段。
  （注意与下面的「灰字标签」区分：那是 clangd 的 inlay hints，用附件占位；
  这里说的是模型续写的灰字，用临时属性绘制。）

## 补全列表（clangd）

- clangd 的 `sortText` **就是作用域距离**（实测：局部变量 `3f8bfb0e` < 头文件 `4109f058`），
  必须按它排序，不要自己重新设计权重。
- 头文件符号的 label 带 `•` 前缀，解析名字时要跳过。
- Tab 走的是 `insertTab` 而不是 `keyDown`，补全面板的 Tab 处理必须在那里也检查。
- 不提供与正在输入的词完全相同的候选（那会吞掉一次按键且什么都不变）。

## 查找 / 参数提示 / 重命名 / 灰字标签

### 查找替换
- 匹配逻辑在 `EditorCore/TextSearch`，**不在视图里**，所以能脱离窗口测试
- 空查询必须返回空数组，不能返回"全部"；能匹配空串的正则要跳过，否则死循环
- 查找高亮用**独立的临时属性通道**，不能碰诊断的 `.backgroundColor`，否则清掉搜索时
  会连带擦掉红色波浪线

### 参数提示
- `CallContext` 判断"光标是否在调用括号内"，纯逻辑、可测。规则容易写错的地方：
  字符串里的逗号不算参数分隔、`if(`/`while(` 不是调用、语句边界要截断
- clangd 首次请求常返回空（文档还没打开完），**必须重试一次**

### 重命名
- clangd 返回的路径会重复：`/tmp/x.cpp` 与 `/private/tmp/x.cpp` 是同一文件（macOS
  符号链接）。**按解析后的真实路径去重**，否则同一处会被替换两次
- 必须做成**一次撤销**：对不可变字符串一次性生成结果，再一次性写回，不要逐处替换

### 灰字标签（inlay hints）
- **TextKit 1 没有公开的隐藏文本 API**（`glyphShape` 已移除）。直接 `draw` 出来的
  文字**不会推开代码**，会叠在上面 —— 实测过，`name:` 直接盖在 `s` 上
- 唯一可行的机制是 `NSTextAttachment` + `NSTextAttachmentCell`，它能让排版层真正
  留出宽度
- 代价：附件会进 `textView.string`。所以 **`DocumentModel.text` 和所有同步路径必须
  读 `currentSourceText()`**，绝不能读 `textView.string`，否则 `\uFFFC` 会写进保存的
  文件、发给 clangd、进到编译器
- 编辑时必须先移除标签，否则偏移全错
- clangd 会给匿名成员造 `u1`、`u2` 这种名字并带上 `{&`，必须过滤，否则显示成噪音

### 诊断节奏
- clangd 每次按键都回报，半成品代码立刻标红。**红色波浪线延迟 600ms 显示**
- 延迟只是显示层的，⌥F 快速修复必须能查到**尚未绘制**的诊断，否则会误报
  "请先把光标放在标红的位置上"

## 完成即删

新任务开始前先写进上面「当前任务」，完成并验证通过后立刻删除。
