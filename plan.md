# 实施计划与进度(plan.md)

> 本文件记录项目目标、已完成内容、关键决策与后续路线,作为上下文压缩后的"事实底座"。
> 配套 `AGENTS.md`(架构深解 + 踩坑清单)、`README.md`(用法)。

## 1. 目标

把官方 MATLAB/Simulink Copilot 在中国不可用的空缺,用「**原生内嵌进 MATLAB 界面的 AI 助手**」补上:停靠侧边栏对话,自动感知工程上下文,经 MATLAB MCP 实操会话。**能力对标官方且只多不少。**

核心约束(用户反复强调):
- **必须真正内嵌进 MATLAB/Simulink 界面**,不是外部 web 前端、不开第二个窗口。
- UI 在 `uihtml` 内渲染,**无 CDN**(全资源内联)。
- 复用用户已有的官方 MATLAB MCP,不重造通信层。

## 2. 架构决策(已定)

- **三段式**:uihtml 面板(JS)⇄ MATLAB 面板进程 ⇄ Node sidecar ⇄ 后端 CLI。
- **后端适配层**:`BackendAdapter` 抽象;`ClaudeCodeAdapter` / `CodexAdapter` / `EchoAdapter`。**运行时可切换**(sidecar 收 `set_config` 重建适配器)。
- **大脑放本地 sidecar**(用户选「复用现成 headless agent」),不在 MATLAB 内做 agent 编排。
- **线协议**:localhost TCP,行分隔 JSON,**全 ASCII**(避开 MATLAB tcpclient 的 UTF-8 解码问题)。
- **权限**:headless agent 的 `--permission-prompt-tool` → sidecar 控制端口 → UI 确认卡;只读工具自动放行。绝不 skip-permissions。
- **斜杠命令范围**:实用集 + 自定义命令(用户选定);纯 TUI 命令不引(headless 无效)。
- **模型来源**:读 codex/claude 配置自动枚举 + 预设(用户选定)。

## 3. 已完成(全部已实测,真实 MATLAB R2025b)

### v0.10.0 收口：统一安全与多会话可靠性

- 新标签、Fork、隐藏体检会话首消息携带完整 config，sidecar 在 adapter 创建前应用。
- Sidecar 会话使用 `ready/generation/dispatchEpoch/closed` 屏障；配置重建、Stop、关闭和旧事件回流互不串扰。
- MATLAB `Panel` 增加 `ConfigByConv`、按会话 pending 状态和本地权限控制器；Plan 模式同时约束 MCP 与本地副作用操作。
- 附件为一次性消息资源，派发后消费，Stop/关闭/销毁清理临时图片。
- 11 个确定性模块的路径、Git ref、CSV/JSON、扫描值、Stateflow 和 SDI 输入完成安全加固。
- 浅色主题权限卡对比度修复；README 与全部静态架构/流程图改为当前实现，实机截图由 MATLAB R2025b 重新导出。
- 当前验证基线：sidecar **65 tests / 11 files**；UI 脚本语法与浏览器注入；MATLAB `checkcode`、类加载、真实面板截图。

### v1 骨架
- Sidecar:协议/stream-json 解析/echo/claude 适配器/TCP server/权限确认 MCP。
- MATLAB:`Panel`(可停靠 uifigure+uihtml)/`Bridge`(tcpclient 行协议)/`Context`(上下文采集)/`copilot.m` 入口。
- UI:本地打包聊天界面,流式渲染。

### v2 能力对标
- 文档来源引用(系统提示锚定 MathWorks 文档 + UI 链接)。
- 快捷动作:诊断报错/解释/加注释/生成测试/标准检查。
- 生成到光标(`matlab.desktop.editor`,兼容 Live Editor)。
- Simulink 入口:`install_toolstrip.m`(官方 JSON 插件 ribbon)+ `sl_customization.m`(Tools 菜单)。

### v3 富交互(本阶段)
- **思考过程**:解析 thinking/reasoning → 可折叠流式块;claude 经 `MAX_THINKING_TOKENS`。
- **富文本渲染器**:自包含 Markdown(标题/粗斜体/列表/引用/表格/代码块带语言头/行内代码/链接),PUA 占位符防冲突。
- **紫色科技 UI 重做**:双侧头像、语义化配色(用户蓝/思考紫/工具青/技能金)、流式光标、卡片化工具/技能调用、入场动效。
- **Codex 后端**:`codex exec --json` 解析(agent_message/reasoning/command/mcp_tool_call/error)。
- **运行时切换**:后端 claude↔codex、模型、思考强度、编辑模式(Modes 弹窗)。
- **加载本地文件作上下文**(`＋` uigetfile)。
- **斜杠命令**:`/` 菜单(内置 + 自定义命令枚举)。
- **能力枚举**:`capabilities.js` 读配置出后端/模型/模式/命令。

### 关键修复(实测中发现,均已修)
1. 中文乱码 → 线上全 ASCII(`serialize` + `Bridge.asciiJson`)。
2. 单变量工作区致 sidecar 崩溃 → `toArray/toArr` 强制数组。
3. busy 卡死/result 丢失 → `Bridge.onData` 排空所有行。
4. context 推送静默失败 → `Panel.pushToUi` 改传 JSON 字符串。
5. 嵌套 claude 401 → `buildEnv` 检测 `CLAUDECODE` 清洗 token。
6. matlab MCP `failed to attach` → `sessionDetails.json` **路径不一致**(MCP Server vs MCP Core Server);`copilot.m` 镜像 + 需 `satk_initialize` + 单实例。
7. matlab 工具/approval 没加载 → claude 用 `--strict-mcp-config` 注入 matlab+approval。
8. 气泡叠加 → `assistant_start` 强制新建气泡。
9. Markdown 占位符冲突("C0"/"B5") → 改 PUA 字符 `/`。
10. 工具卡 flex 塌成 1px → `#messages > * { flex:0 0 auto }`。
11. **Codex 慢(64s)→ `--ignore-user-config` + 注入 matlab MCP(~25s)**。
12. Codex 传输回退警告噪声 → 过滤。

### v4 对标官方 Simulink Copilot + 打磨(本阶段,均已实测)
- **P1 模型组件搜索 + 高亮**(对标官方「搜索模型」):`🔍 查找模块` → 输入描述 → agent 语义定位 → MATLAB 原生 `hilite_system(path,'find')` 橙色高亮 + 解释。`ModelSearch.m`。**双保险取路径**:① 解析回答末尾 `<<HILITE: 路径>>` 标记(UI 渲染时剥掉);② 兜底嗅探 agent `model_read` 工具入参里属于当前模型的 block 路径(`collectStrings`)。不弱化权限。
- **P2 就地解释选中模块**(对标官方「解释模块」):`🧩 解释模块` 面板按钮 → 针对选中 block 用 `model_read` 读真实参数逐个精准解释(`explainSelected`)。Simulink 右键菜单代码也注册了,但 **R2025b 起上下文菜单 API 变扩展点格式、旧 `addCustomMenuFcn` 不渲染**,故按钮是可靠入口。
- **界面主题**:Light / Dark / 随 MATLAB(`Panel.detectTheme`:读 `settings().matlab.appearance.MATLABTheme`,System 时查 Windows 注册表;UI `request_theme`/`theme` 事件 + `html[data-theme=light]` 覆盖 + 浅底文字修正);localStorage 持久化,获焦/发送时重同步。
- **悬停说明**:快捷按钮悬停满 2 秒弹详细用途气泡(`data-tip` + 2s 定时)。
- **权限模式三态真正生效**:`ask` 逐条确认 / `auto` 改模型放行·跑代码仍确认(`isExecuteTool`) / `plan` 强制只读拒绝。修了「auto 仍逐条批准」(acceptEdits 不覆盖 MCP 工具)与「plan 不强制只读」两个漏洞。
- **稳定性修复**:去掉 3s 上下文刷新 `timer` + 单例 persistent 注册表(它们持有对象致 `clear classes` 失败、点 X 关不掉)→ 改发消息时刷新 + 按窗口 `UserData` 查找面板 + `onClose` 无条件删窗口。
- **作者寄语**:header 同行加 `Code is cheap, Show me your Harness! · © 林南橘`(紫蓝渐变,自适应省略)。

测试:**32 个 sidecar 测试全绿**(8 文件;新增 auto/plan 权限模式用例)。

### v5 多页面 / Fork / 消息体验 + 顶栏精简(本阶段,UI 已实测)
- **多会话地基**:sidecar `单 adapter → Map<convId,{adapter,独立config,会话}>`;`convId` 路由(默认 main 向后兼容),`close_conv` 关页;权限确认 MCP 注入 convId、确认卡按页路由(`convId::id` 复合键防撞);审计/compact 按会话归属。**35 单测**(新增多会话用例)。
- **多页面**:UI 标签页(可命名/改名/关闭/＋),每页独立对话+会话+配置;后台标签也正确收流。UI 用「全局渲染指针按 convId 重指向」让海量旧渲染代码零改动。
- **卡片 Fork**:每条回答可拉「以该卡片内容为种子」的独立子会话(convId=`fork-N`),嵌在卡片内,不进标签栏、不污染主线;首条消息内嵌父卡片内容作种子,后续走子会话续接。
- **消息 Reset / Copy**:用户气泡「✎ 编辑」撤回该条及其后并回填输入;回答卡片「⧉ 复制」走 MATLAB `clipboard`。按钮**悬停才显示、不占高度**。
- **顶栏从 3 行压成 1 行**:标签页 + 上下文 + 品牌图标合并;上下文压成一个**带计数图标**(悬停弹气泡看详情);品牌寄语/作者移到**空会话欢迎水印**。
- MATLAB:Panel 跟踪 `ActiveConv`,所有转发后端的消息带 convId;新增 `copy_text`/`close_conv` 事件。
- **附件支持所有文件 + 粘贴图片**:`＋` `uigetfile` 默认显示所有文件;图片(png/jpg/…)走视觉(附件给路径,agent 用 Read 读图);其余读文本。输入框 `Ctrl+V` 粘贴截图 → `attach_image{dataUrl}` → MATLAB `base64decode` 写临时 PNG → 图片附件。附件 struct 统一 `{name,content,path,isImage}`;`types.js` preamble 图片给路径 + Read 指令。

### v6 MBD 工程化 + 会话/工程能力(本阶段,均已实测)
**MBD 工程化(快捷动作):**
- 🪄 **批量编辑**:自然语言描述批改需求 → agent 定位所有目标 block → 逐个 `model_edit`(每处走 diff 确认)。
- 🧪▶ **测试编排一键化**:生成测试 → 运行 → 结果汇总闭环(MATLAB `functiontests`/`runtests` 或 Simulink Test/`model_test`)。
- 📋 **需求追溯**:反向推导需求条目、建立 block↔需求双向追溯矩阵(检测 Requirements Toolbox)。
- 🔬 **代码评审**:MISRA-C 风险 + 圈复杂度 + 向量化机会 + Embedded Coder 代码规模/RAM/ROM 估算。
- 🔄 **自愈验证环**:run→抓错→修→重跑,最多 3 轮直到通过。
- 📸 **画布截图分析**:导出模型 PNG → 视觉分析信号流/命名/未连接端口/布局。

**会话与工程能力:**
- ⚡ **常驻后端进程**:Claude Code 工具栏开关(或 `env MATLAB_COPILOT_PERSISTENT=1`),进程常驻消除每轮冷启延迟;进程意外退出自动 resume 重启、中断 kill+resume、故障安全。**(原"未做/暂缓"项,现已实现)**
- **会话落盘持久化 + 按项目恢复**:按工程根分 key 存 localStorage,重启自动恢复历史(提示"后端上下文已重置")。
- ⬇ **会话导出为 Markdown**。
- **工程级全工程索引**:在当前文件/模型基础上,索引整个 MATLAB Project(git 分支/状态 + slx/m/数据字典/Bus 文件清单)。
- **任务清单可视化**:回答里的 `- [ ]` / `- [x]` 渲染成可勾选复选框。
- **快捷命令面板(Ctrl+K)** + 键盘快捷键(↑召回上条/↓↑导航/Esc)+ **成本/token 显示**(按标签累计)。

## 4. 待办 / 路线

### 对标官方 Simulink Copilot 的 6 项能力(差距追踪)
| # | 官方能力 | 状态 |
|---|---|---|
| 1 | Copilot Chat 对话(工具/建模/设计建议) | ✅ 已有(双后端) |
| 2 | 解释模型/模块(选中→解释) | ✅ 完成(🧩 解释模块,读真实参数) |
| 3 | 搜索模型组件(描述→定位→高亮) | ✅ 完成(🔍 查找模块 + `hilite_system`) |
| 4 | 排查错误(解释+根因+修复) | ✅ 完成:`sldiagviewer.DiagnosticReceiver` 结构化诊断 + 卡片 + 一键跳转高亮 block(`Diagnostics.m`) |
| 5 | 基于 MathWorks 文档作答(RAG) | ✅ 完成:**在线 RAG** —— 系统提示 best-effort WebFetch 抓 mathworks.com/ww2.mathworks.cn 文档核实、只引实际抓到的链接(dev-client 实测 claude 真抓真纠);抓取失败改用**本地 MATLAB `help` 文档兜底**(只读自省 `help/which/exist/lookfor` 自动放行,严格门控有单测),都查不到才标「未核实」;适配中国/联网不稳环境 |
| 6 | 可信度/可追溯(认证级) | ✅ 完成:操作审计轨迹(破坏性操作落 `~/.matlab-copilot/audit-*.jsonl` + 面板「变更记录」)+ 系统提示自验证(改后 model_read 回读)+ 来源标注 |
| 7 | 自动执行预定义任务(Process Advisor) | ✅ 完成:**自适应任务流** ⚙ —— `Tasks.capabilities()` 探测 padv/Simulink Check/Test;有 `padv` 用真 `runprocess`,无则编排等价管线(编译/结构化诊断 → 标准检查/基本静态检查 → Simulink Test → 汇总报告);本机实测(无 padv/Check、有 Test)提示正确自适应 |

**进度**:**4 个红框差距全部闭合**。官方 6 项能力 + 可追溯 + 任务编排已全部对齐或超过。本机 license:无 Process Advisor / 无 Simulink Check / 有 Simulink Test → 任务流自动降级为等价管线,装了附加件的机器自动升级用真 Process Advisor。中国可访问 mathworks.com 文档站,故文档 RAG 走在线 WebFetch。


### 已完成(本阶段补做)
- ✅ **切换/中断优雅化**:主动 kill(切后端/点停止)时 close 回调不再弹「退出码 null」;UI `onConfigChanged` 复位 busy。(机制后续演进为 per-child `child._killing` + `this.child===child` 守卫,消除跨代竞态;两后端一致,见 AGENTS §7.18)
- ✅ **附件按文件移除**:每个附件独立 ✕(`remove_attachment` 事件),保留「清除全部」。
- ✅ **斜杠命令参数占位符**:自定义命令体含 `$ARGUMENTS` 则替换为用户参数,否则附在末尾。
- ✅ **/compact 真正压缩**:生成摘要(用户可见)→ `adapter.resetSession()` 丢弃后端续接会话 → 摘要播种到下一轮上下文(`compactSummary`,只播一次)。server 端编排,有单测覆盖(切后端时重置 `compacting` 防卡死)。
- ✅ **工具条图标**:`install_toolstrip.m` 用 `imwrite` 生成紫色 16/24px 图标(白色四角星 + 圆角透明),action 引用 `copilotIcon`。
- ✅ **.mltbx 打包向导**:`build_toolbox.m`(R2023a+ `ToolboxOptions`/`packageToolbox`),打包 matlab/ui/sidecar、排除 node_modules 等;装后提示 npm install + satk_initialize。

### 未做(暂缓)
1. **AppContainer 真侧栏**:未公开 API,脆弱;保持 docking 兜底。
2. **Reset 真·后端回滚**:目前 Reset 是 UI 撤回 + 作为新一轮重发(后端历史仍留那轮);真回滚需 resetSession+重放或按 /compact 重播种,代价大。
3. **每标签页独立上下文/附件**:目前上下文(MATLAB 实时状态)与附件是面板级共享,多标签共用;如需每页独立可后续做。
4. **右键菜单**:R2025b 上下文菜单需用 R2026a 扩展点 API 重做(现用面板按钮兜底)。
5. **离线 LLM(Ollama)**:仍未实现;当前只支持 Claude Code / Codex 云端后端。
6. **离线 docroot 文档索引**:用户明确不做(在线 WebFetch + 本地 `help` 兜底已够),暂不实现。

## 5. 验证方式

- 单测:`cd sidecar && npm test`。
- 不连 MATLAB 联调:`node src/index.js`(设 `MATLAB_COPILOT_BACKEND`)+ `node dev-client.mjs <port> "<问题>"`。
- 真实面板:`copilot()` 后在工具栏切后端/模型/模式,发消息看流式+思考+工具卡。
- UI 视觉:`ui/` 起静态服务用浏览器预览(`.claude/launch.json` 已配 python http.server),`onSidecar({...})` 注入样例事件。
