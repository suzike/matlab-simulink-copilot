# AGENTS.md — 给在本仓库工作的 AI agent 的工作手册

> 目的:把本项目的架构、协议、各后端调用方式、**所有踩过的坑(含原因)**、扩展方法固化下来,
> 让上下文压缩 / 新会话后仍能无损接续。配套 `plan.md`(进度)、`README.md`(用法)。
> 环境:Windows 11,MATLAB R2025b(`D:\Software\Matlab2025b`),Node v25,bash(Git Bash)。

## 0. 一句话

MATLAB 内嵌侧边栏 AI 助手:`uihtml` 面板 ⇄ MATLAB ⇄ 本地 Node sidecar ⇄ headless 后端(Claude Code / Codex)⇄ 复用的 MATLAB MCP。

## 1. 数据流(必须牢记)

```
JS(ui/index.html)
  │  sendEventToMATLAB(name, data)              JS → MATLAB
  ▼
Panel.onHtmlEvent(evt)  → Bridge.send(struct)   组装上下文后下发
  │  tcpclient writeline(asciiJson(jsonencode))  MATLAB → sidecar(全 ASCII 行 JSON)
  ▼
server.handleClientLine → adapter.sendMessage()
  │  spawn 后端 CLI,stdout 行 → 翻译成 OutMsg 事件
  ▼
adapter 'event' → server.toClient → tcpclient    sidecar → MATLAB
  │  Bridge.onData 排空所有行 → Panel.onSidecarMessage → pushToUi
  ▼
sendEventToHTMLSource(HTML,'sidecar', asciiJsonString)  MATLAB → JS(传字符串!)
  │  JS onSidecar(JSON.parse) → 渲染
```

权限走**另一条** TCP(控制端口):后端的 `--permission-prompt-tool` MCP(`permissionServer.js`)回连 sidecar 控制端口 → 只读自动放行 / 破坏性转 UI 确认卡 → 用户点击 → 回传 decision。

## 2. 端口 / 文件

- 默认端口:client `8765`、control `8766`(env `MATLAB_COPILOT_PORT` / `..._CONTROL_PORT`)。
- 发现文件:`%TEMP%/matlab-copilot-sidecar.json`(pid/端口/backend)。
- 日志:`%TEMP%/matlab-copilot-sidecar.log`、各后端自己的日志。
- 启动成功标志:sidecar 向 stdout 打 `SIDECAR_READY {...}`(Bridge 解析它判断就绪)。

## 3. 协议(sidecar/src/protocol.js)

**InMsg(UI/MATLAB → sidecar)**:`user_message`(含 context、可选 intent=insert_at_cursor、可选完整 config)、`interrupt`、`permission_response`、`ping`、`set_config{config}`、`get_capabilities`、`slash_command{name,args,context,config?}`、`close_conv`。**多会话**:大多 InMsg 带 `convId`(标签页/分支 id,缺省 `main`);OutMsg 也都带 `convId` 供 UI 路由。`permission_request`/`permission_response` 带 convId;权限 pending 用 `convId::id` 复合键。新标签/Fork/隐藏体检会话的首条消息必须携带 UI 继承的完整 config，让 sidecar 在创建 adapter 前原子应用。MATLAB-only 事件另加 `copy_text`(走 `clipboard('copy')`)。

**OutMsg(sidecar → UI)**:`ready`、`status`、`thinking_start/delta/stop`、`assistant_start/delta/stop`、`tool_use`、`tool_result`、`permission_request`、`result`、`error`、`pong`、`capabilities`、`config_changed`、`audit{entry}`(破坏性操作审计轨迹,落 `~/.matlab-copilot/audit-*.jsonl` + 推「变更记录」)。

**MATLAB 直接推给 UI 的事件**(不经 sidecar,`Panel.pushToUi`):`context`、`theme{mode}`、`user_echo{text}`、`attachments{files}`、`diagnostics{items}`(结构化诊断卡片)、`status`、`error`。

**仅 MATLAB 处理的 UI 事件**(不下发 sidecar):`ui_ready`、`diagnose_error`(结构化诊断)、`ask_at_cursor`、`request_context`、`request_theme`、`find_block{query}`(🔍查找模块)、`explain_selected`(🧩解释模块)、`jump_block{path}`(诊断卡片跳转高亮)、`run_tasks`(⚙ 自适应任务流)、`self_heal`(🔄自愈环)、`capture_model`(📸截图分析)、`requirements`(📋需求追溯)、`codegen_review`(🔬代码评审)、`batch_edit{query}`(🪄批量编辑)、`test_orchestrate`(🧪▶测试编排)、`attach_file`(任意类型;图片→视觉)、`attach_image{name,dataUrl}`(粘贴图片:base64→临时 PNG)、`copy_text`、`close_conv`、`clear_attachments`、`remove_attachment{index}`。附件 struct 统一 `{name,content,path,isImage}`:文本嵌 content,图片给 path 让 agent 用 Read 读图(preamble 在 `types.js`)。这些 MBD 快捷动作的 handler 均走同一模式(采集 context → 构造 prompt → `Bridge.send(user_message)`);`onHtmlEvent` 顶层 try/catch 兜底:出错发 `error` 事件解除 UI busy + 复位 `PendingFind/PendingInsert`。

序列化必须用 `serialize()`(把非 ASCII 转 `\uXXXX`)。行缓冲 `createLineBuffer`。

## 4. 后端适配器(sidecar/src/adapters/)

基类 `BackendAdapter`(EventEmitter):`start/sendMessage/interrupt/stop`,子类 `emitEvent(OutMsg)`。
`makeAdapter(state)` 在 `index.js`,按 `state={backend,model,effort,mode}` 造适配器;`Server.applyConfig` 运行时重建。

### ClaudeCodeAdapter
- 命令:`claude --print --output-format stream-json --include-partial-messages --verbose`
  - `--resume <session_id>`(多轮)、`--model`、`--allowedTools`(预批只读)、
  - `--permission-mode <acceptEdits|plan>`(ask=不加)、`--mcp-config <file> --strict-mcp-config`、
  - `--permission-prompt-tool mcp__approval__approval`、`--append-system-prompt`。
- MCP 配置文件由 `index.js` 生成:**只含 `approval` + `matlab`**(`--strict-mcp-config` 防止按 cwd 加载到无关项目级 MCP)。
- thinking:`buildEnv` 设 `MAX_THINKING_TOKENS`(effort→token:low/med/high=2000/8000/16000)。
- 流式:`streamJsonParser.js` 把 `stream_event`(message_start / content_block_start/delta/stop / message_stop)翻译;text_delta→assistant、thinking_delta→thinking;ASSISTANT_START **懒发**(首个 text_delta 才发,避免纯思考/工具消息留空气泡)。
- **常驻模式(opt-in,`MATLAB_COPILOT_PERSISTENT=1` 或 UI ⚡ 开关 → `persistent: true`)**:`start` 预热常驻进程(`--input-format stream-json`),每轮往 stdin 写一行 `{type:'user',message:{...}}`(不关 stdin),跨轮复用一个 translator;消除每轮冷启。**故障安全**:进程意外退出 → 下轮以 `sessionId` resume 重启;中断 → kill+resume;`resetSession`(/compact)→ kill 换新 session;per-turn systemPrompt(insert)→ 指令并入消息文本(常驻无法热换 system prompt)。默认仍走可靠的 resume 模式(`sendOneShot`)。
- **并发安全(两后端一致)**:`this.child`/中断标记**跨异步边界**易竞争(同步 kill+立即新建 vs 异步 close 回调)。统一做法:close/error/stdin-error 回调**闭包捕获这一代 child**,用 `if (this.child === child)` 守卫只清自己这代;中断标记用 **per-child `child._killing`**(非实例级共享);常驻模式用独立 `busy` 标志判忙(child 长存不能靠它);spawn 后必挂 `stdin.on('error')` 防 EPIPE 冒泡 crash。Server 会话另有 `ready/generation/dispatchEpoch/closed` 屏障:配置重建期间消息等新 adapter,Stop 取消待派发消息,旧 adapter 迟到事件和关闭后的异步重建均丢弃。

### CodexAdapter
- 命令:`codex exec --json --skip-git-repo-check --color never --ignore-user-config -C <cwd> -s <sandbox> -m <model> -c model_reasoning_effort="<e>"`
  - 多轮:在 `exec` 后插 `resume <thread_id>`。
  - **`--ignore-user-config` 是提速关键**(甩掉用户 ~/.codex 的 184 skills + 卡顿 MCP,64s→~25s),再用 `-c mcp_servers.matlab.command/args` **重新注入 matlab MCP**(路径用正斜杠避开 TOML 反斜杠转义)。
- 事件:`thread.started`(存 thread_id)、`turn.started`、`item.completed{item}`、`turn.completed{usage}`。
  - item.type:`agent_message`→assistant(整条)、`reasoning`→thinking、`command_execution`→Bash 工具卡、`mcp_tool_call`→工具卡、`error`→错误(过滤 skills-budget / websocket 回退噪声)。
- 注意:Codex 按**完整 item** 推送(无逐 token),所以助手气泡一次成型。Codex 用 OpenAI 鉴权(`codex login`),与 ANTHROPIC 无关。
- **收尾必达(防 UI 卡死)**:UI 靠 `RESULT` 解除 thinking/busy。Codex 三处都要补 RESULT:① `turn.completed`(正常)② `turn.failed` → ERROR + `RESULT{ok:false}` ③ **进程结束但没拿到 turn.completed**(中途退出/卡断/事件格式异常)→ close 兜底补 RESULT(这是「只回一下就没反应」的根因)。再加**空闲看门狗**(180s 完全无 stdout 输出且未结束 → kill+补 RESULT,基于「静默」非总时长,不误杀慢响应)防进程 hang 不退出。

### EchoAdapter
无依赖回显;演示「思考流 + 富文本回复」,用于验证整条 UI 链路。

### 模式映射(makeAdapter + 控制端口)
- claude `--permission-mode`:ask=null / auto=acceptEdits / plan=plan;codex `-s` 沙箱:ask=read-only / auto=workspace-write / plan=read-only。
- **关键**:`acceptEdits` 只覆盖 claude **自带**工具,MATLAB **MCP 工具**(`model_edit` 等)的放行由 `server.js:handleControlLine` 按 `config.mode` 决定:
  - 只读工具 + **只读文档自省**(`evaluate_matlab_code` 内容仅 `help/which/exist/lookfor` 单条调用,`config.js:isSafeIntrospection`,供 WebFetch 失效时本地文档兜底)恒自动放行;
  - `ask` → 其余破坏性工具转 UI 确认;
  - `auto` → 非执行类(改模型/写文件)自动放行,**执行类**(`isExecuteTool`:`run_matlab_file`/`evaluate_matlab_code`/`model_test`/`Bash`)仍转 UI 确认;
  - `plan` → 破坏性工具一律**自动拒绝**(强制只读,只读工具仍放行);MATLAB 侧本地确定性写入/仿真/测试也由 `ConfigByConv` 执行同一门禁,不能通过本地权限卡绕过。
  - 转 UI 的确认请求 **180s 超时默认拒绝**(`unref` 不阻塞退出);control 连接断开清理该 sock 的悬挂 pending(防 Map 泄漏)。`isSafeIntrospection` 的 `extractEvalCode` 收全部代码字段,**多于一个或为零一律不放行**(防校验/执行字段错位绕过)。审计 status 初值 `pending`(待 TOOL_RESULT 转 ok/failed,不谎称已执行);`/compact` 进行中切后端会重置 `compacting` 防卡死。

## 5. MATLAB 端(matlab/+matlabcopilot/)

- `Panel`:建 `uifigure`(`WindowStyle='docked'` try/catch 兜底)+ 铺满 `uihtml`;`onHtmlEvent` 路由 UI 事件;`onSidecarMessage`→`pushToUi`;insert 模式吞气泡只插光标;`Attachments` 附件(文本嵌 content / 图片给 path,`handleAttachFile` 任意类型 + `handleAttachImage` 粘贴图片 base64 写临时 PNG);`pushContext`(发消息时刷新顶栏);`Diag`(常驻 `Diagnostics`);`PendingFind` 查找模块状态机(累积助手文本 + 嗅探工具入参 → `applyHilite`);`explainSelected` 就地解释;`handleRunTasks`(`Tasks`);`detectTheme`(静态)。**多会话**:`ActiveConv` 跟踪当前标签页,`ConfigByConv` 保存完整 per-conv 配置;`PendingFindConv/PendingInsertConv` 只消费发起会话回包并在 Stop/Esc/关闭/中断回执时清理。所有转发后端的消息(`user_message`/`interrupt`/`set_config`/`slash`/`close_conv` 及诊断/查找/解释/任务流)都带 `convId`,首消息还带完整 config;MATLAB 自发的 `user_echo`/`diagnostics` 也带 convId。**无常驻刷新定时器**;单例靠静态 `findActive()` 按图窗 `UserData` 找(不留 persistent);`onClose` 无条件删窗口。
- `ModelSearch`(静态工具类):`parseMarker`(取 `<<HILITE: 路径>>`)、`highlight`(`open_system`+`hilite_system(path,'find')`)、`collectStrings`(递归取工具入参里的字符串叶子,嗅探 block 路径)、`leafName`。
- `Diagnostics`(handle):`sldiagviewer.DiagnosticReceiver` 常驻(Panel 构造时建,前向捕获后续模型操作诊断);`collect()` 返回 struct 数组(severity/message/id/block,最新在前),`fromMSL` 兜底读 MSLDiagnostic 属性,`parseBlock` 从报错文本正则抽 block 路径,`lasterr` 兜底。Panel `handleDiagnose` 拉它→`diagnostics` 卡片 + 拼进 prompt;`jump_block` 复用 `ModelSearch.highlight` 跳转。
- `Tasks`(静态):`capabilities()` 探测 padv/`Simulink_Check`/`Simulink_Test`(exist+license);`prompt(model,caps)` 拼自适应分阶段任务流(有 padv 用 runprocess,无则 model_check/基本静态检查 + model_test + 汇总)。Panel `handleRunTasks` 用它(`run_tasks` 事件)。
- `Bridge`:`launchSidecar`(ProcessBuilder node)→`tcpclient`→`configureCallback("terminator")`;`onData` **读完所有可用字节按 LF 切分处理每行**;`send` 用 `asciiJson(jsonencode(msg))`;静态 `asciiJson` 把非 ASCII 转 `\uXXXX`。
- `Context.snapshot`:活动 editor 文件(path/name/line/选中)、`currentModel`/`currentSubsystem`、选中 block、`whos`(base)、`lasterr`、**`projectInfo`(工程级)**。`projectInfo` = 工程根(向上找 `.git`/`.prj`)+ git 分支/状态 + **全工程文件索引**(`projectFiles`:MATLAB Project API 优先,否则 `scanDir` 递归剪枝扫 slx/mdl·m·sldd/mat);整体按 root + **15s TTL 缓存**(避免每轮 snapshot 重复 git 双进程与递归扫描)。坑:`scanDir` 进子目录前按**目录名整段**剪枝(slprj/.git/codegen…,非子串);`relPath` 先归一化 `\`↔`/` 再比较(Windows 大小写不敏感),否则输出绝对路径;收集结果用 `(end+1,1)` 强制列向量(否则标量后退化行向量,与 `[rels;sub]` 拼接维度冲突 → 索引整个失效)。
- `Editor`:`activeCursor` / `insertAtCursor`。
- `copilot.m`:addpath;**claude 后端启动时 `shareMATLABSession()` + `mirrorSessionDetails()`**(把会话写到 server 读取路径);创建 Panel。

## 6. UI(ui/index.html,单文件,无 CDN)

- 两段 `<script>`:① 桥 + 渲染 + 事件分发;② 工具栏(后端/模型/思考/模式/附件/斜杠)。
- `renderMd`:自包含 Markdown,**用 `String.fromCharCode(0xE000/0xE001)` 私有区字符做代码占位符**(普通文本如 "C0" 不冲突)。`renderPlain` 给用户输入。
- `onSidecar` switch 处理所有 OutMsg;`addRow` 造头像+气泡;`ensureThink` 思考块;`addToolCard`/`classifyTool` 工具/技能卡;`applyCaps/setConfig/reflectConfig` 工具栏。
- 配色 CSS 变量:`--brand1/2`(紫)、`--user`(蓝)、`--think`(紫)、`--tool`(青)、`--skill`(金)。
- **主题**:`html[data-theme=light]` 覆盖全部变量 + 两处玻璃条/背景 + 浅底文字修正(`.bubble.assistant strong/code`、`.think .th-head`);`applyThemeChoice`(light/dark/auto)存 localStorage;auto 时发 `request_theme`,收 `theme{mode}` 着色;窗口获焦/发送时重同步。深色自洽元素(用户气泡/报错/权限卡自带深底)不随主题改。
- **悬停说明**:`[data-tip]` + 全局 mouseover 2s 定时 → `#tip` 气泡。
- **顶栏单行**:`header` = 品牌图标 + `#tabs-list`(标签页)+ `＋` + `#ctx-chip`(上下文计数图标,悬停弹 `#ctx-pop` 看明细)+ 状态;品牌寄语/`© 林南橘` 移到**空会话 `.welcome` 水印**(`WELCOME_HTML`,首条消息 `clearWelcome()` 移除)。原标题/上下文行已并入此行。
- **多标签页 / Fork**:`tabs` map(convId→{pane,bubbles,thinks,busy,config,auditLog,isFork}),全局 `messages/bubbles/thinks/config/auditLog` 按 `useRender(convId)`/`switchTab` 重指向;`renderTabs` 渲染标签(改名用 `renamingConv` 持久态);Fork=`isFork` 会话,pane 是卡片内 `.fork-msgs`、不进标签栏、首条嵌父卡片内容。工具卡/权限 id 按 convId 命名空间化。
- **消息操作**:`addBubbleActions` 给完成的助手气泡挂「⧉ 复制 / ⑂ Fork」,用户气泡挂「✎ 编辑」(`resetToEdit`);均 `.msg-actions` **悬停才显示、不占高度**。
- **粘贴图片**:`#input` 的 `paste` 监听抓 image item → FileReader 转 base64 → `attach_image{dataUrl}`。
- **会话持久化**:每个 tab 维护 `history`(user 存渲染 html、assistant 额外存原始 raw markdown 供导出);`recordHist` 在 `addRow`(user)/`assistant_stop` 落库,防抖 600ms 存 localStorage(key=`mc-session-<projectKey>`,projectKey 来自 `projectInfo.root`,预览态 default);超额逐轮裁半、每 tab `HISTORY_CAP=400`;`restoreSession` 首次 `renderContext`(或预览态启动)触发,重建标签 + **推进 `tabSeq` 越过已恢复编号**(否则 newTab 撞键覆盖)、`restoring` 标志防重复记录、插「历史记录」分隔。`exportSession` 用 history(assistant 用 raw)导出 Markdown。
- **成本/键盘**:`updateCostBar(cost, convId)` 按 **tab 累计**(`t.costUsd`),只显示当前活动标签、`switchTab` 刷新(避免多标签数字混淆);`Ctrl+K` 开斜杠面板、空输入 `↑` 召回 `lastSentMsg`、面板内 `↑↓/Esc` 导航;`⚡ tb-fast` 开关切常驻(codex 后端禁用)。
- `#messages > * { flex:0 0 auto }`(防 flex column 压缩卡片)。

## 7. 踩坑清单(改前必读,都有惨痛实测)

1. **MATLAB tcpclient 错解码 UTF-8** → 线上**全 ASCII**(`serialize` + `Bridge.asciiJson` 两端)。改协议/新增字段含中文时务必走它们。
2. **MATLAB jsonencode 数组/标量歧义**:单元素 string 数组→标量字符串、空→`[]`。消费端一律 `toArray`(sidecar)/`toArr`(UI)。
3. **tcpclient 回调每次只读一行会丢尾行** → `onData` 必须排空所有可用行(否则 result 滞留 → busy 永不复位)。
4. **`sendEventToHTMLSource` 传嵌套结构体(含空 string 数组)会静默失败** → `pushToUi` 改传 `asciiJson(jsonencode(...))` 字符串,JS 端 `JSON.parse`。
5. **嵌套在 Claude Code 会话里跑子 claude 会 401**(注入的受限 `ANTHROPIC_AUTH_TOKEN`)→ `buildEnv` 检测 `CLAUDECODE` 时删 `ANTHROPIC_*`/`CLAUDE_CODE_*`,回退 `~/.claude/.credentials.json`。正常 MATLAB 启动无此问题、且保留用户 relay。
6. **matlab MCP `failed to attach`**:`matlab-mcp-server` 读 `%APPDATA%\MathWorks\MATLAB MCP Server\v1\sessionDetails.json`,但 `shareMATLABSession` 写到 `…MATLAB MCP Core Server\…`(版本目录名不一致)。`copilot.m:mirrorSessionDetails` 把 Core→Server 镜像。另外:① 必须 `satk_initialize` 激活 MATLAB 侧 MCP 处理器;② **保持单 MATLAB 实例**(多实例时谁最后 shareMATLABSession 谁生效,attach 会指向另一个)。
7. **claude 加载错 MCP**:不加 `--strict-mcp-config` 时 claude 按 cwd 加载项目级 MCP(drawio/Playwright…)而没有 matlab 工具,且 `mcp__approval__approval` not found 直接退出。→ 显式注入 + strict。
8. **气泡叠加**:resume 模式每轮 msg id 从 m1 重置 → 按 id 复用会追加进上一轮气泡。`assistant_start` 强制新建。
9. **Markdown 占位符**:别用普通字符做 sentinel(会和正文冲突),用 PUA。
10. **flex column 卡片塌成 1px**:`overflow:hidden` 的 flex item 最小高变 0 → 加 `flex:0 0 auto`。
11. **Codex 慢**:满配每轮加载 184 skills + 卡顿 MCP(有的鉴权超时 ~30s)→ 64s。`--ignore-user-config` + 注入 matlab MCP → ~25s。
12. **桌面控制**:`open_application "MATLAB R2025b"` 会**新开实例**(不是聚焦)→ 别用它聚焦;`uigetfile`/native 文件框是 full tier 可控。`computer-use` 截图正常,但 `Claude_Preview` 的 `preview_screenshot` 本会话常超时(JS 仍可用 `preview_eval` 验证)。
13. **不挂常驻定时器 / persistent 注册表**:面板曾用 3s `timer` 刷新上下文 + 静态 `persistent` 存单例,二者都**持有 Panel 对象** → `clear classes` 因「对象正在使用」失败 → 对象被作废,其回调(发送/关闭)再触发就抛 "Invalid or deleted object" → **点 X 关不掉、输入就报错**。已改:发消息时刷新上下文;单例改 `findActive()` 按图窗 `UserData` 查找;`onClose`/`delete` 各步独立 try、**最后无条件 `delete(obj.Figure)`**。**重建铁律:先 `delete(findall(0,'Type','figure'))` 关面板,再 `clear classes`**;顺序反了必复现。
14. **Simulink 右键菜单 API 变更(R2025b/R2026a)**:上下文菜单改「扩展点(extension point)」格式,旧 `cm.addCustomMenuFcn('Simulink:PreContextMenu', …)` 注册不报错但**菜单项不渲染**(官方 `slConvertCustomContextMenus` 转换)。`Simulink:ToolsMenu` 仍有效。→「就地解释模块」用**面板按钮**入口,右键代码保留待用扩展点重做。见记忆 `simulink-contextmenu-api-change`。
15. **`acceptEdits` 不覆盖 MCP 工具**:claude `--permission-mode acceptEdits` 只自动放行 claude 自带 Edit/Write;MATLAB MCP 工具仍走 `--permission-prompt-tool` → 控制端口。故 auto/plan 的放行逻辑必须在 `server.js:handleControlLine` 按 `config.mode` 实现(见 §4),否则 auto 模式仍逐条弹卡片。
16. **主题随 MATLAB 解析 System**:`settings().matlab.appearance.MATLABTheme.ActiveValue` 选「System」时返回 `"System"` 而非明暗 → `Panel.detectTheme` 再读 Windows 注册表 `HKCU\…\Themes\Personalize\AppsUseLightTheme`(1=亮 0=暗)。
17. **P1 查找模块取路径要双保险**:只靠 agent 在回答里吐 `<<HILITE:>>` 标记**不可靠**(LLM 常不照做)→ 兜底嗅探 agent `model_read` 工具入参里属于当前模型(`startsWith(model+"/")`)的 block 路径;取不到才提示「未能定位」。
18. **适配器 child/killing 跨异步边界竞态**(claudeCode + codex 都中过):`interrupt`/`stop` 同步 kill + 立即 `this.child=null`,而被 kill 进程的 `close` 回调是**异步**的。若中断后立刻发新消息 spawn 新 child,旧 child 迟到的 close 会 ① 把**新 child 误清成 null**(保护失效) ② 读到被新轮重置的共享 `killing=false` → **把主动 kill 误报成错误** ③ 读/写到新 translator。**修法**:所有回调闭包捕获自己那代 `child`,`if(this.child===child)` 守卫;`killing` 改 **per-child `child._killing`**;常驻模式判忙用独立 `busy`(child 长存);spawn 后挂 `stdin.on('error')` 防 EPIPE 异步抛出 crash 整个 sidecar;`stdin.write` 失败重启重发一次。
19. **Codex「只回一下就没反应」**:`gotTurn` 仅在 `turn.completed` 置真;进程**正常退出却没产出 turn.completed** 时旧 close 逻辑什么都不做 → 无 RESULT → UI 永久卡 thinking。修:close 时 `!gotTurn` 必补 RESULT;`turn.failed` 也补;再加 180s 空闲看门狗防 hang。Codex 慢是其 CLI 每轮冷启特性(非 bug),追速用 Claude Code + ⚡ 常驻。
20. **安装后 `mcp__approval__approval not found`(matlab 工具都在、唯独 approval 缺)**:`permissionServer.js` 曾依赖 `@modelcontextprotocol/sdk`+`zod`,sidecar 主进程却零依赖 → **装后主进程能起、matlab(独立 exe)能起,唯独 approval(node permissionServer.js)因 import 第三方失败而崩**。根因:`.mltbx` 打包的 node_modules 深层路径(sdk 相对路径已 109 字符)装到 `AppData\…\MATLAB Add-Ons\…\sidecar\node_modules\@modelcontextprotocol\sdk\dist\…` 超 **Windows 260 MAX_PATH** → 文件丢失/损坏。源码文件夹直接加路径不报错(路径短、node_modules 完整)正是佐证。**根治**:permissionServer 改**手写极简 MCP(JSON-RPC 2.0 over newline-delimited stdio)**,去掉 sdk/zod → 整个 sidecar **零 npm 依赖**;`build_toolbox` 把 `node_modules` 加进 excludeDirs(不打包);`package.json` `dependencies:{}`;`copilot_doctor` 改查 `src/permissionServer.js` 而非 node_modules。MCP stdio 握手:`initialize`(回 client 的 protocolVersion + `capabilities:{tools:{}}` + serverInfo)→ `notifications/initialized`(通知,忽略)→ `tools/list` → `tools/call`;stdout 只准输出 JSON-RPC 行(不能有调试噪声)。

## 8. 怎么改 / 验证

- **加一个 UI→后端控制能力**:protocol.js(InMsg)→ Panel.onHtmlEvent 转发 → server.handleClientLine 处理。回传走 OutMsg + onSidecar。
- **加一个后端**:继承 `BackendAdapter`,实现 `sendMessage` 把后端输出翻译成 OutMsg;在 `makeAdapter` 和 `capabilities.backends` 注册。
- **改协议/字段**:务必经 `serialize`/`asciiJson`;消费端注意数组/标量。
- **多会话/标签页/Fork**:sidecar `Server.convs = Map<convId,{adapter,config,compacting,...}>`,`ensureConv`/`applyConfig(convId)`/`closeConv`;`onAdapterEvent(c,msg)` 给事件打 convId。UI 用「全局 `messages`/`bubbles`/`thinks`/`config`/`auditLog` 按 convId 重指向」(`useRender(convId)`)让旧渲染零改;**坑**:处理每条入站事件前必须 `useRender(msg.convId)`、用户动作前 `useRender(activeConv)`,否则渲染落错 pane。标签页=`tab.pane`(在 `#panes`);**Fork**=`isFork` 的会话,其 `pane` 是卡片内的 `.fork-msgs`、不进标签栏,首条消息内嵌父卡片内容作种子。工具卡/权限 id 都按 convId 命名空间化防撞。
- **跑测试**:`cd sidecar && npm test`(当前 65 个,11 文件)。新增逻辑配单测。MATLAB 侧用 `matlab -batch` + `checkcode`(纯静态语法)/`meta.class.fromName`(类加载)/直接调静态方法(如工程索引逻辑)无界面自检,临时 `.m` 跑完删掉。**适配器并发改动**用 fake child(EventEmitter,覆盖 `spawnChild`)测 busy 保护 / per-child 守卫 / reset 不回写,不真 spawn CLI。
- **对标官方差距**:见 plan.md 差距表。文档锚定走**在线 RAG**(中国可访问 mathworks.com 文档站;不可用的只是官方 Copilot 产品)——系统提示 **best-effort** WebFetch 抓取核实,**失败不重试、优雅降级**标注「未核实」(MATLAB 启动的 sidecar 进程联网环境可能和 shell 不同,WebFetch 在面板里可能失败,故不强制)。可追溯靠 `server.js:recordAudit`(破坏性 tool_use → 审计 JSONL + `audit` 事件)。
- **不连 MATLAB 联调**:`node src/index.js`(设 env backend)+ `node dev-client.mjs <port> "<q>"`(自动批准权限请求)。
- **UI 视觉**:`.claude/launch.json` 已配静态服务;`preview_start` 后 `preview_eval` 注入 `onSidecar(...)` 样例事件验证(截图工具可能超时,用 eval 读 DOM 替代)。

## 9. 安全红线

- 永不 `--dangerously-skip-permissions` / `codex --dangerously-bypass-*`。
- 破坏性 MATLAB 工具默认经 UI 确认;**面板未连接时默认拒绝**。
- 自动放行只发生在用户**显式选了 `auto` 编辑模式**时(且仍对执行类工具确认),或 `plan` 模式强制只读 —— 这是用户经 mode 开关的主动选择,不是代码私自放权。
- 不在 URL/日志里放凭据;子进程凭据来自其环境,不硬编码。
