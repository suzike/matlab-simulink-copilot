import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const { chromium } = await import(pathToFileURL(path.join(root, 'sidecar', 'node_modules', 'playwright', 'index.mjs')));
const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 1440, height: 1000 }, deviceScaleFactor: 1 });
await page.addInitScript(() => localStorage.clear());
await page.goto(pathToFileURL(path.join(root, 'ui', 'index.html')).href);

await page.evaluate(() => {
  onSidecar({ type: 'ready' });
  onSidecar({ type: 'context', convId: 'main', context: {
    currentModel: 'ThermalManagementController',
    currentSubsystem: 'ThermalManagementController/VehicleControl',
    selectedBlocks: ['ThermalManagementController/VehicleControl/CompressorGain'],
    workspaceVars: ['Cal_CompressorGain', 'Bus_ThermalStatus'],
    projectInfo: { root: 'E:/Projects/ThermalManagement', branch: 'feature/REQ-241',
      projectFiles: ['models/ThermalManagementController.slx', 'tests/ThermalManagementController_tests.mldatx'] },
  } });
  onSidecar({ type: 'user_echo', convId: 'main', text: '按照 REQ-241 调整压缩机增益，并完成变更验证。' });
  onSidecar({ type: 'thinking_start', convId: 'main', id: 'doc-think' });
  onSidecar({ type: 'thinking_delta', convId: 'main', id: 'doc-think', text: '先读取当前模型参数和需求影响范围，再建立模型检查点。' });
  onSidecar({ type: 'thinking_stop', convId: 'main', id: 'doc-think' });
  onSidecar({ type: 'tool_use', convId: 'main', id: 'doc-read', name: 'mcp__matlab__model_read',
    input: { model: 'ThermalManagementController', block: 'VehicleControl/CompressorGain' } });
  onSidecar({ type: 'tool_result', convId: 'main', id: 'doc-read', ok: true, summary: '已读取增益参数与上下游连接' });
  onSidecar({ type: 'assistant_start', convId: 'main', id: 'doc-answer' });
  onSidecar({ type: 'assistant_delta', convId: 'main', id: 'doc-answer', text: '## 变更结果\n\n- 已建立修改前检查点\n- `CompressorGain` 已按 REQ-241 更新\n- 模型 Update 与规范检查通过\n- 定向 Test Manager 用例 6/6 通过\n\n证据已进入当前工程变更集。' });
  onSidecar({ type: 'assistant_stop', convId: 'main', id: 'doc-answer' });
  onSidecar({ type: 'change_transaction', convId: 'main', runId: 'run-req-241',
    model: 'ThermalManagementController', status: 'verified', rollbackAvailable: true,
    rollbackAttempted: false, rolledBack: false, compileOk: true, standardsOk: true,
    newStandardErrors: [], manifestFile: 'C:/Users/demo/.matlab-copilot/runs/run-req-241/manifest.json' });
  onSidecar({ type: 'result', convId: 'main', ok: true, costUsd: 0.018 });
});
await page.screenshot({ path: path.join(root, 'docs', 'images', 'v0.13.0-ui-overview.jpg'), type: 'jpeg', quality: 90, fullPage: true });

await page.evaluate(() => {
  onSidecar({ type: 'change_recorder_state', state: {
    active: true, phase: 'active', sessionId: 'REQ-241-session', changeCount: 2, evidenceCount: 2,
    trackedFileCount: 46, recordDir: 'C:/Users/demo/.matlab-copilot/change-records/thermal/REQ-241-session',
    task: { title: 'REQ-241 压缩机控制增益调整', requirementIds: ['REQ-241'], owner: 'Controls Team',
      description: '调整高温工况压缩机增益并完成模型级验证。',
      plannedModels: ['ThermalManagementController'],
      plannedFiles: ['models/ThermalManagementController.slx'],
      acceptanceCriteria: ['模型 Update 通过', '建模规范检查通过', 'Test Manager 定向用例通过'] },
    workflow: { stage: 'validating' },
    assessment: { riskLevel: 'medium', readiness: 'not_ready',
      openRisks: ['等待最终覆盖率证据'], modelVerification: [{ model: 'ThermalManagementController', readiness: 'ready' }] },
  } });
  onSidecar({ type: 'project_change', entry: { id: 'change-1', sequence: 1,
    time: '2026-07-20T10:20:30.000Z', source: 'ai-model-edit', kind: 'model_edit',
    model: 'ThermalManagementController', status: 'verified', summary: '调整 CompressorGain',
    changes: [{ block: 'ThermalManagementController/VehicleControl/CompressorGain', param: 'Gain', before: '1.0', after: '1.15' }] } });
  onSidecar({ type: 'project_change', entry: { id: 'verification-1', sequence: 2,
    time: '2026-07-20T10:22:10.000Z', source: 'deterministic-verification', kind: 'testrun_report',
    model: 'ThermalManagementController', status: 'passed', summary: 'Test Manager：通过 6，失败 0' } });
  document.querySelector('#tb-recorder').click();
});
await page.waitForTimeout(300);
await page.screenshot({ path: path.join(root, 'docs', 'images', 'v0.13.0-change-recorder.jpg'), type: 'jpeg', quality: 90, fullPage: true });
await browser.close();
