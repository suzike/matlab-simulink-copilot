// 枚举可用后端 / 模型 / 模式 / 思考强度 / 斜杠命令,供 UI 填充选择器。
// 模型按用户选择「读配置自动枚举」:解析 ~/.codex/config.toml 与 ~/.claude 配置,再并入常用预设。
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const HOME = os.homedir();

function readSafe(p) { try { return fs.readFileSync(p, 'utf8'); } catch { return ''; } }
function uniq(arr) { return [...new Set(arr.filter(Boolean))]; }

// 极简 TOML 取值:抓所有 `model = "..."`(含 profiles 内的)。
function codexModels() {
  const txt = readSafe(path.join(HOME, '.codex', 'config.toml'));
  const found = [];
  const re = /^\s*model\s*=\s*"([^"]+)"/gm;
  let m; while ((m = re.exec(txt))) found.push(m[1]);
  const presets = ['gpt-5-codex', 'gpt-5', 'o3', 'o4-mini'];
  return uniq([...found, ...presets]);
}

function claudeModels() {
  const found = [];
  for (const f of ['.claude/settings.json', '.claude.json']) {
    const txt = readSafe(path.join(HOME, f));
    if (!txt) continue;
    try { const j = JSON.parse(txt); if (j.model) found.push(j.model); } catch {}
  }
  if (process.env.ANTHROPIC_MODEL) found.push(process.env.ANTHROPIC_MODEL);
  const presets = ['sonnet', 'opus', 'haiku', 'claude-opus-4-8', 'claude-sonnet-4-6', 'claude-haiku-4-5'];
  return uniq([...found, ...presets]);
}

// 加载自定义斜杠命令:~/.claude/commands、项目 .claude/commands(*.md)、~/.codex/prompts(*.md)。
export function loadSlashCommands(cwd) {
  const dirs = [
    { dir: path.join(HOME, '.claude', 'commands'), source: 'claude' },
    { dir: path.join(cwd || '.', '.claude', 'commands'), source: 'claude-project' },
    { dir: path.join(HOME, '.codex', 'prompts'), source: 'codex' },
  ];
  const cmds = [];
  for (const { dir, source } of dirs) {
    let files = [];
    try { files = fs.readdirSync(dir); } catch { continue; }
    for (const f of files) {
      if (!/\.(md|markdown|txt)$/i.test(f)) continue;
      cmds.push({ name: '/' + f.replace(/\.(md|markdown|txt)$/i, ''), source, path: path.join(dir, f) });
    }
  }
  return cmds;
}

// 内置(可落地)命令:大多映射为面板原生动作,UI 端处理。
const BUILTIN = [
  // —— MBD 操作 ——
  { name: '/explain',  desc: '解释选中代码或 Simulink block',       kind: 'action' },
  { name: '/comment',  desc: '给选中代码添加中文注释',               kind: 'action' },
  { name: '/fix',      desc: '诊断最近报错并给出修复步骤',           kind: 'action' },
  { name: '/test',     desc: '为当前文件/模型生成测试用例',          kind: 'action' },
  { name: '/check',    desc: '运行 Simulink 建模标准检查',           kind: 'action' },
  { name: '/overview', desc: '当前打开模型或文件的整体概览',         kind: 'action' },
  { name: '/heal',     desc: '自愈验证环:运行→修→重跑(最多 3 轮)',      kind: 'action' },
  { name: '/capture',  desc: '截图并 AI 分析 Simulink 画布',           kind: 'action' },
  { name: '/req',      desc: '需求追溯:反向推导需求条目,建立双向追溯', kind: 'action' },
  { name: '/codegen',  desc: '代码评审:MISRA-C 风险 + 复杂度 + EC 规模', kind: 'action' },
  { name: '/batch',    desc: '批量编辑:按描述定位所有目标 block 逐个批改', kind: 'action' },
  { name: '/testflow', desc: '测试编排:生成→运行→汇总完整闭环',          kind: 'action' },
  // —— 配置 ——
  { name: '/model',    desc: '切换模型',                             kind: 'config' },
  { name: '/mode',     desc: '切换编辑模式(ask/auto/plan)',          kind: 'config' },
  { name: '/think',    desc: '切换思考强度(low/medium/high)',        kind: 'config' },
  { name: '/claude',   desc: '切到 Claude Code 后端',               kind: 'config' },
  { name: '/codex',    desc: '切到 Codex 后端',                     kind: 'config' },
  // —— UI ——
  { name: '/clear',    desc: '清屏',                                 kind: 'ui' },
  { name: '/context',  desc: '刷新上下文',                           kind: 'ui' },
  { name: '/export',   desc: '导出当前对话为 Markdown 文件',         kind: 'ui' },
  { name: '/compact',  desc: '压缩对话(请模型总结已有上下文)',       kind: 'prompt' },
];

export function getCapabilities(current, cwd) {
  const custom = loadSlashCommands(cwd).map((c) => ({ name: c.name, desc: c.source + ' 自定义命令', kind: 'custom' }));
  return {
    backends: [
      { id: 'claude', label: 'Claude Code' },
      { id: 'codex', label: 'Codex' },
    ],
    models: { claude: claudeModels(), codex: codexModels() },
    modes: [
      { id: 'ask', label: 'Ask before edits', desc: '每次编辑前征求同意' },
      { id: 'auto', label: 'Edit automatically', desc: '自动编辑选中文本或整个文件' },
      { id: 'plan', label: 'Plan mode', desc: '只探索并给出计划,先不编辑' },
    ],
    efforts: ['low', 'medium', 'high'],
    commands: [...BUILTIN, ...custom],
    current,
  };
}

// 解析一条斜杠命令的可执行内容(自定义命令读其文件体)。返回 null 表示交给 UI/内置处理。
export function resolveSlashCommand(name, cwd) {
  const c = loadSlashCommands(cwd).find((x) => x.name === name);
  if (!c) return null;
  const body = readSafe(c.path);
  return body ? { kind: 'custom', body } : null;
}
