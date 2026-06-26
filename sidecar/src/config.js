// sidecar 集中配置。可用环境变量覆盖,便于 MATLAB 端按需启动。
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

export const HOST = '127.0.0.1';
export const CLIENT_PORT = intEnv('MATLAB_COPILOT_PORT', 8765);   // UI/MATLAB 连接
export const CONTROL_PORT = intEnv('MATLAB_COPILOT_CONTROL_PORT', 8766); // 权限确认回连

// 后端选择:'claude'(默认) | 'echo'(联调用,无需 claude/MATLAB)
export const BACKEND = process.env.MATLAB_COPILOT_BACKEND || 'claude';

// agent 工作目录,默认当前目录(MATLAB 端会传入当前文件夹)
export const CWD = process.env.MATLAB_COPILOT_CWD || process.cwd();

export const MODEL = process.env.MATLAB_COPILOT_MODEL || null;
// 常驻后端进程(消除每轮冷启延迟)。opt-in,env 设初值,UI 开关可运行时切换。
export const PERSISTENT = process.env.MATLAB_COPILOT_PERSISTENT === '1';
// extended thinking 预算(token)。默认开启,展示思考过程;设 0 关闭。
export const THINKING_TOKENS = intEnv('MATLAB_COPILOT_THINKING_TOKENS', 8000);
// Codex 后端:推理强度与沙箱策略。
export const CODEX_EFFORT = process.env.MATLAB_COPILOT_CODEX_EFFORT || 'medium'; // low|medium|high
export const CODEX_SANDBOX = process.env.MATLAB_COPILOT_CODEX_SANDBOX || 'workspace-write';

// 视为只读、可由 sidecar 自动放行的工具(按 MCP 工具名后缀匹配)。
// 其余工具(model_edit / run_matlab_file / evaluate_matlab_code / model_test 等)
// 一律弹到 UI 上由用户确认 —— 绝不使用 --dangerously-skip-permissions。
export const READONLY_TOOL_SUFFIXES = [
  'model_overview',
  'model_read',
  'model_query_params',
  'model_resolve_params',
  'model_check',
  'detect_matlab_toolboxes',
  'check_matlab_code',
];

// Claude Code 内置的安全工具,直接预批,免一次往返。
export const PREAPPROVED_TOOLS = ['Read', 'Glob', 'Grep', 'TodoWrite', 'WebFetch', 'WebSearch'];

// 「执行/运行」类工具:运行代码、跑测试/仿真、执行 shell —— 即使在 auto(自动编辑)模式下
// 也仍需用户确认(区别于"改模型/写文件"这类编辑)。读改靠确认链,真正跑代码多一道关。
export const EXECUTE_TOOL_SUFFIXES = ['run_matlab_file', 'evaluate_matlab_code', 'model_test'];

// 给 agent 追加的系统提示,让它清楚自己是 MATLAB 内嵌 Copilot。
export const APPEND_SYSTEM_PROMPT =
  '你是内嵌在 MATLAB/Simulink 界面里的 Copilot 侧边栏。用户消息可能附带 <matlab-context> 段,' +
  '描述当前打开的文件、选中代码、当前模型与选中的 block、工作区变量、最近报错。' +
  '优先用 MATLAB/Simulink MCP 工具(model_overview/model_read/model_edit/run_matlab_file 等)读取与操作实况会话。' +
  '修改模型或运行代码这类操作会触发用户确认,请把意图说清楚。回答用简体中文。' +
  // 文档锚定(对标官方 Copilot「答案锚定 MathWorks 文档」):best-effort 在线 RAG + 优雅降级。
  '涉及 MATLAB/Simulink 函数、工具箱、报错或用法时,优先用 WebFetch 抓取对应 MathWorks 文档页核实' +
  '(可用 https://www.mathworks.com/help/... 或中国镜像 https://ww2.mathworks.cn/help/...,如 .../help/matlab/ref/<函数>.html);' +
  '抓到就锚定真实内容(语法/参数/行为以文档为准)作答并给可点击链接。' +
  '**但 WebFetch 失败时(网络错误/404)绝不反复重试**:最多换一次 URL。' +
  '仍失败则改用**本地 MATLAB 文档兜底**:用 evaluate_matlab_code 执行 help(\'函数名\')(必要时配合 which/exist/lookfor)' +
  '获取本机权威帮助文本,据此锚定作答——这类只读自省调用(help/which/exist/lookfor)会自动放行、无需你确认。' +
  '只有当在线与本地都查不到时,才基于已有可靠知识作答,并在结尾用一行标注「⚠ 未经核实」(可附最可能的官方文档链接,注明未验证)。' +
  '无论如何都不要把不确定的函数行为/参数当作已核实的事实陈述。' +
  // 可信度/可追溯(对标官方 rigor/traceability):自验证 + 来源标注。
  '改完模型或参数后,务必用 model_read 回读确认改动已生效,并在回答里简短报告验证结果(如「✓ 已验证:Gain=2」);若回读不符要指出。' +
  '区分信息来源:基于文档或刚读取的模型/工作区得出的结论,点明其依据;无法核实的内容标注「未核实/推断」,不要把猜测当事实陈述。' +
  // 自愈验证环:run→抓错→修→重跑,对标 agentic 调试闭环。
  '\n\n**自愈验证环**:当用户触发「自愈运行」或要求「修复并验证」时,按以下固定流程:' +
  '\n① 执行验证(evaluate_matlab_code / model_check / model_test,视上下文选择);' +
  '\n② 若全部通过 → 回复「✓ [验证 N/3] 通过」并停止;' +
  '\n③ 若失败 → 分析错误根因 → 最小化修复(model_edit / 修改文件)→ 返回步骤①;' +
  '\n④ 最多迭代 3 次;第 3 次仍失败 → 列出剩余问题并询问用户,不要擅自扩大修改范围。' +
  '\n每次迭代以「[验证 N/3]」为前缀,后接本轮结果与修复动作(≤2 句)。' +
  // 画布视觉理解:分析 Simulink 模型截图。
  '\n\n**模型截图分析**:当收到附加了 Simulink 模型截图的消息时,先用 Read 工具打开图片查看,' +
  '再系统分析:信号流与整体架构、命名/未命名 block、未连接端口、可疑参数值、布局可读性,最后给出可操作的改进建议。';

// 「光标处生成插入」模式的系统提示:只产出可直接插入的代码,不要解释/不要围栏。
export const INSERT_SYSTEM_PROMPT =
  '你正在为 MATLAB 编辑器的光标处生成代码。只返回可直接插入的 MATLAB 代码,' +
  '不要任何解释、不要 markdown 代码围栏、不要前后缀文字。匹配周围代码风格与缩进。';

function intEnv(name, dflt) {
  const v = process.env[name];
  const n = v ? parseInt(v, 10) : NaN;
  return Number.isFinite(n) ? n : dflt;
}

// 探测本机 MATLAB MCP server(matlab-mcp-server.exe)的启动命令与参数。
// 优先 env 覆盖,其次读 ~/.matlab/agentic-toolkits/config.json。找不到返回 null。
export function getMatlabMcpServer() {
  if (process.env.MATLAB_MCP_CMD) {
    return {
      command: process.env.MATLAB_MCP_CMD,
      args: (process.env.MATLAB_MCP_ARGS || '').split('\n').filter(Boolean),
    };
  }
  try {
    const cfgPath = path.join(os.homedir(), '.matlab', 'agentic-toolkits', 'config.json');
    const cfg = JSON.parse(fs.readFileSync(cfgPath, 'utf8'));
    const cmd = cfg.mcpServerPath;
    const simSrc = cfg.toolkits?.simulink?.source;
    if (!cmd || !fs.existsSync(cmd) || !simSrc) return null;
    const ext = path.join(simSrc, 'tools', 'tools.json');
    const args = [`--matlab-session-mode=${cfg.sessionMode || 'existing'}`];
    if (fs.existsSync(ext)) args.push(`--extension-file=${ext}`);
    return { command: cmd, args };
  } catch {
    return null;
  }
}

// 判断某工具是否只读(可自动放行)。
export function isReadonlyTool(toolName) {
  if (!toolName) return false;
  if (PREAPPROVED_TOOLS.includes(toolName)) return true;
  return READONLY_TOOL_SUFFIXES.some((suf) => toolName.endsWith(suf));
}

// 判断某工具是否"执行/运行"类(auto 模式下仍需确认)。
export function isExecuteTool(toolName) {
  if (!toolName) return false;
  if (toolName === 'Bash' || toolName === 'KillBash') return true;
  return EXECUTE_TOOL_SUFFIXES.some((suf) => toolName.endsWith(suf));
}

// 只读自省调用:用于文档兜底(本地 help)。这些函数纯读、无副作用,可自动放行。
// 严格匹配「单条语句、仅 help/which/exist/lookfor、参数为字符串字面量或单个词」,
// 不允许链式/嵌套/其它函数 —— 绝不放过任何能改状态或跑任意代码的东西。
const SAFE_INTROSPECTION =
  /^(help|which|exist|lookfor)\s*(\(\s*(['"][^'"]*['"])(\s*,\s*['"][^'"]*['"])*\s*\)|\s+[-\w.\\/]+)\s*;?$/i;

function extractEvalCode(input) {
  if (!input || typeof input !== 'object') return null;
  // 收集所有可能承载代码的字符串字段。多于一个(校验对象与执行对象可能错位)或没有,
  // 一律视为不安全 → 返回 null → 不自动放行,交由 UI 确认。
  const keys = ['code', 'command', 'matlab_code', 'matlabCode', 'expression', 'script', 'input'];
  const found = keys.map((k) => input[k]).filter((v) => typeof v === 'string');
  return found.length === 1 ? found[0] : null;
}

// evaluate_matlab_code 但内容只是只读文档自省 → 可自动放行(供文档兜底无摩擦)。
export function isSafeIntrospection(toolName, input) {
  if (!toolName || !toolName.endsWith('evaluate_matlab_code')) return false;
  const code = extractEvalCode(input);
  if (!code) return false;
  return SAFE_INTROSPECTION.test(code.trim());
}
