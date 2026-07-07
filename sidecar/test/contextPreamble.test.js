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

test('userPaths(addpath 文件夹)渲染进 preamble;单元素标量也兼容', () => {
  const out = renderContextPreamble({ userPaths: ['C:/proj/lib', 'C:/proj/utils'] });
  assert.match(out, /已加载到 MATLAB 路径的文件夹/);
  assert.match(out, /C:\/proj\/lib\nC:\/proj\/utils/);
  // MATLAB jsonencode 单元素 string 数组 → 标量字符串
  const one = renderContextPreamble({ userPaths: 'C:/only/one' });
  assert.match(one, /C:\/only\/one/);
  // 空/缺失不产出该节
  assert.equal(renderContextPreamble({ userPaths: [] }), '');
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
