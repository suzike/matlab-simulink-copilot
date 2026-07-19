import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { ProjectChangeRecorder } from '../src/projectChangeRecorder.js';

function fixture() {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'mc-recorder-'));
  const root = path.join(base, 'project');
  const records = path.join(base, 'records');
  fs.mkdirSync(root);
  fs.writeFileSync(path.join(root, 'controller.m'), 'gain = 1;\n', 'utf8');
  const recorder = new ProjectChangeRecorder({ root, storageRoot: records, debounceMs: 20 });
  return { base, root, recorder, cleanup: () => fs.rmSync(base, { recursive: true, force: true }) };
}

test('记录修改前后快照、哈希与文本行摘要', async () => {
  const f = fixture();
  try {
    await f.recorder.start();
    fs.writeFileSync(path.join(f.root, 'controller.m'), 'gain = 2;\nlimit = 10;\n', 'utf8');
    const entry = await f.recorder.capture('controller.m');
    assert.equal(entry.kind, 'modified');
    assert.notEqual(entry.beforeHash, entry.afterHash);
    assert.equal(fs.readFileSync(entry.beforeSnapshot, 'utf8'), 'gain = 1;\n');
    assert.equal(fs.readFileSync(entry.afterSnapshot, 'utf8'), 'gain = 2;\nlimit = 10;\n');
    assert.equal(entry.textDelta.firstChangedLine, 1);
    assert.equal(f.recorder.status().changeCount, 1);
  } finally {
    await f.recorder.stop();
    f.cleanup();
  }
});

test('记录工程文件新增和删除，忽略生成目录与不支持的扩展名', async () => {
  const f = fixture();
  try {
    fs.mkdirSync(path.join(f.root, 'slprj'));
    fs.writeFileSync(path.join(f.root, 'slprj', 'generated.m'), 'x=1;', 'utf8');
    fs.writeFileSync(path.join(f.root, 'raw.bin'), 'raw', 'utf8');
    await f.recorder.start();
    assert.equal(f.recorder.status().trackedFileCount, 1);

    fs.writeFileSync(path.join(f.root, 'plant.slx'), Buffer.from('fake-model-v1'));
    const added = await f.recorder.capture('plant.slx');
    assert.equal(added.kind, 'added');
    fs.rmSync(path.join(f.root, 'plant.slx'));
    const deleted = await f.recorder.capture('plant.slx');
    assert.equal(deleted.kind, 'deleted');
    assert.equal(fs.readFileSync(deleted.beforeSnapshot, 'utf8'), 'fake-model-v1');
  } finally {
    await f.recorder.stop();
    f.cleanup();
  }
});

test('相同内容不重复记录，路径越界被拒绝', async () => {
  const f = fixture();
  try {
    await f.recorder.start();
    assert.equal(await f.recorder.capture('controller.m'), null);
    assert.equal(await f.recorder.capture('../outside.m'), null);
    assert.equal(f.recorder.status().changeCount, 0);
  } finally {
    await f.recorder.stop();
    f.cleanup();
  }
});

test('模型文件记录可原位回写 MATLAB 语义对比，JSONL 保持追加式', async () => {
  const f = fixture();
  try {
    fs.writeFileSync(path.join(f.root, 'plant.slx'), Buffer.from('model-before'));
    await f.recorder.start();
    fs.writeFileSync(path.join(f.root, 'plant.slx'), Buffer.from('model-after'));
    const change = await f.recorder.capture('plant.slx');
    assert.equal(change.semantic.status, 'pending');
    const enriched = f.recorder.enrichEntry(change.id, change.sequence, {
      status: 'analyzed', blockCountBefore: 8, blockCountAfter: 9,
      changes: [
        { block: 'Controller/Gain', param: 'Gain', before: '1', after: '2' },
        { block: 'Controller/Auth', param: 'ApiKey', before: 'old-secret', after: 'new-secret' },
      ],
      added: 'Controller/Limit', removed: [],
    });
    assert.equal(f.recorder.entries.length, 1);
    assert.equal(enriched.semantic.changes.length, 2);
    assert.equal(enriched.semantic.changes[1].after, '[已脱敏]');
    assert.equal(enriched.semantic.added[0], 'Controller/Limit');
    const lines = fs.readFileSync(path.join(f.recorder.recordDir, 'changes.jsonl'), 'utf8').trim().split('\n');
    assert.equal(lines.length, 2);
    assert.equal(JSON.parse(lines[1]).eventType, 'enrichment');
    const report = await f.recorder.exportReport();
    assert.match(fs.readFileSync(report.reportFile, 'utf8'), /模型语义变化: 参数 2，新增块 1，删除块 0/);
  } finally {
    await f.recorder.stop();
    f.cleanup();
  }
});

test('AI 模型事务进入统一时间线并导出 JSON 与 Markdown 报告', async () => {
  const f = fixture();
  try {
    await f.recorder.start();
    const entry = f.recorder.addExternalEntry({
      id: 'run-1', source: 'ai-model-edit', kind: 'model_edit', model: 'demo',
      status: 'verified', summary: '修改控制器增益',
      changes: [{ block: 'demo/Gain', param: 'Gain', before: '1', after: '2', apiKey: 'secret-value' }],
      manifestFile: 'C:/evidence/manifest.json',
    });
    assert.equal(entry.source, 'ai-model-edit');
    assert.equal(entry.changes[0].apiKey, '[已脱敏]');
    fs.writeFileSync(path.join(f.root, 'late-save.slx'), Buffer.from('late-model'));
    const report = await f.recorder.exportReport();
    assert.equal(report.changeCount, 2);
    assert.equal(f.recorder.entries.some((item) => item.relativePath === 'late-save.slx'), true);
    assert.equal(fs.existsSync(report.reportFile), true);
    assert.equal(fs.existsSync(report.manifestFile), true);
    const markdown = fs.readFileSync(report.reportFile, 'utf8');
    assert.match(markdown, /工程模型变更记录/);
    assert.match(markdown, /修改控制器增益/);
    assert.match(markdown, /参数变化: 1 项/);
  } finally {
    await f.recorder.stop();
    f.cleanup();
  }
});

test('任务级证据包聚合需求、影响、验证矩阵和定向测试建议', async () => {
  const f = fixture();
  try {
    fs.mkdirSync(path.join(f.root, 'tests'));
    fs.writeFileSync(path.join(f.root, 'plant.slx'), Buffer.from('plant-v1'));
    fs.writeFileSync(path.join(f.root, 'tests', 'plant_regression.mldatx'), Buffer.from('test-data'));
    await f.recorder.start(f.root, { title: '调整热管理增益', requirementIds: 'REQ-101, BUG-42', owner: 'Lin' });
    fs.writeFileSync(path.join(f.root, 'plant.slx'), Buffer.from('plant-v2'));
    const change = await f.recorder.capture('plant.slx');
    f.recorder.enrichEntry(change.id, change.sequence, { status: 'analyzed',
      changes: [{ block: 'Controller/Gain', param: 'Gain', before: '1', after: '2' }], added: [], removed: [] });
    f.recorder.addExternalEntry({ id: 'test-1', source: 'deterministic-verification',
      kind: 'testrun_report', status: 'passed', summary: '通过 4，失败 0', metrics: { passed: 4, failed: 0 } });
    f.recorder.addExternalEntry({ id: 'standards-1', source: 'deterministic-verification',
      kind: 'standards_report', status: 'passed', summary: '错误 0，警告 1', metrics: { errors: 0, warnings: 1 } });

    const state = f.recorder.status();
    assert.equal(state.assessment.riskLevel, 'low');
    assert.equal(state.assessment.readiness, 'ready');
    assert.deepEqual(state.task.requirementIds, ['REQ-101', 'BUG-42']);
    assert.equal(state.assessment.testRecommendations[0].files[0], 'tests/plant_regression.mldatx');
    const report = await f.recorder.exportReport();
    assert.equal(fs.existsSync(report.evidenceIndexFile), true);
    assert.equal(fs.existsSync(report.traceabilityFile), true);
    const trace = JSON.parse(fs.readFileSync(report.traceabilityFile, 'utf8'));
    assert.equal(trace.requirements.length, 2);
    assert.deepEqual(trace.requirements[0].verificationIds, ['test-1', 'standards-1']);
    assert.match(fs.readFileSync(report.reportFile, 'utf8'), /交付判断: `ready`/);
  } finally {
    await f.recorder.stop();
    f.cleanup();
  }
});

test('停止时先对账并保留防抖窗口内的最后一次保存', async () => {
  const f = fixture();
  try {
    f.recorder.debounceMs = 1000;
    await f.recorder.start();
    fs.writeFileSync(path.join(f.root, 'controller.m'), 'gain = 9;\n', 'utf8');
    await new Promise((resolve) => setTimeout(resolve, 30));
    const state = await f.recorder.stop();
    assert.equal(state.active, false);
    assert.equal(state.changeCount, 1);
    assert.equal(f.recorder.entries[0].relativePath, 'controller.m');
    assert.equal(fs.existsSync(f.recorder.entries[0].afterSnapshot), true);
  } finally {
    await f.recorder.stop();
    f.cleanup();
  }
});

test('启动与停止并发时按调用顺序串行，停止返回后不会重新激活', async () => {
  const f = fixture();
  try {
    const original = f.recorder.buildBaseline.bind(f.recorder);
    f.recorder.buildBaseline = async (...args) => {
      await new Promise((resolve) => setTimeout(resolve, 40));
      return original(...args);
    };
    const starting = f.recorder.start();
    const stopping = f.recorder.stop();
    await Promise.all([starting, stopping]);
    assert.equal(f.recorder.status().active, false);
    assert.equal(f.recorder.status().phase, 'idle');
  } finally {
    await f.recorder.stop();
    f.cleanup();
  }
});

test('已跟踪文件超过大小上限时跳过，不误记为删除', async () => {
  const f = fixture();
  try {
    fs.writeFileSync(path.join(f.root, 'small.txt'), '1234', 'utf8');
    f.recorder.maxFileBytes = 8;
    await f.recorder.start();
    fs.writeFileSync(path.join(f.root, 'small.txt'), '123456789', 'utf8');
    const entry = await f.recorder.capture('small.txt');
    assert.equal(entry, null);
    assert.equal(f.recorder.files.has('small.txt'), true);
    assert.equal(fs.existsSync(path.join(f.root, 'small.txt')), true);
    assert.equal(f.recorder.entries.some((item) => item.kind === 'deleted'), false);
  } finally {
    await f.recorder.stop();
    f.cleanup();
  }
});

test('模型变更后的交付判断不接受旧验证证据', async () => {
  const f = fixture();
  try {
    fs.writeFileSync(path.join(f.root, 'plant.slx'), Buffer.from('v1'));
    await f.recorder.start(f.root, { title: '模型修改' });
    f.recorder.addExternalEntry({ id: 'old-test', source: 'deterministic-verification', kind: 'testrun_report', status: 'passed' });
    f.recorder.addExternalEntry({ id: 'old-check', source: 'deterministic-verification', kind: 'standards_report', status: 'passed' });
    fs.writeFileSync(path.join(f.root, 'plant.slx'), Buffer.from('v2'));
    const change = await f.recorder.capture('plant.slx');
    f.recorder.enrichEntry(change.id, change.sequence, { status: 'analyzed', changes: [], added: [], removed: [] });
    const assessment = f.recorder.status().assessment;
    assert.equal(assessment.readiness, 'not_ready');
    assert.match(assessment.openRisks.join('\n'), /早于最近一次模型变更/);
  } finally {
    await f.recorder.stop();
    f.cleanup();
  }
});

test('模型语义结果截断时不能判定 ready', async () => {
  const f = fixture();
  try {
    fs.writeFileSync(path.join(f.root, 'plant.slx'), Buffer.from('v1'));
    await f.recorder.start(f.root, { title: '模型修改' });
    fs.writeFileSync(path.join(f.root, 'plant.slx'), Buffer.from('v2'));
    const change = await f.recorder.capture('plant.slx');
    f.recorder.enrichEntry(change.id, change.sequence, { status: 'analyzed', truncated: true, changes: [], added: [], removed: [] });
    f.recorder.addExternalEntry({ id: 'test', source: 'deterministic-verification', kind: 'testrun_report', status: 'passed' });
    f.recorder.addExternalEntry({ id: 'check', source: 'deterministic-verification', kind: 'standards_report', status: 'passed' });
    const assessment = f.recorder.status().assessment;
    assert.equal(assessment.readiness, 'not_ready');
    assert.match(assessment.openRisks.join('\n'), /已截断/);
  } finally {
    await f.recorder.stop();
    f.cleanup();
  }
});

test('文件监视失败时状态明确降级并启用周期对账', async () => {
  const f = fixture();
  try {
    await f.recorder.start();
    f.recorder.degradeWatcher('test watcher failure');
    assert.equal(f.recorder.status().phase, 'degraded');
    assert.equal(f.recorder.status().watcherHealthy, false);
    assert.ok(f.recorder.poller);
  } finally {
    await f.recorder.stop();
    f.cleanup();
  }
});
