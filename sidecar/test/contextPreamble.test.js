import { test } from 'node:test';
import assert from 'node:assert/strict';
import { renderContextPreamble } from '../src/adapters/types.js';

test('workspaceVars/selectedBlocks 为单个字符串时不崩溃(MATLAB 单元素歧义)', () => {
  // 模拟 MATLAB 工作区只剩 1 个变量 → jsonencode 成标量字符串
  const out = renderContextPreamble({ workspaceVars: 'p (1x1 Panel)', selectedBlocks: 'demo/Gain' });
  assert.match(out, /p \(1x1 Panel\)/);
  assert.match(out, /demo\/Gain/);
});

test('数组形式正常渲染', () => {
  const out = renderContextPreamble({ workspaceVars: ['a (1x1 double)', 'b (3x3 double)'], selectedBlocks: ['m/G1', 'm/G2'] });
  assert.match(out, /a \(1x1 double\), b \(3x3 double\)/);
  assert.match(out, /m\/G1\nm\/G2/);
});

test('字段缺失/空字符串安全', () => {
  assert.equal(renderContextPreamble({}), '');
  assert.equal(renderContextPreamble({ workspaceVars: '', selectedBlocks: '' }), '');
  assert.equal(renderContextPreamble(null), '');
});

test('完整上下文含 activeFile/model/lastError', () => {
  const out = renderContextPreamble({
    activeFile: { path: 'C:/x/foo.m', selection: 'x = 1;' },
    currentModel: 'demo',
    lastError: 'boom',
  });
  assert.match(out, /foo\.m/);
  assert.match(out, /x = 1;/);
  assert.match(out, /demo/);
  assert.match(out, /boom/);
  assert.match(out, /<matlab-context>/);
});
