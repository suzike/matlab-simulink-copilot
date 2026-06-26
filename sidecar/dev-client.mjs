// 手动联调客户端:模拟 MATLAB 面板,连 sidecar,发一条 user_message,
// 打印所有出站事件直到 result。用于在没有 MATLAB GUI 的情况下验证 claude 真后端。
import net from 'node:net';

const PORT = parseInt(process.argv[2] || '8770', 10);
const TEXT = process.argv[3] || '用一句话简单介绍 MATLAB 的 plot 函数。';

const sock = net.createConnection({ host: '127.0.0.1', port: PORT }, () => {
  console.log('[client] connected, sending question:', TEXT);
  const msg = { type: 'user_message', id: 'q1', text: TEXT, context: { currentModel: '', workspaceVars: [] } };
  sock.write(JSON.stringify(msg) + '\n');
});

let buf = '';
sock.setEncoding('utf8');
sock.on('data', (chunk) => {
  buf += chunk;
  let i;
  while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i); buf = buf.slice(i + 1);
    if (!line.trim()) continue;
    let m; try { m = JSON.parse(line); } catch { continue; }
    if (m.type === 'assistant_delta') process.stdout.write(m.text);
    else if (m.type === 'assistant_start') process.stdout.write('\n[assistant] ');
    else if (m.type === 'thinking_start') process.stdout.write('\n[thinking] ');
    else if (m.type === 'thinking_delta') process.stdout.write(m.text);
    else if (m.type === 'thinking_stop') process.stdout.write('\n[/thinking]');
    else if (m.type === 'tool_use') console.log(`\n[tool_use] ${m.name} ${JSON.stringify(m.input)}`);
    else if (m.type === 'tool_result') console.log(`\n[tool_result] ok=${m.ok} ${String(m.summary).slice(0,120)}`);
    else if (m.type === 'permission_request') {
      console.log(`\n[permission_request] ${m.tool} -> 自动批准`);
      sock.write(JSON.stringify({ type: 'permission_response', id: m.id, approved: true }) + '\n');
    }
    else if (m.type === 'status') console.log(`\n[status] ${m.text}`);
    else if (m.type === 'error') console.log(`\n[ERROR] ${m.message}`);
    else if (m.type === 'result') {
      console.log(`\n[result] ok=${m.ok} costUsd=${m.costUsd}`);
      sock.end(); process.exit(0);
    }
  }
});
sock.on('error', (e) => { console.log('[client] socket error', e.message); process.exit(1); });
