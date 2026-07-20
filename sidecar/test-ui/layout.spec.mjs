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
    onSidecar({ type: 'change_transaction', convId: 'main', runId: 'run-layout', model: 'ThermalManagementController', status: 'verified', rollbackAvailable: true, rollbackAttempted: false, rolledBack: false, rollbackMessage: '', compileOk: true, compileMessage: '', standardsOk: true, newStandardErrors: [], manifestFile: 'C:/Users/test/.matlab-copilot/runs/run-layout/manifest.json' });
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
    const clippedButtons = [...document.querySelectorAll('header button, footer button')]
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

test('可信变更事务卡展示验证与回退状态', async ({ page }) => {
  const card = page.locator('.mdiff').filter({ hasText: '可信变更事务' });
  await expect(card).toBeVisible();
  await expect(card).toContainText('验证通过');
  await expect(card).toContainText('模型编译/更新');
  await expect(card).toContainText('manifest.json');

  await page.evaluate(() => onSidecar({
    type: 'change_transaction', convId: 'main', runId: 'run-rollback',
    model: 'ThermalManagementController', status: 'rolled_back',
    rollbackAvailable: true, rollbackAttempted: true, rolledBack: true,
    rollbackMessage: '验证失败，已恢复修改前检查点。',
    compileOk: false, compileMessage: '参数无法解析', standardsOk: true,
    newStandardErrors: [], manifestFile: 'C:/runs/run-rollback/manifest.json'
  }));
  const rollback = page.locator('.mdiff').filter({ hasText: '失败，已回退' });
  await expect(rollback).toContainText('已恢复检查点');
});

test('工程模型变更记录器展示状态、时间线与报告路径', async ({ page }) => {
  await page.evaluate(() => {
    onSidecar({ type: 'change_recorder_state', state: {
      active: true, sessionId: 'session-ui', changeCount: 1, trackedFileCount: 12,
      recordDir: 'C:/Users/test/.matlab-copilot/change-records/project/session-ui',
      task: { title: '热管理增益调整', requirementIds: ['REQ-101'], owner: 'Lin', description: '修正高温工况',
        plannedModels: ['ThermalManagementController'], plannedFiles: ['models/controller.slx'],
        acceptanceCriteria: ['Test Manager 通过', '规范检查通过'] },
      workflow: { stage: 'draft' },
      assessment: { riskLevel: 'medium', readiness: 'not_ready', openRisks: ['尚无测试结果'] },
    } });
    onSidecar({ type: 'project_change', entry: {
      id: '00001-controller.m', sequence: 1, time: '2026-07-19T10:20:30.000Z',
      source: 'filesystem-save', kind: 'modified', relativePath: 'src/controller.m',
      textDelta: { addedLines: 2, removedLines: 1, firstChangedLine: 8 },
    } });
  });
  await expect(page.locator('#tb-recorder')).toHaveClass(/recording/);
  await page.locator('#tb-recorder').click();
  await expect(page.locator('#recorder-pop')).toBeVisible();
  const popupBounds = await page.evaluate(() => {
    const popup = document.querySelector('#recorder-pop').getBoundingClientRect();
    const footer = document.querySelector('footer').getBoundingClientRect();
    return { popupBottom: popup.bottom, footerTop: footer.top };
  });
  expect(popupBounds.popupBottom).toBeLessThanOrEqual(popupBounds.footerTop - 7);
  await expect(page.locator('#recorder-pop')).toContainText('热管理增益调整');
  await expect(page.locator('#recorder-pop')).toContainText('not_ready');
  await expect(page.locator('#rec-task-req')).toHaveValue('REQ-101');
  await expect(page.locator('#rec-task-models')).toHaveValue('ThermalManagementController');
  await expect(page.locator('#rec-task-files')).toHaveValue('models/controller.slx');
  await expect(page.locator('#rec-task-accept')).toHaveValue('Test Manager 通过\n规范检查通过');
  await expect(page.locator('#rec-approve')).toBeEnabled();
  await expect(page.locator('#rec-execute')).toBeDisabled();
  await expect(page.locator('#recorder-pop')).toContainText('src/controller.m');
  await expect(page.locator('#recorder-pop')).toContainText('+2/-1');
  await expect(page.locator('#rec-start')).toBeDisabled();
  await expect(page.locator('#rec-stop')).toBeEnabled();

  await page.locator('#rec-task-title').fill('热管理增益调整 - 修订');
  await page.locator('#rec-task-req').fill('REQ-101, BUG-42');
  await page.locator('#rec-task-title').focus();
  await page.locator('#rec-task-title').evaluate((el) => el.setSelectionRange(4, 4));
  await expect(page.locator('#recorder-pop')).toBeVisible();

  await page.evaluate(() => onSidecar({ type: 'project_change', entry: {
    id: '00002-controller.slx', sequence: 2, time: '2026-07-19T10:21:30.000Z',
    source: 'filesystem-save', kind: 'modified', relativePath: 'models/controller.slx',
    semantic: { status: 'analyzed', changes: [{ block: 'Control/Gain', param: 'Gain', before: '1', after: '2' }], added: ['Control/Limit'], removed: [] },
  } }));
  await expect(page.locator('#recorder-pop')).toContainText('models/controller.slx');
  await expect(page.locator('#recorder-pop')).toContainText('参数 1 / 块 +1 -0');
  await expect(page.locator('#rec-task-title')).toBeFocused();
  await expect(page.locator('#rec-task-title')).toHaveValue('热管理增益调整 - 修订');
  expect(await page.locator('#rec-task-title').evaluate((el) => el.selectionStart)).toBe(4);
  await expect(page.locator('#rec-task-title')).toHaveValue('热管理增益调整 - 修订');
  await expect(page.locator('#rec-task-req')).toHaveValue('REQ-101, BUG-42');

  await page.evaluate(() => onSidecar({ type: 'change_recorder_state', state: {
    active: true, workflow: { stage: 'executing' }, changeCount: 2,
  } }));
  await expect(page.locator('#rec-validate')).toBeEnabled();

  await page.evaluate(() => onSidecar({ type: 'change_report', report: {
    active: true, sessionId: 'session-ui', changeCount: 1,
    reportFile: 'C:/records/session-ui/change-report.md',
    evidenceIndexFile: 'C:/records/session-ui/evidence-index.json',
  } }));
  await expect(page.locator('#status')).toHaveText('任务证据包已导出');
});

test('Markdown 链接不能注入事件属性', async ({ page }) => {
  const result = await page.evaluate(() => {
    const host = document.createElement('div');
    host.innerHTML = renderMd('[hover](https://example.com/"onmouseover="window.__xss=7)');
    document.body.appendChild(host);
    const anchor = host.querySelector('a');
    anchor?.dispatchEvent(new MouseEvent('mouseover', { bubbles: true }));
    return { href: anchor?.getAttribute('href'), onmouseover: anchor?.getAttribute('onmouseover'), xss: window.__xss || 0 };
  });
  expect(result.onmouseover).toBeNull();
  expect(result.xss).toBe(0);
  expect(result.href).toContain('https://example.com/');
});

test('编辑旧消息同步裁剪持久化历史', async ({ page }) => {
  await page.evaluate(() => {
    useRender('main');
    messages.innerHTML = '';
    tabs.main.history = [];
    addUserMessage('需要编辑的原始消息');
  });
  await expect(page.locator('.row.user')).toHaveCount(1);
  await page.locator('.row.user').hover();
  await expect(page.locator('.row.user .ma-btn')).toBeVisible();
  await page.locator('.row.user .ma-btn').click();
  expect(await page.evaluate(() => tabs.main.history.length)).toBe(0);
  await expect(page.locator('.row.user')).toHaveCount(0);
  await expect(page.locator('#input')).toHaveValue('需要编辑的原始消息');
});

test('Esc 关闭记录器弹窗而不中断会话', async ({ page }) => {
  await page.locator('#tb-recorder').click();
  await expect(page.locator('#recorder-pop')).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(page.locator('#recorder-pop')).toBeHidden();
});

test('模型列表为空时不显示孤立下拉箭头', async ({ page }) => {
  await expect(page.locator('#tb-model')).toBeHidden();
  await expect(page.locator('#tb-model-div')).toBeHidden();

  await page.evaluate(() => applyCaps({
    models: { claude: ['claude-sonnet'], codex: ['gpt-5'] },
    current: { backend: 'claude', model: 'claude-sonnet', effort: 'medium', mode: 'ask' },
  }));
  await expect(page.locator('#tb-model')).toBeVisible();
  await expect(page.locator('#tb-model-div')).toBeVisible();
  await expect(page.locator('#tb-model')).toHaveValue('claude-sonnet');
});

test('快捷功能三态切换不改变输入框位置', async ({ page }) => {
  const inputBottom = async () => page.locator('.inputrow').evaluate((el) => Math.round(el.getBoundingClientRect().bottom));
  const baseline = await inputBottom();

  await page.locator('#quick-mode-collapsed').click();
  await expect(page.locator('#quick-shell')).toHaveAttribute('data-mode', 'collapsed');
  await expect(page.locator('.quick')).toBeHidden();
  expect(await inputBottom()).toBe(baseline);

  await page.locator('#quick-mode-single').click();
  await expect(page.locator('#quick-shell')).toHaveAttribute('data-mode', 'single');
  await expect(page.locator('.quick')).toBeVisible();
  expect(await page.locator('.quick').evaluate((el) => getComputedStyle(el).flexWrap)).toBe('nowrap');
  expect(await inputBottom()).toBe(baseline);

  await page.locator('#quick-mode-expanded').click();
  await expect(page.locator('#quick-shell')).toHaveAttribute('data-mode', 'expanded');
  expect(await page.locator('.quick').evaluate((el) => getComputedStyle(el).flexWrap)).toBe('wrap');
  expect(await inputBottom()).toBe(baseline);
  await expect(page.locator('#quick-mode-expanded')).toHaveAttribute('aria-pressed', 'true');
});

test('单行模式隐藏滚动条并用鼠标滚轮横向浏览', async ({ page }) => {
  await page.locator('#quick-mode-single').click();
  const quick = page.locator('.quick');
  const metrics = await quick.evaluate((el) => ({
    clientWidth: el.clientWidth,
    scrollWidth: el.scrollWidth,
    scrollbarWidth: getComputedStyle(el).scrollbarWidth,
  }));
  expect(metrics.scrollWidth).toBeGreaterThan(metrics.clientWidth);
  expect(metrics.scrollbarWidth).toBe('none');
  await quick.hover();
  await page.mouse.wheel(0, 320);
  await expect.poll(() => quick.evaluate((el) => el.scrollLeft)).toBeGreaterThan(0);
  await expect(page.locator('#quick-prev')).toBeEnabled();
});

test('快捷按钮悬停时上边缘不被裁切', async ({ page }) => {
  await page.locator('#quick-mode-single').click();
  const button = page.locator('#btn-test');
  await button.hover();
  const bounds = await page.evaluate(() => {
    const quick = document.querySelector('.quick').getBoundingClientRect();
    const target = document.querySelector('#btn-test').getBoundingClientRect();
    return { quickTop: quick.top, quickBottom: quick.bottom, buttonTop: target.top, buttonBottom: target.bottom };
  });
  expect(bounds.buttonTop).toBeGreaterThanOrEqual(bounds.quickTop);
  expect(bounds.buttonBottom).toBeLessThanOrEqual(bounds.quickBottom);
});

test('受限宽度下快捷功能保持单行且三态控件不重叠', async ({ page }) => {
  await page.setViewportSize({ width: 760, height: 600 });
  await page.locator('#quick-mode-single').click();

  const state = await page.evaluate(() => {
    const modes = document.querySelector('.quick-modes').getBoundingClientRect();
    const quick = document.querySelector('.quick').getBoundingClientRect();
    return {
      quickHeight: quick.height,
      overlap: modes.right > quick.left && modes.left < quick.right && modes.bottom > quick.top && modes.top < quick.bottom,
      inputBottom: Math.round(document.querySelector('.inputrow').getBoundingClientRect().bottom),
      viewportHeight: document.documentElement.clientHeight,
    };
  });
  expect(state.quickHeight).toBeLessThanOrEqual(30);
  expect(state.overlap).toBe(false);
  expect(state.inputBottom).toBeLessThanOrEqual(state.viewportHeight - 8);
  const problems = await layoutProblems(page);
  expect(problems.document[0], JSON.stringify(problems, null, 2)).toBeLessThanOrEqual(problems.viewport[0] + 1);
  expect(problems.clippedButtons, JSON.stringify(problems, null, 2)).toEqual([]);
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

test('工程切换时会话历史按工程隔离并可往返恢复', async ({ page }) => {
  const state = await page.evaluate(() => {
    renderContext({ projectInfo: { root: 'C:\\Work\\ProjectA' }, currentModel: 'ModelA' });
    useRender('main');
    addUserMessage('Project A only');
    saveSession();

    renderContext({ projectInfo: { root: 'C:\\Work\\ProjectB' }, currentModel: 'ModelB' });
    const bBefore = tabs.main.history.map((item) => item.html).join('\n');
    useRender('main');
    addUserMessage('Project B only');
    saveSession();

    renderContext({ projectInfo: { root: 'c:/work/projecta/' }, currentModel: 'ModelA' });
    return {
      key: projectKey,
      bBefore,
      aHistory: tabs.main.history.map((item) => item.html).join('\n'),
      storedA: localStorage.getItem('mc-session-c:/work/projecta'),
      storedB: localStorage.getItem('mc-session-c:/work/projectb'),
    };
  });
  expect(state.key).toBe('c:/work/projecta');
  expect(state.bBefore).not.toContain('Project A only');
  expect(state.aHistory).toContain('Project A only');
  expect(state.aHistory).not.toContain('Project B only');
  expect(state.storedA).toContain('Project A only');
  expect(state.storedB).toContain('Project B only');
});

test('关闭会话墓碑保持固定容量', async ({ page }) => {
  const state = await page.evaluate(() => {
    for (let i = 0; i < CLOSED_CONV_CAP + 100; i++) rememberClosedConv('closed-' + i);
    return {
      size: closedConvs.size,
      oldest: closedConvs.has('closed-0'),
      newest: closedConvs.has('closed-' + (CLOSED_CONV_CAP + 99)),
    };
  });
  expect(state.size).toBe(256);
  expect(state.oldest).toBe(false);
  expect(state.newest).toBe(true);
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
