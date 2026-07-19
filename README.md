<div align="center">

# MATLAB / Simulink Copilot

**真正内嵌在 MATLAB / Simulink 中的本地 AI 工程助手**

停靠式 `uihtml` 面板，自动感知 MATLAB 工程和活动模型，通过本地 sidecar 驱动 Claude Code / Codex，并复用 MATLAB MCP 操作当前 MATLAB 会话。

[![Version](https://img.shields.io/badge/version-0.11.0-success)](https://github.com/suzike/matlab-simulink-copilot/releases/tag/v0.11.0)
![MATLAB](https://img.shields.io/badge/MATLAB-R2023b%2B-orange?logo=mathworks)
![Node](https://img.shields.io/badge/Node.js-%E2%89%A520-339933?logo=node.js&logoColor=white)
![Backends](https://img.shields.io/badge/backends-Claude%20Code%20%7C%20Codex-2563eb)
![Tests](https://img.shields.io/badge/sidecar-72%20tests-16a34a)
![Runtime dependencies](https://img.shields.io/badge/sidecar-0%20npm%20dependencies-0f766e)

[安装指南](INSTALL.md) · [变更日志](CHANGELOG.md) · [开发计划](plan.md) · [最新 Release](https://github.com/suzike/matlab-simulink-copilot/releases/latest)

</div>

## 当前实机界面

下面两张图由仓库当前 `ui/index.html` 在全屏浏览器预览中生成，展示与 MATLAB `uihtml` 面板相同的前端代码、布局和交互状态。

<div align="center">
  <img src="docs/images/v0.11.0-ui-overview.jpg" width="900" alt="MATLAB Copilot v0.11.0 全屏界面与可信变更事务">
  <br>
  <sub>真实 MATLAB 内嵌面板：活动工程上下文、Echo 全链路冒烟、当前工具栏与 MBD 快捷动作。</sub>
</div>

<br>

<div align="center">
  <img src="docs/images/v0.11.0-change-recorder.jpg" width="900" alt="MATLAB Copilot v0.11.0 工程模型变更记录器">
  <br>
  <sub>真实 MATLAB 内嵌渲染：规范检查、覆盖率和本地权限确认卡。报告数值为固定协议演示数据，仅用于验证当前 UI 事件链。</sub>
</div>

## v0.11.0 重点

本版本将工具从“AI 功能集合”升级为可信工程代理：新增模型变更事务、失败安全回退、工程级持续记录器、模型文件语义差异、任务与需求元数据、确定性验证矩阵、风险和交付就绪度判断，以及可审计的完整证据包。

v0.10.3 完成的 MATLAB R2023b / 高缩放界面优化继续保留：

这个补丁版本解决 [Issue #1](https://github.com/suzike/matlab-simulink-copilot/issues/1) 中 MATLAB R2023b / 高显示缩放下底部功能区过高的问题，同时保持输入框位置和高度不变。

- **快捷功能三态**：沙漏按钮右侧提供隐藏、单行和全部多行展开三个图标模式，选择按本地偏好持久化。
- **响应式单行**：默认只占一行；大屏自然显示更多按钮，小屏显示较少，后续功能通过鼠标滚轮、触控板横滑或左右箭头浏览。
- **无可见滚动条**：单行模式保留横向滚动能力但隐藏滚动条，避免额外占用垂直空间。
- **输入区稳定**：三态只改变快捷功能行，配置工具栏、附件和对话输入框不参与缩放或折叠。
- **工具栏修复**：修复快捷按钮悬停上边缘裁切，以及模型列表为空时出现孤立下拉箭头。
- **R2023b 等效回归**：新增 760×600 受限视口覆盖；当前共 22 项 Playwright 用例在桌面和窄屏项目全部通过。

v0.10.2 完成的会话资源隔离继续保留：

- **每会话上下文快照**：标签与 Fork 按 `convId` 保存最近一次 MATLAB 工程状态，后台会话更新不会覆盖当前标签的上下文提示。
- **每会话附件队列**：待发送文件、粘贴图片、单项移除、清空、消费和临时文件清理均按 `convId` 执行。
- **Fork 输入隔离**：分支粘贴与附件列表固定绑定对应 Fork，不再误用主标签的活动会话。
- **关闭资源回收**：关闭标签或 Fork 时只清理目标会话的配置、上下文和临时附件，不影响其他会话。
- **隔离与布局回归测试**：Playwright 在桌面与窄屏验证标签切换、后台事件、Fork 附件、快捷功能三态、滚轮横移、悬停边界、空模型下拉和变更记录器任务证据，共 22 项用例。

### 工程模型变更记录器

下一阶段从“功能集合”升级为可信工程代理。当前已完成模型变更事务与工程级持续记录器：每次 `model_edit` 建立检查点和基线，执行后强制更新编译并检查新增规范错误；工程记录器则为当前 MATLAB 工程建立文件基线，持续保存模型、数据字典、需求和代码文件的保存前后快照，并将 AI 事务写入同一时间线。安全条件满足时验证失败会自动恢复修改前模型，完整证据分别写入 `~/.matlab-copilot/runs/` 与 `~/.matlab-copilot/change-records/`。

工具栏红色圆点用于控制工程记录器。启动、停止和导出均由用户显式触发；导出同时生成 `change-report.md`、`manifest.json` 和追加式 `changes.jsonl`。记录内容包括来源、时间、文件、增删改类型、SHA-256、前后快照和文本行变化摘要。保存的 `.slx/.mdl` 修改会由 MATLAB 隔离加载前后快照，补充块参数变化、新增/删除块与模型规模；AI 模型编辑则记录验证/回退状态和事务证据路径。

每个记录会话同时是一个工程变更任务，可填写任务名称、需求/工单 ID、责任人和变更说明。规范检查、Test Manager、覆盖率、需求矩阵和影响扫描结果自动进入验证矩阵；系统据此计算影响文件/模型/块、未闭环风险和 `ready/not_ready` 交付状态，并按受影响模型关联项目中的 `.mldatx` 或测试脚本。最终证据包额外包含 `evidence-index.json` 和 `traceability.json`。

v0.10.1 完成的质量门禁继续保留：

- **最终安装包验收**：`release_acceptance` 解包 `.mltbx`，从包内代码执行类加载、`checkcode`、环境自检与 Echo TCP 全链路，并输出 JSON 证据。
- **浏览器布局回归**：Playwright 固定验证 1100×1000、520×900 和 760×600 受限视口、明暗主题、代表性消息及全部可见按钮，阻止文字越界与页面横向溢出回归。
- **静态 Release 门禁**：统一检查版本一致性、运行时零依赖、Git/安装包清单、关键图标、UTF-8、UI 脚本语法、打包污染和 SHA-256。
- **CI 接入**：GitHub Actions 在 Windows 上执行 Node、UI 和静态发布门禁；MATLAB R2025b 验收保留机器可读的本机证据。
- **结构化环境诊断**：`copilot_doctor` 保留原有终端输出，同时返回可供自动验收消费的检查结果。

v0.10.0 完成的安全与可靠性能力继续保留：

- **每会话配置原子继承**：新标签、Fork 和隐藏体检会话的首条消息携带完整 `config`；sidecar 在 adapter 创建前应用，避免先用默认配置启动再切换。
- **会话启动与关闭屏障**：`ready / generation / dispatchEpoch / closed` 共同保证配置重建期间不误派发，Stop 能取消待派发消息，关闭后迟到事件不会污染 UI。
- **Plan 模式覆盖 MATLAB 本地动作**：版本对比、需求锚定、经验库写入、测试、覆盖率、参数扫描、SWDD 等本地副作用操作与 MCP 工具使用同一安全语义。
- **本地权限与审计闭环**：Ask 模式显示结构化确认卡；审计先记 `pending`，执行后更新 `ok / failed`；拒绝、超时和关闭均有确定结果。
- **一次性附件生命周期**：附件只随一次已成功派发的消息发送；Stop、会话关闭和面板销毁会清理临时图片，避免重复注入与临时文件泄漏。
- **确定性模块输入加固**：Git ref、文件路径、CSV/JSON、参数扫描值、Stateflow 和仿真数据读取增加边界校验与失败收敛。
- **权限 MCP 零依赖测试**：新增独立 `permissionServer` JSON-RPC 握手、工具调用、超时与异常路径测试。
- **浅色主题修复**：权限卡和次级文字显式定义对比色，真实 MATLAB 截图验证可读性。

完整条目见 [CHANGELOG.md](CHANGELOG.md)。

## 系统架构

<div align="center">
  <img src="docs/images/architecture.svg" width="900" alt="MATLAB Copilot v0.11.0 静态系统架构图">
</div>

| 层 | 当前职责 | 关键实现 |
|---|---|---|
| MATLAB / Simulink | 内嵌 UI、上下文采集、每会话配置/快照/附件、本地确定性 MBD 和本地权限 | `Panel.m`、`Context.m`、`Bridge.m`、`+matlabcopilot/*` |
| Node sidecar | 多会话注册表、adapter 生命周期、流式事件翻译、控制端口权限、审计 | `server.js`、`protocol.js`、`permissionServer.js` |
| 后端 | 推理、工具规划、回答生成；Claude 可选常驻，Codex 使用结构化 JSON 事件 | `ClaudeCodeAdapter`、`CodexAdapter` |
| MATLAB MCP | 读取、修改、测试当前已共享的 MATLAB / Simulink 会话 | `matlab-mcp-server` |

### 多会话生命周期

<div align="center">
  <img src="docs/images/session-lifecycle.svg" width="900" alt="MATLAB Copilot 多会话生命周期与竞态防护图">
</div>

`convId` 是标签、Fork 和隐藏任务的隔离键。每个会话拥有独立的 adapter、配置、上下文快照、附件队列、启动 Promise 和生命周期代次；UI 关闭会话后还保留 tombstone，忽略迟到消息。

### 一轮消息的数据流

<div align="center">
  <img src="docs/images/dataflow.svg" width="900" alt="MATLAB Copilot v0.11.0 消息数据流图">
</div>

- MATLAB 与 sidecar 使用 localhost TCP + 行分隔 JSON；线上字符串统一转为 ASCII `\uXXXX`，规避 `tcpclient` UTF-8 解码问题。
- client 端口默认 `8765`，permission control 端口默认 `8766`，可由环境变量覆盖。
- UI 首消息传完整配置；sidecar 等 adapter `ready` 后才派发消息。
- 后端事件按 `convId` 回流；MATLAB 排空所有可用行后再送入当前 `uihtml`，UI 只更新目标标签或 Fork。
- 只有真正越过派发屏障的消息才消费目标会话附件；中断和关闭只撤销并清理对应会话的资源。

## 功能全景

<div align="center">
  <img src="docs/images/features.svg" width="900" alt="MATLAB Copilot v0.11.0 功能全景图">
</div>

### AI 与模型交互

| 能力 | 当前实现 |
|---|---|
| 对话与工程问答 | Claude Code / Codex 运行时切换，思考与工具过程可视化 |
| 上下文感知 | 活动编辑器、光标与选区、当前模型/子系统/选中 block、工作区、诊断、工程文件索引、Git 状态；最近快照按会话隔离 |
| 模型解释 | 读取真实模型参数后解释当前模型或选中 block |
| 组件搜索 | 自然语言定位 block，回答标记与工具参数双通路提取路径，`hilite_system` 高亮 |
| 错误诊断 | `sldiagviewer.DiagnosticReceiver` 结构化采集，诊断卡可跳转到 block |
| 文档核实 | 优先核对 MathWorks 在线文档；不可用时降级到受限的本地 `help/which/exist/lookfor` |
| 生成到光标 | 生成代码后写入当前编辑器光标位置，替代无公开 API 的灰字补全 |
| 批量编辑与自愈 | 自然语言定位目标、逐项确认修改；run → 诊断 → 修复 → 重跑，最多三轮 |
| 画布视觉分析 | 导出 Simulink 画布图并作为图像附件交给支持视觉的 agent |

### 确定性 MBD 工程套件

| 模块 | 能力 |
|---|---|
| `ModelDiff` / `VersionDiff` | 修改前后参数、增删块和截图对比；当前模型与 Git 历史模型语义对比 |
| `ModelFileDiff` | 对记录器保存的 `.slx/.mdl` 前后快照执行隔离加载和块级语义对比，不触碰活动模型 |
| `ChangeTransaction` | `model_edit` 检查点、编译/规范门禁、失败安全回退和机器可读运行证据 |
| `ProjectChangeRecorder` | 当前工程持续记录、任务元数据、保存前后快照、AI 事务、验证矩阵、风险判断、定向测试建议和最终证据包 |
| `StandardsChecker` | 本地规则检查；支持项目级 `modeling_rules.json` |
| `TestBridge` | 发现并运行 `.mldatx`，汇总用例和决策/条件/MCDC 覆盖率缺口 |
| `ReqTrace` | `requirements.csv` 与模型 block 双向锚定，结果写入可版本化 JSON |
| `SfExplain` | Stateflow 结构提取、不可达状态和无出口逻辑检查 |
| `ImpactScan` | 修改接口、信号、变量前扫描引用和影响面 |
| `SimInsight` | 读取最近 SDI run，计算终值、超调、稳定时间和范围 |
| `ParamSweep` | 参数取值批扫、仿真与输出指标对照 |
| `KnowledgeBase` | 将有效回答沉淀到项目 `.copilot_kb/`，按错误指纹自动召回 |
| `DocGen` | 从模型确定性提取接口、参数、层级和 Stateflow，生成 SWDD 骨架 |
| 本地辅助 | MIL/SIL 对比提示、代码评审、自适应任务流、夜间批跑、并行体检 |

常用高级命令：`/mdiff`、`/sf`、`/impact`、`/siminsight`、`/sweep`、`/silcheck`、`/swdd`、`/checkup`、`/night`。输入 `? 你的需求` 可在本地匹配功能，无需记忆命令。

### 会话与交互

- 多标签页、每页独立配置和后端会话；任意助手卡片可 Fork 为嵌套分支。
- 按项目保存历史并恢复；支持导出 Markdown、`/compact` 摘要播种和成本累计。
- 回答选区右键批注、多便签合并追问、黄色原文锚点。
- 回答期间支持队列或引导模式，`Esc` / Stop 中断并清理待处理任务。
- 长对话轮次导航轨、悬停预览、点击跳转与 scroll-spy。
- 文本、代码和图片附件；输入框可直接粘贴截图。
- 快捷功能支持隐藏、单行横向浏览和全部多行展开三种形态；单行模式隐藏滚动条，可用鼠标滚轮、触控板或左右箭头浏览，输入框保持不变。
- Light、Dark、跟随 MATLAB 三种主题；UI 单文件、无 CDN。

## 权限与安全

<div align="center">
  <img src="docs/images/permission.svg" width="900" alt="MATLAB Copilot v0.11.0 权限与安全逻辑图">
</div>

| 模式 | 只读操作 | 修改模型/写文件 | 执行 MATLAB / shell / 测试 | MATLAB 本地确定性副作用 |
|---|---|---|---|---|
| Ask | 自动允许 | 显示确认卡 | 显示确认卡 | 显示确认卡 |
| Auto | 自动允许 | 自动允许并审计 | 仍显示确认卡 | 按操作类别确认并审计 |
| Plan | 自动允许 | 强制拒绝 | 强制拒绝 | 强制拒绝 |

安全不变量：

- 不使用 `--dangerously-skip-permissions` 或 Codex 的危险绕过参数。
- 面板未连接、确认超时 180 秒、控制连接断开和会话关闭都默认拒绝。
- 本地文档自省只允许单条 `help/which/exist/lookfor`；零字段或多个代码字段都不自动放行。
- MCP 与 MATLAB 本地动作都写审计轨迹；状态从 `pending` 更新到真实执行结果。
- `/mdiff` 只接受受限 Git ref，并使用参数化进程调用，避免命令拼接。

审计日志默认写入 `~/.matlab-copilot/audit-*.jsonl`，面板内可查看会话操作留痕。工程变更记录保存在 `~/.matlab-copilot/change-records/<projectHash>/<sessionId>/`，不写回被监视工程。

工程记录器不向模型注入 `PostSaveFcn` 或其他回调，因此不会修改用户模型配置。人工或脚本编辑在文件保存后进入记录；尚未保存的 AI `model_edit` 由 `ChangeTransaction` 通道即时进入时间线。单文件默认上限为 50 MB，生成目录、Git 元数据与 `node_modules` 自动忽略。

## 快速开始

### 前置条件

| 组件 | 要求 |
|---|---|
| MATLAB | R2023b+，需要 Simulink；当前 Release 在 R2025b 完成实机验证 |
| Node.js | 20 或更高；sidecar 无运行时 npm 依赖 |
| AI 后端 | Claude Code 或 Codex CLI，至少安装并登录一个 |
| MATLAB MCP | Simulink Agentic Toolkit 与 `matlab-mcp-server`；需要调用模型工具时执行 `satk_initialize` |

### 安装与启动

从 [Releases](https://github.com/suzike/matlab-simulink-copilot/releases/latest) 下载 `MATLAB-Copilot.mltbx`，双击安装，或在 MATLAB 中执行：

```matlab
matlab.addons.install('MATLAB-Copilot.mltbx')
satk_initialize
copilot_doctor()
copilot
```

源码运行：

```matlab
addpath('E:/path/to/matlab-simulink-copilot/matlab')
satk_initialize
copilot
```

完整安装、登录、端口、故障排查和卸载步骤见 [INSTALL.md](INSTALL.md)。

## 目录结构

```text
matlab/
  copilot.m                       启动、共享 MATLAB 会话
  copilot_doctor.m                环境与 MCP 自检
  build_toolbox.m                 生成 MATLAB-Copilot.mltbx
  +matlabcopilot/
    Panel.m                       内嵌界面、事件路由、多会话、本地权限
    Bridge.m                      sidecar 进程与 ASCII TCP 协议
    Context.m                     MATLAB/Simulink/工程上下文
    ChangeTransaction.m           模型变更检查点、验证、回退与运行清单
    ModelFileDiff.m               已保存模型快照的隔离语义对比
    ModelDiff.m ... DocGen.m      确定性 MBD 工程模块
ui/
  index.html                      单文件聊天 UI，无 CDN
sidecar/
  src/server.js                   多会话、配置屏障、权限、审计
  src/permissionServer.js         零依赖 MCP JSON-RPC 权限服务
  src/projectChangeRecorder.js    工程文件基线、快照、时间线与报告
  src/adapters/                   Claude Code / Codex / Echo
  test/                           72 个测试，12 个测试文件
docs/images/                      真实 MATLAB 截图与静态 SVG 图
```

架构细节、协议字段、后端命令、历史故障与扩展规则见 [AGENTS.md](AGENTS.md)。

## 开发与验证

Sidecar：

```powershell
Set-Location sidecar
npm test
```

完整 Release 自动门禁：

```powershell
Set-Location sidecar
npm ci
npx playwright install chromium
npm run release:verify
```

MATLAB 静态和类加载验证：

```matlab
addpath('matlab')
checkcode('matlab/+matlabcopilot/Panel.m', '-id')
meta.class.fromName('matlabcopilot.Panel')
```

构建工具箱：

```matlab
run('matlab/build_toolbox.m')
```

对最终安装包执行非破坏性 MATLAB 验收并生成机器可读报告：

```matlab
addpath('matlab')
release_acceptance('MATLAB-Copilot.mltbx', ...
    ReportFile='_verify/matlab-release-acceptance.json')
```

详细发布步骤和受保护的 Add-On 安装验收见 [Release 验收清单](docs/RELEASE_CHECKLIST.md)。

当前主分支发布门槛包括：72 个 sidecar 测试、22 项 Playwright 桌面/窄屏回归、UI 两段脚本语法检查、MATLAB `checkcode` / 类加载与 8 项真实 Simulink 事务/快照/辅助逻辑测试、真实 Panel 截图、最终 `.mltbx` 验收、SHA-256 生成和 GitHub Release 资产校验。

## 已知边界

- Simulink 新版右键菜单使用扩展点 API，当前稳定入口是面板中的“解释选中”。
- MATLAB 未公开编辑器灰字补全 API，当前使用“生成到光标”。
- AppContainer 真侧栏依赖未公开 API，当前使用受支持的 `uifigure` docking 方案并保留 normal window 兜底。
- 当前云端后端只有 Claude Code 与 Codex，不包含 Ollama 离线后端。
- MATLAB 桌面只有一个实时活动状态；各标签保存自己的最近快照，但切回标签时会按当前 MATLAB 状态刷新。

## License

见 [LICENSE](LICENSE)。
