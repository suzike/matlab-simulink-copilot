# 变更日志（Changelog）

本项目的所有重要变更都记录在此文件。

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)（MAJOR.MINOR.PATCH）。

---

## [0.10.1] — 2026-07-18

本补丁版本建立可重复执行的发布质量门禁，重点防止安装包内容漂移和 UI 文字越界回归。

### 新增（Added）

- 新增 `scripts/release-check.mjs`，检查版本一致性、运行时零依赖、Git/MLTBX 清单、关键图标、UTF-8、UI 脚本语法、打包排除项和 SHA-256，并可输出机器可读 JSON。
- 新增 Playwright 桌面与窄屏布局回归，覆盖明暗主题、代表性对话/工具状态、页面横向溢出和快捷按钮文字边界。
- 新增 `release_acceptance.m`，从最终 `.mltbx` 解包执行 MATLAB 类加载、`checkcode`、`copilot_doctor` 和 Echo TCP 全链路；Add-On 注册安装保持显式启用和替换保护。
- 新增 Windows GitHub Actions 质量门禁与 Release 验收清单。

### 变更（Changed）

- `copilot_doctor` 在保留原有可读输出的同时返回结构化检查结果。
- 将 Simulink 工具栏 16/24 px 图标纳入版本控制，保证干净检出后的安装包可重复构建。
- Playwright 仅作为开发依赖；sidecar 运行时依赖仍为零，`.mltbx` 继续排除 `node_modules`。

### 验证（Verified）

- Sidecar：65 项 Node 测试全部通过。
- UI：4 项 Playwright 场景通过，覆盖 1100×1000 和 520×900 两种视口及明暗主题。
- MATLAB：R2025b `checkcode`、结构化 `copilot_doctor`、包内类加载和 Echo TCP 全链路验收。
- 发布包：`MATLAB-Copilot.mltbx` 使用 `ToolboxVersion=0.10.1` 重新构建并通过内容清单与 SHA-256 门禁。

## [0.10.0] — 2026-07-11

本版本完成半成品功能收口，重点统一多会话配置、MATLAB 本地操作权限和资源生命周期，并修复会话启动/关闭时的异步竞态。

### 新增（Added）

- **每会话完整配置**：`user_message` 与 `slash_command` 可携带完整 `config`；新标签、Fork 和隐藏体检会话在 adapter 创建前原子继承 UI 配置。
- **MATLAB 本地权限控制器**：版本对比、需求锚定、经验库保存、测试、覆盖率、参数扫描和 SWDD 等副作用操作统一显示确认卡并写审计。
- **本地权限审计状态机**：操作先记录 `pending`，执行、拒绝或失败后更新为 `ok / failed`。
- **权限 MCP 独立测试**：覆盖 JSON-RPC 初始化、`tools/list`、`tools/call`、请求转发、审批响应和异常输入。
- **发布证据**：新增真实 MATLAB R2025b 内嵌截图，以及运行时架构、消息流、权限和会话生命周期静态图。

### 变更（Changed）

- Sidecar 会话增加 `ready / generation / dispatchEpoch / closed` 屏障，配置重建期间等待新 adapter，Stop 可取消未派发消息。
- `Panel` 使用 `ConfigByConv` 保存完整 per-conv 配置；插入、搜索与本地权限 pending 都按发起会话隔离。
- 附件改为一次性派发语义：仅成功派发后消费，Stop、关闭会话和销毁面板时清理临时图片。
- Plan 模式从只约束后端/MCP 扩展到 MATLAB 本地确定性副作用操作，形成双层强制只读。
- README、INSTALL、开发计划、功能清单、目录结构和全部发布图与当前代码同步。

### 修复（Fixed）

- 修复新会话先按默认配置启动、随后才收到 UI 配置造成的后端/模式短暂错配。
- 修复配置重建、Stop 或关闭期间待派发消息仍可能落入旧 adapter 的竞态。
- 修复关闭标签或 Fork 后旧 adapter 迟到事件重新写入 UI 的问题。
- 修复一次性附件重复注入、临时粘贴图片长期残留和跨回合误复用。
- 修复 Plan 模式可通过 MATLAB 本地确认卡执行写入/仿真/测试的权限缺口。
- 加固 Git ref、项目路径、规则/需求/经验文件、参数扫描值、Stateflow 与 SDI 数据输入边界。
- 修复浅色主题中权限卡次级文字对比度不足，并补齐全局 `--text2` 颜色变量。

### 验证（Verified）

- Sidecar：**65 个测试，11 个测试文件，全部通过**。
- UI：两段内联 JavaScript 语法检查与浏览器运行时注入检查通过。
- MATLAB：R2025b `checkcode`、关键类加载、真实 `Panel` 启动和两张 `exportapp` 截图通过。
- 发布包：`MATLAB-Copilot.mltbx` 使用 `ToolboxVersion=0.10.0` 构建并生成 SHA-256。

## [0.9.0] — 2026-07-07

面向团队赋能的大版本:新增 **14 项能力**,核心思路是「**确定性优先**」——检查/对比/统计由本地代码保证准确可复现(零 token、秒回),AI 只做它擅长的解释、归因与建议。

### 新增 — MBD 工程套件(Added)

- **◈ 模型语义 diff**:AI 每次 `model_edit` 前后自动快照,卡片展示 参数改前→改后表 / 新增删除块 / 父系统前后截图——slx 二进制改动第一次"看得见"。
- **✔ 建模规范检查器**:8 项确定性检查(未连接/端口·子系统·信号命名/魔术数字白名单/禁用块/层深/单层块数),规则读项目根 `modeling_rules.json`(内置 MAB 子集默认);报告卡上按需「AI 解释修复」「深查 Simulink Check」。
- **🧪 Test Manager 深度集成**:项目里有 `.mldatx` 直接本地真跑并结构化汇总;`coverage_check` 输出决策/条件/MCDC 覆盖率 + 块级缺口 + AI 补例建议(无 license 优雅降级)。
- **📋 需求双向追溯**:需求源=飞书多维表格导出的 `requirements.csv`(或 json),锚定关系存 `req_links.json`(纯文本可进 git);画布选中块 + 输入需求 ID 一键锚定,矩阵卡未覆盖高亮、点块画布跳转。

### 新增 — 高阶九连(Added)

- `/mdiff <ref>` **版本对比**:当前模型 vs git 历史版本的结构/参数/截图级 diff。
- `/sf` **Stateflow 解析**:状态/迁移表 + **不可达/无出口死逻辑检测** + mermaid 输出。
- `/impact <名>` **影响分析**:改接口前扫全部已加载模型的使用点(参数引用/命名信号/Goto tag),点击跳画布。
- `/siminsight` **仿真分析**:SDI 最近 run 的终值/超调/2% 稳定时间 + 曲线图 + AI 动态特性解读。
- `/sweep 变量 值列表` **参数敏感度扫描**:批量仿真出 取值×输出 对照表,自动恢复工作区。
- `/silcheck` **MIL vs SIL**:license 探测 + 引导式一致性验证编排(需 Embedded Coder)。
- `/night HH:MM 任务;任务` **夜间批跑**:定时灌入队列逐条执行,完成自动导出 Markdown 晨报。
- **📌 经验沉淀 + 自动召回**:气泡一键存入 `.copilot_kb/`(可进 git 共享);新消息按报错指纹自动召回相似经验注入上下文。
- `/checkup` **并行体检**:3 个隐藏子会话同查 结构/风险/可测性,完成后自动汇总成体检报告。

### 新增 — 文档与可发现性(Added)

- `/swdd` **SWDD 设计文档生成**:确定性提取 接口表/标定参数/子系统树/Stateflow 模式 成 Markdown 骨架落盘,AI 按需补全【待补】描述。
- **🧭 功能发现系统**:输入「? 你的需求」本地秒匹配功能(零 token,候选点击即执行,兜底 AI 选);**情境自动建议**(报错→诊断、AI 改模型 3 处→复核规范、工具失败→自愈,每类一次可关);斜杠菜单支持中文描述搜索;首次使用引导。
- **上下文感知 addpath 路径**:快照携带用户加载到 MATLAB 路径的文件夹,AI 直接知道共享库在哪。

### 性能(Performance)

- **`asciiJson` 向量化**:旧实现含中文时逐字符循环,大事件(截图 base64)一次序列化卡数秒且阻塞 MATLAB 主线程(连带拖慢 MCP 工具执行)→ 改按非 ASCII 位置分段拼接,**293KB 事件 0.001s**(千倍级)。
- 模型 diff:大画布(>60 块)跳过截图;diff 计算移到事件转发之后——"AI 操作模型慢"的三个根因全部消除。

### 修复(Fixed)

- 导航轨把 Fork 分支对话计入主会话轮次;Fork 气泡内批注错发主会话。
- KnowledgeBase 错误标识符大小写不匹配致召回失效;SfExplain 无出口检测被守卫误杀;DocGen 字符串行/列向量拼接崩溃。

### 测试(Tests)

- sidecar 56 → **57**;新增 MATLAB 综合功能测试(11 个模块全覆盖,含 asciiJson 性能断言);UI Playwright 断言累计 **100+** 全过。

---

## [0.7.5] — 2026-06-28

### 新增（Added）

- **对话轮次导航轨（minimap + 跳转锚点）**：长对话左侧多出一条紧凑的刻度轨（圆角框包裹），把「找回之前某轮问答」从线性滚动变成可视化的轮次索引。
  - **等距紧凑刻度**：每条用户消息一个刻度、等距排列、自适应缩距，压缩成一小块、永不松散到要滚动；轮次 ≥ 3 才出现，空/短会话自动隐藏。
  - **悬停富预览**：移到刻度弹出预览卡，显示该轮的 `第 N / 总 轮`、用户问、调用过的工具名，以及元信息徽章——`💬 N 答`（回合数）、`N ✓ / M ✕`（工具成功/失败）、`⟨⟩ 代码`、`◈ diff`。
  - **点击跳转 + scroll-spy**：点刻度平滑滚动到那一轮并整轮高亮；滚动时高亮当前所在轮的刻度（「我在哪」）。
  - **per-tab 隔离**：导航轨始终针对当前标签页的会话重建，切换会话正确跟随。

### 修复（Fixed）

- 切换到空/短会话时，导航轨没清掉上一个会话残留的刻度与预览卡（仅 `display:none` 隐藏）→ 现在主动清空。
- 后建会话（会话三及以后）的预览卡因缺 `z-index` 且 DOM 排在新建 pane 之前，被后续 pane 遮挡/挤偏（错位到下方、压成窄条）→ 给预览卡加 `z-index`，并在新建标签页后把导航轨/预览卡移到 `#panes` 末尾。

---

## [0.7.0] — 2026-06-27

本次聚焦**对话中的交互增强**：让用户能针对长回答里的具体段落批量追问，并在 AI 回答过程中即时干预（中断 / 排队 / 引导）。同时修复了一批伴随这些新交互暴露出的健壮性问题。

### 新增（Added）

- **选区批注 / 便签卡片**：在助手气泡内右键选中有疑问的文字 → 弹出批注框 → 可添加多条批注，以**便签卡片**形式贴在发送区，一键合并发送。被批注的文字段持久**黄色高亮**，清晰标识每条追问的对象。批注状态**按标签页隔离**，不再跨标签串台。
- **每个气泡的操作按钮**：每条助手气泡（含会话恢复出的历史气泡）都带 **复制 / 批注 / Fork** 按钮，并以**配色与图标**和气泡正文区分（复制=青、批注=黄、Fork=紫）。
- **回答中插入新需求**：AI 回答时即可输入下一条指令，两种模式（底部图标栏一键切换）：
  - **队列模式**：新消息排队，在**右下角灰显回显**（虚线边 / 淡化 / 灰字，与主会话区分），上一轮结束后逐条自动发送。
  - **引导模式**：立即中断当前回答，优先执行新指令。
- **Esc 即时中断**：回答过程中按 `Esc` 立即中断；`Stop` 按钮与 `Send` 互斥醒目显示；并加 MATLAB figure 键盘兜底，规避 `uihtml` 吞键。

### 变更（Changed）

- 待发送队列由右上角移到**右下角**并灰显，避免挤占对话流、与主会话视觉区分。

### 修复（Fixed）

- **批注浮框定位**：footer 的 `backdrop-filter: blur()` 会成为定位包含块、破坏内部 `position: fixed` → 把批注框 / 队列面板移为 `<body>` 直接子节点。
- **「上一轮尚未结束」**：后端 `result` 事件先于进程 `close` 触发，UI 在 `result` 后立即发下一条会撞上「子进程仍在」→ 新增后端排队（`_pending`）兜底，进程退出后自动续发。
- **流式气泡禁批注**：流式回答 DOM 持续变更会使保存的 `Range` 失效（高亮静默失败但便签照加）→ 右键 / 批注入口在 `.streaming` 气泡上拒绝，提示结束后再批注。
- **跨块选区高亮安全**：跨 `<p>` / 代码块的选区改为放弃高亮（返回 `null`，**不破坏 DOM**），不再用 `extractContents` 兜底产生不平衡标签；选区落在已有高亮内则复用、不嵌套 `<mark>`。
- **后端排队健壮性**：`_pending` 改为 **FIFO 队列**（收尾期连发多条不互相覆盖）；`interrupt` / `stop` / `resetSession` 显式清空排队；`close` 续发包裹同步抛错与异步 reject，避免拖垮 sidecar；统一 Codex **看门狗超时**与**用户主动中断**对排队的处理（仅用户中断清队列，超时保留续发）。

### 测试（Tests）

- sidecar 单测 **52 → 56**（新增 claudeCode 多条 FIFO 续发、Codex FIFO 入队 / `killChild` 标志 / `resetSession` 清队列）。

---

## [0.6.0] — 2026-06

**首个公开发布版**。内嵌 MATLAB / Simulink 的 AI Copilot 侧边栏，对标官方 Simulink Copilot 六项能力并补齐 MBD 工程化。

### 新增（Added）

- **进程内可停靠面板**：`uifigure` + `uihtml` 原生停靠，无第二窗口 / 无外部浏览器；流式渲染、思考 / 工具可视化。
- **双后端运行时切换**：Claude Code ↔ Codex，会话 / 线程各自 resume；Claude 可选**常驻进程**消除每轮冷启。
- **上下文自动感知**：当前文件 / 模型 / 选中 block / 工作区 / 最近报错；工程级全工程索引（git 状态 + slx/m/数据字典/Bus 清单）。
- **对标官方六项能力**：对话、解释模型/模块、搜索组件（画布高亮）、排查错误（结构化诊断 + 一键跳转出错 block）、答案锚定 MathWorks 文档（在线 RAG + 本地 help 兜底）、自动执行预定义任务（自适应任务流）。
- **MBD 工程化**：批量编辑（逐处 diff 确认）、测试编排闭环、需求追溯矩阵、代码评审（MISRA-C / 复杂度 / Coder 估算）、自愈验证环、画布截图分析。
- **会话与平台**：多标签 + 卡片 Fork、会话持久化按项目恢复、导出 Markdown、成本 / token 显示、Ctrl+K 命令面板、主题三选。
- **权限与安全模型**：只读自动放行 + 破坏性操作经独立控制端口转 UI 确认卡；Ask / Auto / Plan 三档；面板未连接默认拒绝、确认 180s 超时默认拒绝、全程审计留痕；**绝不使用 `--dangerously-skip-permissions`**。

### 修复（Fixed）

- **零 npm 依赖打包**：sidecar（含权限 MCP）改为零依赖、手写 JSON-RPC，**不打包 `node_modules`** → 根治旧版（≤ 0.5.0）`node_modules` 深层路径超 Windows 260 MAX_PATH 导致文件丢失、权限模块 `approval not found` 的问题。

[0.10.1]: https://github.com/suzike/matlab-simulink-copilot/releases/tag/v0.10.1
[0.10.0]: https://github.com/suzike/matlab-simulink-copilot/releases/tag/v0.10.0
[0.9.0]: https://github.com/suzike/matlab-simulink-copilot/releases/tag/v0.9.0
[0.7.5]: https://github.com/suzike/matlab-simulink-copilot/releases/tag/v0.7.5
[0.7.0]: https://github.com/suzike/matlab-simulink-copilot/releases/tag/v0.7.0
[0.6.0]: https://github.com/suzike/matlab-simulink-copilot/releases/tag/v0.6.0
