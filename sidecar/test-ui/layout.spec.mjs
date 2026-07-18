import { expect, test } from '@playwright/test';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const pageUrl = pathToFileURL(path.join(root, 'ui', 'index.html')).href;

async function seedRepresentativeState(page) {
  await page.evaluate(() => {
    onSidecar({ type: 'ready' });
    onSidecar({ type: 'context', context: { currentModel: 'ThermalManagementController', selectedBlocks: ['ThermalManagementController/Vehicle Control/Compressor Command'], projectInfo: { projectFiles: ['matlab/+matlabcopilot/Panel.m', 'sidecar/src/server.js'] } } });
    onSidecar({ type: 'user_echo', convId: 'main', text: '检查当前模型的接口、权限和测试状态' });
    onSidecar({ type: 'thinking_start', convId: 'main', id: 'think-layout' });
    onSidecar({ type: 'thinking_delta', convId: 'main', id: 'think-layout', text: '读取模型结构并核对执行边界。' });
    onSidecar({ type: 'thinking_stop', convId: 'main', id: 'think-layout' });
    onSidecar({ type: 'tool_use', convId: 'main', id: 'tool-layout', name: 'mcp__matlab__model_read', input: { model: 'ThermalManagementController', query: 'all blocks and parameters' } });
    onSidecar({ type: 'tool_result', convId: 'main', id: 'tool-layout', ok: true, summary: '读取完成' });
    onSidecar({ type: 'assistant_start', convId: 'main', id: 'answer-layout' });
    onSidecar({ type: 'assistant_delta', convId: 'main', id: 'answer-layout', text: '## 检查结果\n\n- 模型接口已读取\n- 权限路径保持 Ask / Auto / Plan 隔离\n\n```matlab\nresult = model_check("ThermalManagementController");\n```' });
    onSidecar({ type: 'assistant_stop', convId: 'main', id: 'answer-layout' });
    onSidecar({ type: 'result', convId: 'main', ok: true, costUsd: 0.01 });
  });
}

async function layoutProblems(page) {
  return page.evaluate(() => {
    const visible = (el) => {
      const style = getComputedStyle(el);
      const rect = el.getBoundingClientRect();
      return style.display !== 'none' && style.visibility !== 'hidden' && rect.width > 0 && rect.height > 0;
    };
    const clippedButtons = [...document.querySelectorAll('.quick button, .inputrow button, header button')]
      .filter(visible)
      .filter((el) => el.scrollWidth > el.clientWidth + 1 || el.scrollHeight > el.clientHeight + 1)
      .map((el) => ({ id: el.id, text: el.textContent.trim(), client: [el.clientWidth, el.clientHeight], scroll: [el.scrollWidth, el.scrollHeight] }));
    return {
      viewport: [document.documentElement.clientWidth, document.documentElement.clientHeight],
      document: [document.documentElement.scrollWidth, document.documentElement.scrollHeight],
      clippedButtons,
    };
  });
}

test.beforeEach(async ({ page }) => {
  await page.addInitScript(() => localStorage.clear());
  await page.goto(pageUrl);
  await seedRepresentativeState(page);
});

test('代表性消息状态不产生横向溢出或按钮文字越界', async ({ page }) => {
  const problems = await layoutProblems(page);
  expect(problems.document[0], JSON.stringify(problems, null, 2)).toBeLessThanOrEqual(problems.viewport[0] + 1);
  expect(problems.clippedButtons, JSON.stringify(problems, null, 2)).toEqual([]);
});

test('亮色和暗色主题均可正常渲染', async ({ page }) => {
  for (const theme of ['light', 'dark']) {
    await page.evaluate((mode) => applyThemeChoice(mode), theme);
    await expect(page.locator('html')).toHaveAttribute('data-theme', theme);
    const problems = await layoutProblems(page);
    expect(problems.document[0], `${theme}: ${JSON.stringify(problems, null, 2)}`).toBeLessThanOrEqual(problems.viewport[0] + 1);
  }
});

test('上下文和附件按 convId 隔离', async ({ page }) => {
  await page.evaluate(() => {
    makeTabState('t-isolation', '隔离会话');
    onSidecar({ type: 'context', convId: 'main', context: { currentModel: 'MainModel' } });
    onSidecar({ type: 'attachments', convId: 'main', files: ['main-only.png'] });
    switchTab('t-isolation');
    onSidecar({ type: 'context', convId: 't-isolation', context: { currentModel: 'SecondModel' } });
    onSidecar({ type: 'attachments', convId: 't-isolation', files: ['second-only.csv'] });
  });

  await expect(page.locator('#attachments')).toContainText('second-only.csv');
  await expect(page.locator('#attachments')).not.toContainText('main-only.png');
  await expect(page.locator('#ctx-pop')).toContainText('SecondModel');

  await page.evaluate(() => switchTab('main'));
  await expect(page.locator('#attachments')).toContainText('main-only.png');
  await expect(page.locator('#attachments')).not.toContainText('second-only.csv');
  await expect(page.locator('#ctx-pop')).toContainText('MainModel');

  await page.evaluate(() => {
    onSidecar({ type: 'context', convId: 't-isolation', context: { currentModel: 'SecondModelUpdated' } });
    onSidecar({ type: 'attachments', convId: 't-isolation', files: ['second-updated.json'] });
  });
  await expect(page.locator('#attachments')).toContainText('main-only.png');
  await expect(page.locator('#ctx-pop')).toContainText('MainModel');

  await page.evaluate(() => switchTab('t-isolation'));
  await expect(page.locator('#attachments')).toContainText('second-updated.json');
  await expect(page.locator('#ctx-pop')).toContainText('SecondModelUpdated');
});

test('Fork 附件只渲染到对应分支', async ({ page }) => {
  await page.evaluate(() => {
    const zone = document.createElement('div');
    zone.className = 'fork-zone';
    zone.dataset.conv = 'fork-isolation';
    zone.innerHTML = '<div class="fork-msgs"></div><div class="fork-attachments"></div>';
    document.body.appendChild(zone);
    makeForkState('fork-isolation', zone.querySelector('.fork-msgs'));
    onSidecar({ type: 'attachments', convId: 'main', files: ['main-only.png'] });
    onSidecar({ type: 'attachments', convId: 'fork-isolation', files: ['fork-only.mat'] });
  });

  await expect(page.locator('#attachments')).toContainText('main-only.png');
  await expect(page.locator('#attachments')).not.toContainText('fork-only.mat');
  await expect(page.locator('.fork-zone[data-conv="fork-isolation"] .fork-attachments')).toContainText('fork-only.mat');
  await expect(page.locator('.fork-zone[data-conv="fork-isolation"] .fork-attachments')).not.toContainText('main-only.png');
});
