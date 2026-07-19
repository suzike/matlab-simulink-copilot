// UI/MATLAB ⇄ sidecar 的线协议:每条消息是一行 JSON(newline-delimited JSON)。
// 这一层与具体后端无关,UI 与 MATLAB 只认这套事件。

// ── 入站(UI/MATLAB → sidecar)────────────────────────────────────────────
// 多会话:大多数入站消息可带 convId(标签页/分支 id),缺省为 'main'。
export const InMsg = Object.freeze({
  USER_MESSAGE: 'user_message',       // { type, id, text, context, intent?, convId?, config? }
  INTERRUPT: 'interrupt',             // { type, convId? }
  PERMISSION_RESPONSE: 'permission_response', // { type, id, approved }
  PING: 'ping',                       // { type }
  SET_CONFIG: 'set_config',           // { type, config:{backend?,model?,effort?,mode?}, convId? } 运行时切换
  GET_CAPABILITIES: 'get_capabilities', // { type } 请求可用后端/模型/模式/命令
  SLASH_COMMAND: 'slash_command',     // { type, name, args, context, convId?, config? } 执行斜杠命令
  CLOSE_CONV: 'close_conv',           // { type, convId } 关闭一个会话(标签页),停其后端
  CHANGE_RECORDER_CONTROL: 'change_recorder_control', // { type, action:start|stop|status|configure|export, task? }
  CHANGE_RECORDER_ENTRY: 'change_recorder_entry',     // { type, entry } MATLAB 事务写入工程时间线
  CHANGE_RECORDER_ENRICH: 'change_recorder_enrich',   // { type, id, sequence, semantic } MATLAB 快照语义结果
});

// ── 出站(sidecar → UI/MATLAB)────────────────────────────────────────────
export const OutMsg = Object.freeze({
  READY: 'ready',                     // { type } 后端已就绪
  STATUS: 'status',                   // { type, text } 例如 "thinking"
  THINKING_START: 'thinking_start',   // { type, id } extended thinking 开始
  THINKING_DELTA: 'thinking_delta',   // { type, id, text } 思考流式 token
  THINKING_STOP: 'thinking_stop',     // { type, id } 思考结束
  ASSISTANT_START: 'assistant_start', // { type, id } 一条助手消息开始
  ASSISTANT_DELTA: 'assistant_delta', // { type, id, text } 流式 token
  ASSISTANT_STOP: 'assistant_stop',   // { type, id } 一条助手消息结束
  TOOL_USE: 'tool_use',               // { type, id, name, input } 工具调用卡片
  TOOL_RESULT: 'tool_result',         // { type, id, ok, summary }
  PERMISSION_REQUEST: 'permission_request', // { type, id, tool, input, destructive }
  RESULT: 'result',                   // { type, id, ok, text, costUsd } 一轮结束
  ERROR: 'error',                     // { type, message }
  PONG: 'pong',                       // { type }
  CAPABILITIES: 'capabilities',       // { type, backends, models, modes, efforts, commands, current }
  CONFIG_CHANGED: 'config_changed',   // { type, config } 切换已生效
  AUDIT: 'audit',                     // { type, entry:{id,time,tool,action,status,backend,mode} } 操作审计轨迹
  CHANGE_RECORDER_STATE: 'change_recorder_state', // { type, state } 工程记录器状态
  PROJECT_CHANGE: 'project_change',               // { type, entry } 工程文件/AI 事务变更点
  CHANGE_REPORT: 'change_report',                 // { type, report } 导出报告路径与统计
});

// 把一行文本解析成消息对象;非法行返回 null(调用方应跳过)。
export function parseLine(line) {
  const trimmed = line.trim();
  if (!trimmed) return null;
  try {
    return JSON.parse(trimmed);
  } catch {
    return null;
  }
}

// 把消息对象序列化为一行(末尾不含换行,由写入方补 \n)。
// 关键:转成纯 ASCII(非 ASCII 一律 \uXXXX 转义),避免 MATLAB tcpclient 的
// readline 按非 UTF-8 解码多字节导致中文乱码。JSON 的 \u 转义两端都能正确还原。
export function serialize(obj) {
  const json = JSON.stringify(obj);
  let out = '';
  for (let i = 0; i < json.length; i++) {
    const code = json.charCodeAt(i);
    out += code > 0x7f ? '\\u' + code.toString(16).padStart(4, '0') : json[i];
  }
  return out;
}

// 一个简易的行缓冲:喂入任意 chunk,吐出完整行。
export function createLineBuffer(onLine) {
  let buf = '';
  return (chunk) => {
    buf += chunk;
    let idx;
    while ((idx = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, idx);
      buf = buf.slice(idx + 1);
      onLine(line);
    }
  };
}
