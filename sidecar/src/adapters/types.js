import { EventEmitter } from 'node:events';

/**
 * 后端适配器接口。面板与 sidecar 只认 OutMsg 事件,具体后端(Claude Code / Codex /
 * Agent SDK)由各自适配器实现。这样 v1 接 Claude Code,未来可平滑替换。
 *
 * 事件(通过 EventEmitter 发出):
 *   'event'  (uiMsg)  — 一条 OutMsg 出站消息,server 直接转发给 UI/MATLAB
 *   'error'  (Error)  — 适配器级错误
 *
 * 方法:
 *   start()                      — 初始化(可空实现)
 *   sendMessage({ text, context }) — 发一轮用户消息(含 MATLAB 上下文快照)
 *   interrupt()                  — 中断当前进行中的一轮
 *   stop()                       — 关闭并清理
 */
export class BackendAdapter extends EventEmitter {
  // eslint-disable-next-line no-unused-vars
  async start() {}
  // eslint-disable-next-line no-unused-vars
  async sendMessage(_payload) {
    throw new Error('sendMessage 未实现');
  }
  interrupt() {}
  async stop() {}
  // 压缩:丢弃后端续接会话(释放长历史),下一轮从新会话开始。
  resetSession() {}

  // 子类用它向上抛 UI 事件。
  emitEvent(uiMsg) {
    this.emit('event', uiMsg);
  }
}

// MATLAB jsonencode 会把「单元素」string 数组编码成标量字符串、空数组编码成 []，
// 导致字段可能是 string / array / undefined。这里统一强制成数组,避免崩溃。
function toArray(x) {
  if (Array.isArray(x)) return x;
  if (x === undefined || x === null || x === '') return [];
  return [x];
}

// 把 MATLAB 上下文快照渲染成一段可读的提示前缀。agent 仍可用 MCP 工具拉更多。
export function renderContextPreamble(context) {
  if (!context || typeof context !== 'object') return '';
  const parts = [];
  if (context.compactSummary) parts.push(`# 之前对话摘要(已压缩)\n${context.compactSummary}`);
  if (context.activeFile?.path) {
    parts.push(`# 当前编辑器文件\n路径: ${context.activeFile.path}`);
    if (context.activeFile.selection) {
      parts.push(`选中代码:\n\`\`\`matlab\n${context.activeFile.selection}\n\`\`\``);
    }
  }
  if (context.currentModel) {
    let m = `# 当前 Simulink 模型\n${context.currentModel}`;
    if (context.currentSubsystem && context.currentSubsystem !== context.currentModel) {
      m += `\n当前子系统: ${context.currentSubsystem}`;
    }
    parts.push(m);
  }
  const blocks = toArray(context.selectedBlocks);
  if (blocks.length) {
    parts.push(`# 选中的 block\n${blocks.join('\n')}`);
  }
  const wvars = toArray(context.workspaceVars);
  if (wvars.length) {
    const text = wvars
      .map((v) => (typeof v === 'string' ? v : `${v.name} (${v.size} ${v.class})`))
      .join(', ');
    parts.push(`# 工作区变量\n${text}`);
  }
  if (context.lastError) {
    parts.push(`# 最近报错\n\`\`\`\n${context.lastError}\n\`\`\``);
  }
  const upaths = toArray(context.userPaths);
  if (upaths.length) {
    parts.push(`# 已加载到 MATLAB 路径的文件夹(addpath)\n${upaths.join('\n')}\n(这些目录里的函数/类当前可直接调用;要读其源码就到这些路径下找)`);
  }
  const pi = context.projectInfo;
  if (pi && (pi.root || pi.gitBranch)) {
    let s = `# 工程上下文`;
    if (pi.root) s += `\n项目根: ${pi.root}`;
    if (pi.gitBranch) s += `\n分支: ${pi.gitBranch}`;
    if (pi.gitStatus) s += `\n改动文件:\n${pi.gitStatus}`;
    if (pi.files) s += `\n工程文件索引:\n${pi.files}`;
    parts.push(s);
  }
  const kb = toArray(context.kbHits);
  if (kb.length) {
    const items = kb.map((h) => `## 相似问题:${h.q}\n${h.body || ''}`).join('\n\n');
    parts.push(`# 团队经验库命中(仅供参考,以当前实际情况为准)\n${items}`);
  }
  const atts = toArray(context.attachments);
  for (const a of atts) {
    if (!a || !a.name) continue;
    if (a.isImage && a.path) {
      // 图片:给路径,让 agent 用 Read 工具查看(Read 可视觉读图,已预批)。
      parts.push(`# 附加图片: ${a.name}\n文件路径: ${a.path}\n(请先用 Read 工具查看这张图片,再据此回答)`);
    } else {
      parts.push(`# 附加文件: ${a.name}\n\`\`\`\n${a.content || ''}\n\`\`\``);
    }
  }
  if (!parts.length) return '';
  return `<matlab-context>\n${parts.join('\n\n')}\n</matlab-context>\n\n`;
}
