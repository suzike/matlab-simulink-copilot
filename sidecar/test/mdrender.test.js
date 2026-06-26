import { test } from 'node:test';
import assert from 'node:assert/strict';

// 复制 ui/index.html 里的渲染逻辑做单测(保持与 UI 一致)。
const Z0 = String.fromCharCode(0xE000), Z1 = String.fromCharCode(0xE001);
const RE_BLOCK = new RegExp('^' + Z0 + '(\\d+)' + Z0 + '$');
const RE_CODE = new RegExp(Z1 + '(\\d+)' + Z1, 'g');
function escapeHtml(s) { return String(s).replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c])); }
function mdInline(escaped) {
  let out = escaped;
  const codes = [];
  out = out.replace(/`([^`\n]+)`/g, (m, c) => { codes.push(c); return Z1 + (codes.length - 1) + Z1; });
  out = out.replace(/\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g, (m, t, u) => `<a href="${u}" target="_blank" rel="noopener">${t}</a>`);
  out = out.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>').replace(/__([^_]+)__/g, '<strong>$1</strong>');
  out = out.replace(/~~([^~]+)~~/g, '<del>$1</del>');
  out = out.replace(/(^|[^*])\*([^*\n]+)\*/g, '$1<em>$2</em>');
  out = out.replace(/(^|[^_\w])_([^_\n]+)_/g, '$1<em>$2</em>');
  out = out.replace(/(^|[^"=>\w])(https?:\/\/[^\s<]+)/g, (m, pre, u) => pre + `<a href="${u}" target="_blank" rel="noopener">${u}</a>`);
  out = out.replace(RE_CODE, (m, i) => '<code>' + codes[+i] + '</code>');
  return out;
}
function renderMd(text) {
  const blocks = [];
  const stash = (code) => { blocks.push('<pre class="code">' + escapeHtml(code.replace(/\n$/, '')) + '</pre>'); return '\n' + Z0 + (blocks.length - 1) + Z0 + '\n'; };
  let s = String(text).replace(/```[ \t]*[a-zA-Z0-9_+-]*\n?([\s\S]*?)```/g, (m, code) => stash(code));
  s = s.replace(/```[ \t]*[a-zA-Z0-9_+-]*\n?([\s\S]*)$/, (m, code) => stash(code));
  const lines = s.split('\n');
  let html = '', para = [], listType = null, items = [], quote = [], table = [];
  const fp = () => { if (para.length) { html += '<p>' + para.map((l) => mdInline(escapeHtml(l))).join('<br>') + '</p>'; para = []; } };
  const fl = () => { if (items.length) { html += '<' + listType + '>' + items.map((it) => '<li>' + mdInline(escapeHtml(it)) + '</li>').join('') + '</' + listType + '>'; items = []; listType = null; } };
  const fq = () => { if (quote.length) { html += '<blockquote>' + quote.map((l) => mdInline(escapeHtml(l))).join('<br>') + '</blockquote>'; quote = []; } };
  const ft = () => {
    if (!table.length) return;
    const cells = (r) => r.replace(/^\||\|$/g, '').split('|').map((c) => c.trim());
    let t = '<table>';
    table.forEach((row, i) => { if (i === 1 && /^\s*\|?[ :|-]+\|?\s*$/.test(row)) return; const tag = i === 0 ? 'th' : 'td'; t += '<tr>' + cells(row).map((c) => '<' + tag + '>' + mdInline(escapeHtml(c)) + '</' + tag + '>').join('') + '</tr>'; });
    html += t + '</table>'; table = [];
  };
  const fa = () => { fp(); fl(); fq(); ft(); };
  for (const line of lines) {
    let m;
    if (m = line.match(RE_BLOCK)) { fa(); html += blocks[+m[1]]; continue; }
    if (/^\s*$/.test(line)) { fa(); continue; }
    if (/^\s*\|.*\|\s*$/.test(line)) { fp(); fl(); fq(); table.push(line); continue; }
    ft();
    if (m = line.match(/^(#{1,6})\s+(.*)$/)) { fa(); const n = m[1].length; html += '<h' + n + '>' + mdInline(escapeHtml(m[2])) + '</h' + n + '>'; continue; }
    if (/^\s*(---|\*\*\*|___)\s*$/.test(line)) { fa(); html += '<hr>'; continue; }
    if (m = line.match(/^>\s?(.*)$/)) { fp(); fl(); quote.push(m[1]); continue; }
    if (m = line.match(/^\s*[-*+]\s+(.*)$/)) { fp(); fq(); if (listType !== 'ul') { fl(); listType = 'ul'; } items.push(m[1]); continue; }
    if (m = line.match(/^\s*\d+\.\s+(.*)$/)) { fp(); fq(); if (listType !== 'ol') { fl(); listType = 'ol'; } items.push(m[1]); continue; }
    fl(); fq(); para.push(line);
  }
  fa();
  return html;
}

test('行内代码正确还原、且不破坏 C0/B5 等普通文本', () => {
  const out = renderMd('行内 `code` 测试 C0 B5');
  assert.match(out, /<code>code<\/code>/);
  assert.match(out, /C0 B5/);
  assert.doesNotMatch(out, /[]/); // 占位符必须全部还原
});

test('围栏代码块还原', () => {
  const out = renderMd('前\n\n```matlab\nx = 12*13;\ndisp(x)\n```');
  assert.match(out, /<pre class="code">x = 12\*13;\ndisp\(x\)<\/pre>/);
  assert.doesNotMatch(out, /[]/);
});

test('标题/粗体/斜体/链接/列表/表格', () => {
  const out = renderMd('# 标题\n**粗** *斜* [d](https://x.com/a)\n\n- a\n- b\n\n| h | v |\n| - | - |\n| 1 | 2 |');
  assert.match(out, /<h1>标题<\/h1>/);
  assert.match(out, /<strong>粗<\/strong>/);
  assert.match(out, /<em>斜<\/em>/);
  assert.match(out, /<a href="https:\/\/x\.com\/a"[^>]*>d<\/a>/);
  assert.match(out, /<ul><li>a<\/li><li>b<\/li><\/ul>/);
  assert.match(out, /<table><tr><th>h<\/th><th>v<\/th><\/tr><tr><td>1<\/td><td>2<\/td><\/tr><\/table>/);
});

test('XSS:HTML 被转义', () => {
  const out = renderMd('<script>alert(1)</script>');
  assert.doesNotMatch(out, /<script>/);
  assert.match(out, /&lt;script&gt;/);
});
