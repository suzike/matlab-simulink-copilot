# MATLAB Copilot v0.10.2 — 安装与使用指南

**MATLAB Copilot** 是一个内嵌进 MATLAB / Simulink 界面的 AI 助手侧边栏（类似 VS Code 里的 Copilot 侧栏）。它停靠在 MATLAB 窗口内，能自动感知你当前打开的文件、模型、选中的模块、工作区变量和最近的报错，并通过对话帮你解释、修改、测试模型与代码。

---

## 目录

1. [它是怎么工作的（建议先读）](#它是怎么工作的)
2. [前置条件](#前置条件)
3. [安装步骤](#安装步骤)
4. [首次使用](#首次使用)
5. [界面速览](#界面速览)
6. [进阶配置](#进阶配置)
7. [常见问题（FAQ）](#常见问题)
8. [升级与卸载](#升级与卸载)

---

## 它是怎么工作的

理解这一点能帮你在出问题时快速定位。MATLAB Copilot 由**三个独立的部分**组成，缺一不可：

| 部件 | 角色 | 谁提供 |
|------|------|--------|
| **UI 外壳**（本工具箱） | 停靠面板 + 聊天界面 + 上下文采集 | `MATLAB-Copilot.mltbx` |
| **AI 大脑** | 真正思考、生成回答的大模型 | 你自己的 **Claude Code** 或 **Codex** CLI（绑定你的账号/订阅） |
| **操作 MATLAB 的手** | 让 AI 能读写你的模型/工作区 | **MATLAB MCP Server**（Simulink Agentic Toolkit 提供） |

> **为什么 AI 大脑和手要你自己装？** 因为它们绑定你的账号、订阅和本机 MATLAB 会话，无法、也不应该打包进工具箱。工具箱只负责把这两者"接进 MATLAB 界面"。

数据流向（出问题时对照排查）：

```
你在面板里输入 → MATLAB 采集当前上下文 → 本地 Node 进程(sidecar)
   → 调用 Claude/Codex CLI 思考 → CLI 通过 MATLAB MCP 读写你的模型
   → 流式把回答推回面板显示
```

---

## 前置条件

安装前请确认以下四项都就绪。每项都给了**验证方法**。

### 1. MATLAB R2023b 及以上（推荐 R2025b）

- 必须含 **Simulink**。
- 验证：MATLAB 命令窗口输入 `version` 应显示 `25.x` 或更高。

### 2. Node.js ≥ 20 LTS

- 下载：[nodejs.org](https://nodejs.org)（选 LTS 版本）。
- 验证：**操作系统的终端**（不是 MATLAB）里运行 `node --version`，应显示 `v20` 或更高。
- ⚠️ **关键**：装完 Node.js 后，**重启 MATLAB**，否则 MATLAB 可能看不到它（详见 FAQ 第一条）。

### 3. AI 后端 CLI（二选一）

| 后端 | 安装命令 | 登录 | 需要 |
|------|----------|------|------|
| **Claude Code**（推荐） | `npm install -g @anthropic-ai/claude-code` | `claude login` | 有效的 Anthropic 账号/订阅 |
| **Codex** | `npm install -g @openai/codex` | `codex login` | 有效的 OpenAI 账号 |

- 验证：终端运行 `claude --version`（或 `codex --version`）能输出版本号。
- 至少装一个；两个都装可在面板里随时切换。

### 4. Simulink Agentic Toolkit（提供 MATLAB MCP Server）

- 在 MATLAB 里安装（见下方步骤 3）。
- 验证：安装后 `exist('satk_initialize')` 返回非 0。

---

## 安装步骤

### 步骤 1 — 安装工具箱

在 MATLAB 中**双击** `MATLAB-Copilot.mltbx`，或在命令窗口运行：

```matlab
matlab.addons.install('MATLAB-Copilot.mltbx')
```

**怎么算成功**：MATLAB 主页 → 附加功能 → 管理附加功能，能看到 "MATLAB-Copilot"。

> **关于依赖**：sidecar（本地编排进程）是**零 npm 依赖**的——不含 `node_modules`，**不需要 `npm install`**。这也是 0.6.0 版相对旧版的重要修复：旧版打包了庞大的 `node_modules`，其深层路径在 Windows 上会超过 260 字符上限（MAX_PATH）导致文件丢失、权限模块起不来。

---

### 步骤 2 — 安装并登录 AI 后端

以 Claude Code 为例（在**操作系统终端**里运行，不是 MATLAB）：

```bash
npm install -g @anthropic-ai/claude-code
claude login
```

> 用 Codex 后端就换成：`npm install -g @openai/codex && codex login`

**怎么算成功**：`claude login` 走完浏览器授权后，运行 `claude --version` 能输出版本号。

---

### 步骤 3 — 安装 Simulink Agentic Toolkit（MATLAB MCP Server）

1. MATLAB 主页 → **附加功能** → 搜索 `Simulink Agentic Toolkit` → **安装**。
2. 安装完成后，在 MATLAB 命令窗口运行：

```matlab
satk_initialize
```

这会把**当前这个 MATLAB 会话**共享出去，让 AI 能 attach 到它、读写你的模型和工作区。

**怎么算成功**：`satk_initialize` 无报错完成。

> ⚠️ **保持单个 MATLAB 实例**：MCP 会 attach 到"最后一个共享会话"的实例。如果同时开了多个 MATLAB，AI 可能连到错误的那个。

---

### 步骤 4 — 运行环境自检

```matlab
copilot_doctor()
```

它会逐项检查并打印结果，覆盖：

- ✅ Node.js ≥ 20
- ✅ 后端 CLI（claude / codex）
- ✅ MATLAB MCP Server
- ✅ MATLAB 会话共享（satk_initialize）
- ✅ Sidecar 源码（零依赖）
- ✅ 通信端口 8765

**全部 `✓` 即可进入下一步**；任何 `✗` 项，按它给出的提示修复后再次运行。

---

### 步骤 5 — 启动

```matlab
copilot
```

面板会**停靠在 MATLAB 界面内**。底部状态变为"已就绪 / 已连接"即可开始对话。

| 启动方式 | 命令 |
|----------|------|
| 默认（Claude 后端，当前文件夹为工作目录） | `copilot` |
| 指定 Codex 后端 | `copilot(Backend="codex")` |
| 不连 MATLAB 的纯界面联调（无需 CLI） | `copilot(Backend="echo")` |

---

## 首次使用

打开一个 Simulink 模型，然后在面板里试这几句，感受上下文感知与操作能力：

1. **「解释当前模型」** —— AI 会调用工具读取模型结构，弹出工具调用卡片后给出讲解。
2. **「把某个 Gain 模块改成 2」** —— 会弹出一张**确认卡片**（带改动预览），你点确认后才真正改模型。
3. 制造一个报错，再点工具栏的 **🩺 诊断报错** —— AI 抓取报错 + 上下文，给出根因和修复建议。

> 选中模型里的一个模块，再点 **🧩 解释模块**，AI 会读它的真实参数逐个精准说明。

---

## 界面速览

### 工具栏（顶部）

- **后端切换**：一键在 Claude Code ↔ Codex 之间切换。
- **模型下拉**：选择具体模型（自动读取你的 CLI 配置 + 常用预设）。
- **思考强度**：低 / 中 / 高。
- **编辑模式**（重要，决定权限松紧）：
  - **Ask before edits**（默认）：每次改模型/跑代码都弹确认卡。
  - **Edit automatically**：改模型/写文件自动放行，但**运行代码/跑测试仍要确认**。
  - **Plan**：只读探索、**绝不改动**。v0.10.0 起不仅 sidecar/MCP 强制拒绝，版本对比、需求锚定、测试、覆盖率、参数扫描、SWDD 等 MATLAB 本地副作用操作也使用同一门禁。
- **⚡ 常驻**：仅 Claude Code 可用。开启后后端进程常驻，消除每轮冷启延迟（见进阶配置）。

### 快捷动作（按需点用）

🩺 诊断报错、📖 解释选中、💬 加注释、🧪 生成测试、✔ 标准检查、🔍 查找模块、🧩 解释模块、📖 查文档、⚙ 任务流、🔄 自愈运行、📋 需求追溯、🔬 代码评审、🪄 批量编辑、🧪▶ 测试编排、📸 截图分析、↳ 生成到光标。

> 鼠标悬停在任一按钮上约 2 秒，会弹出它的详细用途和用法说明。
> 其中 **🔍 查找模块 / 🪄 批量编辑 / 📖 查文档** 需要**先在输入框写描述，再点按钮**。

### 对话中的交互（批注 / 插入 / 中断）

- **📝 选区批注 / 便签追问**：回答太长、只想追问其中一段时，在助手气泡里**选中那段文字 → 右键**（或点气泡的 ✚ 批注），弹出批注框写下疑问。可以**连续批注多段**，每条都以**便签卡片**贴在输入框上方，被批注的文字会**持续黄色高亮**；写完一起发送，AI 就知道你针对的是哪几处。
- **⏸ 回答中插入新指令**：AI 还在回答时，你可以直接输入下一条需求。底部图标栏的模式开关决定它怎么处理：
  - **队列**：排队等当前回答结束后自动逐条发送，排队项在**右下角灰显回显**。
  - **引导**：立即打断当前回答，优先执行你的新指令。
- **⌨ Esc 中断**：回答过程中按 `Esc`（或点 **Stop**）立即中断本轮。
- **每条回答都可** 复制 / 批注 / Fork（按钮在气泡角上，配色区分）。

### 🧭 对话轮次导航轨（长对话快速跳转）

对话超过 3 轮后，**左侧会出现一条紧凑的导航轨**（一组短刻度），把整段对话的「轮次」索引成一条可视的竖条：

- **悬停刻度** → 弹出该轮的预览卡：用户问、调用过的工具、`💬 回合数` / `✓ ✕ 工具状态` / `⟨⟩ 代码` / `◈ diff` 徽章，一眼看清那轮干了什么。
- **点击刻度** → 平滑滚动跳到那一轮并整轮高亮，免去长滚动翻找。
- 滚动时当前所在轮的刻度会高亮（知道「我在哪」）。刻度会自适应压紧、不会铺满整条，导航轨本身永远不需要滚动。每个标签页各自独立。

### 斜杠命令

在输入框打 `/` 弹出命令菜单（支持按中文描述搜索，如打 `/文档` 能搜到 `/swdd`），或按 `Ctrl+K` 打开。

**本地高阶命令**（确定性模块，零 token 秒回）：

| 命令 | 作用 |
|---|---|
| `/mdiff HEAD~1` | 当前模型 vs git 历史版本的语义对比（参数/增删块/截图） |
| `/sf` | Stateflow 解析：状态机结构 + 不可达/无出口死逻辑 |
| `/impact 信号名` | 改接口前扫"谁在用它"（点击结果跳画布） |
| `/siminsight` | 最近一次仿真的 超调/稳定时间/曲线 分析 |
| `/sweep Kp 0.5,1,2` | 标定参数批扫仿真 → 取值×输出对照表 |
| `/silcheck` | MIL vs SIL 一致性验证（需 Embedded Coder） |
| `/night 23:30 任务一; 任务二` | 夜间定时批跑，完成自动导出晨报（`/night off` 取消） |
| `/checkup` | 3 个子会话并行体检（结构/风险/可测性）并汇总 |
| `/swdd` | 从模型生成 SWDD 设计文档骨架 + AI 补全 |

另有配置类（`/model` `/mode` `/think` `/claude` `/codex`）、操作类（`/explain` `/fix` `/test` `/batch` `/testflow` 等）、UI 类（`/clear` `/context` `/export` `/compact`）。

### 🧭 记不住功能?两个兜底

- **「? 需求」入口**：输入框打 `? 想看这次改了什么` 回车 → 本地秒匹配出候选功能，点击即执行；匹配不到可一键"让 AI 帮我选"。
- **情境自动建议**：出报错时提示 🩺 诊断、AI 连续改模型时提示 ✔ 复核规范、工具失败时提示 🔄 自愈——每类只提醒一次，可点可关。

### 📁 项目配置文件约定（放 MATLAB 工程根目录）

| 文件 | 作用 | 模板 |
|---|---|---|
| `modeling_rules.json` | 建模规范检查规则（缺省用内置 MAB 子集） | `docs/modeling_rules.example.json` |
| `requirements.csv` | 需求清单（飞书多维表格「导出 CSV」即可） | `docs/requirements.example.csv` |
| `req_links.json` | 需求↔block 锚定关系（面板操作自动生成，可进 git） | 自动生成 |
| `.copilot_kb/` | 团队经验库(📌 存经验生成,建议进 git 共享) | 自动生成 |

### 会话管理

- **多标签页**：顶部 `＋` 新建，每个标签是独立对话 + 独立后端会话 + 独立配置。
- **自动恢复**：会话历史按项目落盘，重启 MATLAB 后自动恢复（会标注"后端上下文已重置"）。
- **⬇ 导出**：把当前对话导出为 Markdown 文件。
- **成本显示**：Claude 后端会显示本标签累计 token 费用。

### 权限与安全

- 破坏性操作（改模型、跑代码、跑测试）默认都会**弹确认卡片**，你看清改动再决定。
- 面板未连接时，破坏性操作**默认拒绝**。
- 只读操作（读模型、查文档）自动放行，不打扰你。

---

## 进阶配置

### `copilot` 命令参数

```matlab
copilot(Backend="claude", Cwd=pwd, Port=8765, ControlPort=8766, NodeBin="node")
```

| 参数 | 默认 | 说明 |
|------|------|------|
| `Backend` | `"claude"` | `"claude"` / `"codex"` / `"echo"` |
| `Cwd` | 当前文件夹 | AI 的工作目录 |
| `Port` | `8765` | sidecar 通信端口 |
| `ControlPort` | `8766` | 权限确认端口 |
| `NodeBin` | `"node"` | Node 可执行文件路径（PATH 找不到时填全路径） |

### 环境变量（在启动 `copilot` 前 `setenv`）

```matlab
setenv('MATLAB_COPILOT_PERSISTENT', '1')   % 默认开启 Claude 常驻模式
setenv('MATLAB_COPILOT_PORT', '9000')      % 改通信端口
setenv('MATLAB_COPILOT_MODEL', 'sonnet')   % 指定默认模型
```

- `MATLAB_COPILOT_PERSISTENT=1`：等价于工具栏开 ⚡ 常驻；进程常驻、每轮免冷启，进程意外退出会自动 resume 重启。
- `MATLAB_COPILOT_PORT` / `MATLAB_COPILOT_CONTROL_PORT`：端口冲突时改这两个（也可以用上面的 `copilot(Port=..., ControlPort=...)`）。

---

## 常见问题

**Q: 启动后 copilot 面板一直"连接中"，或 `copilot_doctor` 报 Node.js 找不到？**
A: 最常见原因是 **MATLAB 看不到 Node.js 的 PATH**（尤其刚装完 Node 没重启 MATLAB）。
- 首选：**完全关闭并重启 MATLAB**，让它重新读取系统 PATH。
- 临时修复：在 MATLAB 命令窗口执行（按你的实际安装路径调整）：
  ```matlab
  setenv('PATH', [getenv('PATH') ';C:\Program Files\nodejs'])
  ```
  然后重新 `copilot`。
- 或在启动时直接指定 Node 全路径：`copilot(NodeBin="C:\Program Files\nodejs\node.exe")`。

**Q: 报错 `MCP tool mcp__approval__approval ... not found`（matlab 工具都在、唯独 approval 缺失）？**
A: 这是旧版本（≤ 0.5.0）的已知问题：旧包打包了 `node_modules`，其深层路径装到 `AppData\…\MATLAB Add-Ons\…` 后超 Windows 260 字符上限（MAX_PATH），文件丢失 → 权限模块起不来。**0.6.0+ 已根治**（sidecar 改为零依赖、不再打包 node_modules）。请**卸载旧版、安装 0.6.0+ 的 `.mltbx`**。
> 旁证：把源码文件夹直接加到 MATLAB 路径不报错，正是因为源码目录路径短、依赖完整。

**Q: `satk_initialize` 说找不到函数？**
A: 还没装 MATLAB MCP Server。先在 附加功能 里安装 **Simulink Agentic Toolkit**，再运行。

**Q: 换了 / 重开了 MATLAB 实例后 AI 失去连接？**
A: 在**新实例**里重新运行 `satk_initialize`，然后重启 `copilot`。同时确保没有多个 MATLAB 实例争用会话。

**Q: AI 连到了错误的模型 / 工作区？**
A: 多半是开了多个 MATLAB 实例。MCP 会 attach 到最后一个 `satk_initialize` 的实例。保持单实例，或在目标实例里重新 `satk_initialize`。

**Q: 用 Codex 后端感觉每轮响应都很慢？**
A: 这是 Codex CLI 自身的冷启动特性（每轮重新拉起进程，单轮可达数十秒）。追求速度建议改用 **Claude Code** 后端，并开启 ⚡ **常驻模式**（工具栏开关，或设 `MATLAB_COPILOT_PERSISTENT=1`），后端进程常驻、消除每轮冷启延迟。

**Q: 端口 8765 / 8766 被占用？**
A: 用环境变量或 `copilot` 参数换端口，**不要去改源码**：
```matlab
copilot(Port=9000, ControlPort=9001)
```
或先 `setenv('MATLAB_COPILOT_PORT','9000')` 再启动。常见占用来源是上一次没关干净的 copilot 实例。

**Q: 面板关不掉 / 重新加载类报错？**
A: 重建时遵循顺序——**先关面板，再 `clear classes`**：
```matlab
delete(findall(0,'Type','figure'))   % 先关掉所有面板窗口
clear classes                        % 再重置类
copilot                              % 重新启动
```

**Q: 第一次回答很慢 / WebFetch 查文档失败？**
A: Claude 首轮要拉起进程稍慢属正常（开常驻模式可缓解）。查文档走在线抓取 MathWorks 文档，网络不稳时会自动降级到本机 `help` 兜底，并在答案里标注，不影响使用。

---

## 升级与卸载

### 升级到 v0.10.2

1. 下载 v0.10.2 的 `MATLAB-Copilot.mltbx`。
2. 关闭现有 Copilot 面板后安装新包。
3. 运行 `copilot_doctor()`，确认 Node、后端 CLI、MATLAB MCP、会话共享、sidecar 文件和端口检查通过。
4. 发布维护者可运行 `release_acceptance('MATLAB-Copilot.mltbx')`，从最终安装包执行类加载、静态检查和 Echo TCP 冒烟。
5. 打开两个标签或一个 Fork，分别添加文件；切换后应只看到目标会话自己的附件。

### 从旧版本升级到 v0.10.0 的权限变化

1. 先**卸载旧版**（见下）。
2. 安装新的 `MATLAB-Copilot.mltbx`。
3. 运行 `copilot_doctor()` 确认全绿，再 `copilot`。
4. 在“Plan”模式尝试测试或版本对比时，应看到操作被直接拒绝；切到“Ask”后应出现结构化确认卡。这是 v0.10.0 本地权限门禁正常工作的验证方式。

> 从源码自行打包新版：在 `matlab/` 目录下运行 `build_toolbox`，会在仓库根生成最新的 `MATLAB-Copilot.mltbx`（不含 node_modules，体积很小）。

### 卸载

MATLAB 主页 → 附加功能 → 管理附加功能 → 找到 **MATLAB-Copilot** → 卸载。

> 卸载只移除 UI 工具箱，不会动你的 Claude/Codex CLI 和 Simulink Agentic Toolkit。
