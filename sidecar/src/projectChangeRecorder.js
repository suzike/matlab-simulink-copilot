import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { EventEmitter } from 'node:events';

const TRACKED_EXTENSIONS = new Set([
  '.slx', '.mdl', '.sldd', '.slreqx', '.mldatx', '.m', '.mlx',
  '.mat', '.json', '.yaml', '.yml', '.xml', '.csv', '.txt', '.md',
]);
const TEXT_EXTENSIONS = new Set(['.m', '.json', '.yaml', '.yml', '.xml', '.csv', '.txt', '.md']);
const IGNORED_DIRS = new Set([
  '.git', '.svn', '.hg', '.matlab-copilot', 'node_modules', 'slprj',
  'codegen', '_verify', '.playwright-mcp',
]);

export class ProjectChangeRecorder extends EventEmitter {
  constructor({ root, storageRoot, debounceMs = 900, maxFileBytes = 50 * 1024 * 1024 } = {}) {
    super();
    this.root = path.resolve(root || process.cwd());
    this.storageRoot = storageRoot || path.join(os.homedir(), '.matlab-copilot', 'change-records');
    this.debounceMs = debounceMs;
    this.maxFileBytes = maxFileBytes;
    this.active = false;
    this.phase = 'idle';
    this.watcherHealthy = false;
    this.sessionId = null;
    this.startedAt = null;
    this.stoppedAt = null;
    this.recordDir = null;
    this.entries = [];
    this.files = new Map();
    this.sequence = 0;
    this.watcher = null;
    this.poller = null;
    this.pending = new Map();
    this.reportFile = null;
    this.task = sanitizeTask();
    this.operation = Promise.resolve();
  }

  start(projectRoot, task) {
    return this.runExclusive(() => this.startImpl(projectRoot, task));
  }

  async startImpl(projectRoot, task) {
    if (this.active) return this.status();
    this.phase = 'starting';
    this.emit('state', this.status());
    if (projectRoot) this.root = path.resolve(String(projectRoot));
    if (!fs.existsSync(this.root) || !fs.statSync(this.root).isDirectory()) {
      this.phase = 'idle';
      throw new Error(`工程目录不存在: ${this.root}`);
    }
    this.sessionId = makeSessionId();
    this.startedAt = new Date().toISOString();
    this.stoppedAt = null;
    this.entries = [];
    this.files = new Map();
    this.sequence = 0;
    this.reportFile = null;
    this.task = sanitizeTask(task);
    const projectKey = crypto.createHash('sha256').update(this.root.toLowerCase()).digest('hex').slice(0, 16);
    this.recordDir = path.join(this.storageRoot, projectKey, this.sessionId);
    fs.mkdirSync(path.join(this.recordDir, 'shadow'), { recursive: true });
    fs.mkdirSync(path.join(this.recordDir, 'snapshots'), { recursive: true });
    try {
      await this.buildBaseline(this.root);
      this.active = true;
      this.phase = 'active';
      this.writeManifest();
      this.startWatcher();
      this.emit('state', this.status());
      return this.status();
    } catch (error) {
      this.active = false;
      this.phase = 'idle';
      this.watcherHealthy = false;
      throw error;
    }
  }

  stop() {
    return this.runExclusive(() => this.stopImpl());
  }

  async stopImpl() {
    if (!this.active) {
      this.phase = 'idle';
      return this.status();
    }
    this.phase = 'stopping';
    this.emit('state', this.status());
    this.watcher?.close();
    this.watcher = null;
    this.watcherHealthy = false;
    if (this.poller) clearInterval(this.poller);
    this.poller = null;
    await this.reconcile();
    this.active = false;
    this.phase = 'idle';
    this.stoppedAt = new Date().toISOString();
    this.writeManifest();
    this.emit('state', this.status());
    return this.status();
  }

  status() {
    return {
      active: this.active,
      phase: this.phase,
      watcherHealthy: this.watcherHealthy,
      projectRoot: this.root,
      sessionId: this.sessionId,
      startedAt: this.startedAt,
      stoppedAt: this.stoppedAt,
      changeCount: this.entries.filter((entry) => entry.source !== 'deterministic-verification').length,
      evidenceCount: this.entries.filter((entry) => entry.source === 'deterministic-verification').length,
      eventCount: this.entries.length,
      trackedFileCount: this.files.size,
      recordDir: this.recordDir,
      reportFile: this.reportFile,
      task: this.task,
      assessment: buildAssessment(this.entries, this.files, this.task),
    };
  }

  configureTask(value) {
    this.task = sanitizeTask(value);
    this.writeManifest();
    this.emit('state', this.status());
    return this.status();
  }

  startWatcher() {
    try {
      this.watcher = fs.watch(this.root, { recursive: true }, (_eventType, filename) => {
        if (!filename || !this.active) return;
        const rel = this.normalizeRelative(String(filename));
        if (!rel || !this.shouldTrack(rel)) return;
        const old = this.pending.get(rel);
        if (old) clearTimeout(old);
        const timer = setTimeout(() => {
          this.pending.delete(rel);
          this.capture(rel).catch((error) => this.emit('warning', { relativePath: rel, message: error.message }));
        }, this.debounceMs);
        if (timer.unref) timer.unref();
        this.pending.set(rel, timer);
      });
      this.watcherHealthy = true;
      this.watcher.on('error', (error) => this.degradeWatcher(`文件监视失败: ${error.message}`));
    } catch (error) {
      this.degradeWatcher(`当前平台不支持递归文件监视: ${error.message}`);
    }
  }

  degradeWatcher(message) {
    this.watcherHealthy = false;
    if (this.active) this.phase = 'degraded';
    this.emit('warning', { message });
    this.startFallbackPoller();
    this.emit('state', this.status());
  }

  startFallbackPoller() {
    if (this.poller || !this.active) return;
    this.poller = setInterval(() => {
      this.runExclusive(() => this.reconcile())
        .catch((error) => this.emit('warning', { message: `周期对账失败: ${error.message}` }));
    }, 5000);
    if (this.poller.unref) this.poller.unref();
  }

  async buildBaseline(dir) {
    for (const item of fs.readdirSync(dir, { withFileTypes: true })) {
      if (item.isSymbolicLink()) continue;
      if (item.isDirectory() && IGNORED_DIRS.has(item.name.toLowerCase())) continue;
      const full = path.join(dir, item.name);
      if (item.isDirectory()) {
        await this.buildBaseline(full);
        continue;
      }
      const rel = this.normalizeRelative(path.relative(this.root, full));
      if (!this.shouldTrack(rel)) continue;
      const state = this.readState(full);
      if (!state || state.skipped) continue;
      this.files.set(rel, state.meta);
      this.copyBuffer(state.content, this.shadowPath(rel));
    }
  }

  async capture(relativePath) {
    if (!this.active) return null;
    const rel = this.normalizeRelative(relativePath);
    if (!rel || !this.shouldTrack(rel)) return null;
    const full = path.resolve(this.root, rel);
    if (!isInside(this.root, full)) return null;
    const previous = this.files.get(rel) || null;
    let current = null;
    try {
      const stat = fs.lstatSync(full);
      if (stat.isSymbolicLink()) return null;
      if (stat.isFile()) current = this.readState(full);
    } catch (error) {
      if (error?.code !== 'ENOENT') throw error;
    }
    if (current?.skipped) return null;
    if (!previous && !current) return null;
    if (previous && current && previous.hash === current.meta.hash) return null;

    const kind = !previous ? 'added' : (!current ? 'deleted' : 'modified');
    const sequence = ++this.sequence;
    const changeId = `${String(sequence).padStart(5, '0')}-${safeName(path.basename(rel))}`;
    const snapDir = path.join(this.recordDir, 'snapshots', changeId);
    fs.mkdirSync(snapDir, { recursive: true });
    const ext = path.extname(rel);
    const beforeFile = previous ? path.join(snapDir, `before${ext}`) : null;
    const afterFile = current ? path.join(snapDir, `after${ext}`) : null;
    const shadow = this.shadowPath(rel);
    if (previous && fs.existsSync(shadow)) fs.copyFileSync(shadow, beforeFile);
    if (current) {
      this.copyBuffer(current.content, afterFile);
      this.copyBuffer(current.content, shadow);
      this.files.set(rel, current.meta);
    } else {
      this.files.delete(rel);
      if (fs.existsSync(shadow)) fs.rmSync(shadow, { force: true });
    }

    const entry = {
      id: changeId,
      sequence,
      time: new Date().toISOString(),
      source: 'filesystem-save',
      kind,
      relativePath: rel.replaceAll('\\', '/'),
      extension: ext.toLowerCase(),
      beforeHash: previous?.hash || null,
      afterHash: current?.meta.hash || null,
      beforeSize: previous?.size ?? null,
      afterSize: current?.meta.size ?? null,
      beforeSnapshot: beforeFile,
      afterSnapshot: afterFile,
      textDelta: TEXT_EXTENSIONS.has(ext.toLowerCase()) ? summarizeText(beforeFile, afterFile) : null,
      semantic: kind === 'modified' && ['.slx', '.mdl'].includes(ext.toLowerCase())
        ? { status: 'pending' }
        : null,
    };
    this.appendEntry(entry);
    return entry;
  }

  addExternalEntry(value) {
    if (!this.active || !value || typeof value !== 'object') return null;
    const entry = sanitizeExternalEntry(value, ++this.sequence);
    this.appendEntry(entry);
    return entry;
  }

  enrichEntry(id, sequence, value) {
    if (!this.recordDir || !value || typeof value !== 'object') return null;
    const entry = this.entries.find((item) => item.id === String(id) && item.sequence === Number(sequence));
    if (!entry) return null;
    entry.semantic = sanitizeSemantic(value);
    entry.enrichedAt = new Date().toISOString();
    fs.appendFileSync(path.join(this.recordDir, 'changes.jsonl'), JSON.stringify({
      eventType: 'enrichment', id: entry.id, sequence: entry.sequence,
      time: entry.enrichedAt, semantic: entry.semantic,
    }) + '\n');
    this.writeManifest();
    this.emit('change', entry);
    this.emit('state', this.status());
    return entry;
  }

  appendEntry(entry) {
    this.entries.push(entry);
    fs.appendFileSync(path.join(this.recordDir, 'changes.jsonl'), JSON.stringify(entry) + '\n');
    this.writeManifest();
    this.emit('change', entry);
    this.emit('state', this.status());
  }

  async exportReport() {
    if (!this.recordDir) throw new Error('工程变更记录器尚未启动');
    if (this.active) await this.reconcile();
    this.reportFile = path.join(this.recordDir, 'change-report.md');
    const state = this.status();
    fs.writeFileSync(this.reportFile, buildMarkdownReport(state, this.entries), 'utf8');
    fs.writeFileSync(path.join(this.recordDir, 'evidence-index.json'), JSON.stringify({
      schemaVersion: 1, generatedAt: new Date().toISOString(), task: this.task,
      assessment: state.assessment,
      artifacts: { report: this.reportFile, manifest: path.join(this.recordDir, 'manifest.json'),
        eventLog: path.join(this.recordDir, 'changes.jsonl'), snapshots: path.join(this.recordDir, 'snapshots') },
    }, null, 2), 'utf8');
    fs.writeFileSync(path.join(this.recordDir, 'traceability.json'), JSON.stringify({
      schemaVersion: 1, task: this.task,
      requirements: this.task.requirementIds.map((id) => ({ id,
        changedFiles: state.assessment.impactedFiles,
        changedModels: state.assessment.impactedModels,
        verificationIds: state.assessment.verification.map((item) => item.id) })),
    }, null, 2), 'utf8');
    this.writeManifest();
    return { ...this.status(), manifestFile: path.join(this.recordDir, 'manifest.json'),
      evidenceIndexFile: path.join(this.recordDir, 'evidence-index.json'),
      traceabilityFile: path.join(this.recordDir, 'traceability.json') };
  }

  async flushPending() {
    const paths = [...this.pending.keys()];
    for (const timer of this.pending.values()) clearTimeout(timer);
    this.pending.clear();
    for (const rel of paths) {
      try { await this.capture(rel); }
      catch (error) { this.emit('warning', { relativePath: rel, message: error.message }); }
    }
  }

  async reconcile() {
    await this.flushPending();
    const diskPaths = new Set();
    this.collectTrackedPaths(this.root, diskPaths);
    const allPaths = new Set([...this.files.keys(), ...diskPaths]);
    for (const rel of allPaths) {
      try { await this.capture(rel); }
      catch (error) { this.emit('warning', { relativePath: rel, message: error.message }); }
    }
  }

  collectTrackedPaths(dir, output) {
    for (const item of fs.readdirSync(dir, { withFileTypes: true })) {
      if (item.isSymbolicLink()) continue;
      if (item.isDirectory() && IGNORED_DIRS.has(item.name.toLowerCase())) continue;
      const full = path.join(dir, item.name);
      if (item.isDirectory()) this.collectTrackedPaths(full, output);
      else {
        const rel = this.normalizeRelative(path.relative(this.root, full));
        if (rel && this.shouldTrack(rel)) output.add(rel);
      }
    }
  }

  readState(full) {
    const stat = fs.statSync(full);
    if (stat.size > this.maxFileBytes) {
      this.emit('warning', { relativePath: path.relative(this.root, full), message: '文件超过记录大小上限，已跳过' });
      return { skipped: true, reason: 'oversized', size: stat.size };
    }
    const content = fs.readFileSync(full);
    return { content, meta: {
      hash: crypto.createHash('sha256').update(content).digest('hex'),
      size: stat.size,
      modifiedAt: stat.mtime.toISOString(),
    } };
  }

  shouldTrack(rel) {
    const parts = rel.split(/[\\/]+/);
    if (parts.some((part) => IGNORED_DIRS.has(part.toLowerCase()))) return false;
    return TRACKED_EXTENSIONS.has(path.extname(rel).toLowerCase());
  }

  normalizeRelative(value) {
    const rel = path.normalize(String(value || '')).replace(/^([/\\])+/, '');
    if (!rel || rel === '.' || rel.startsWith(`..${path.sep}`) || path.isAbsolute(rel)) return null;
    return rel;
  }

  shadowPath(rel) { return path.join(this.recordDir, 'shadow', rel); }

  copyBuffer(buffer, destination) {
    fs.mkdirSync(path.dirname(destination), { recursive: true });
    fs.writeFileSync(destination, buffer);
  }

  writeManifest() {
    if (!this.recordDir) return;
    const manifest = {
      schemaVersion: 1,
      ...this.status(),
      files: Object.fromEntries(this.files),
      changes: this.entries,
    };
    const target = path.join(this.recordDir, 'manifest.json');
    const temp = `${target}.tmp`;
    fs.writeFileSync(temp, JSON.stringify(manifest, null, 2), 'utf8');
    fs.renameSync(temp, target);
  }

  runExclusive(operation) {
    const result = this.operation.then(operation, operation);
    this.operation = result.catch(() => {});
    return result;
  }
}

function makeSessionId() {
  return `${new Date().toISOString().replace(/[:.]/g, '-')}-${crypto.randomBytes(3).toString('hex')}`;
}

function safeName(value) {
  return String(value).replace(/[^A-Za-z0-9._-]+/g, '_').slice(0, 80) || 'change';
}

function isInside(root, target) {
  const rel = path.relative(path.resolve(root), path.resolve(target));
  return rel === '' || (!rel.startsWith('..') && !path.isAbsolute(rel));
}

function summarizeText(beforeFile, afterFile) {
  const before = beforeFile && fs.existsSync(beforeFile) ? fs.readFileSync(beforeFile, 'utf8').split(/\r?\n/) : [];
  const after = afterFile && fs.existsSync(afterFile) ? fs.readFileSync(afterFile, 'utf8').split(/\r?\n/) : [];
  let prefix = 0;
  while (prefix < before.length && prefix < after.length && before[prefix] === after[prefix]) prefix += 1;
  let suffix = 0;
  while (suffix < before.length - prefix && suffix < after.length - prefix && before[before.length - 1 - suffix] === after[after.length - 1 - suffix]) suffix += 1;
  return { addedLines: Math.max(0, after.length - prefix - suffix), removedLines: Math.max(0, before.length - prefix - suffix), firstChangedLine: prefix + 1 };
}

function sanitizeExternalEntry(value, sequence) {
  const text = (v, max = 500) => String(v ?? '')
    .replace(/\b(sk-[A-Za-z0-9_-]{12,}|sk-proj-[A-Za-z0-9_-]{12,}|Bearer\s+[A-Za-z0-9._~+/-]+=*)\b/gi, '[已脱敏]')
    .replace(/[\r\n]+/g, ' ').slice(0, max);
  const list = (v, max = 120) => (v == null ? [] : (Array.isArray(v) ? v : [v])).slice(0, max).map((item) => {
    if (typeof item === 'string') return text(item);
    if (!item || typeof item !== 'object') return text(item);
    return Object.fromEntries(Object.entries(item).slice(0, 12).map(([k, val]) => [
      text(k, 60),
      /(token|secret|password|authorization|cookie|api.?key)/i.test(k) ? '[已脱敏]' : text(val, 500),
    ]));
  });
  return {
    id: text(value.id || `external-${sequence}`, 120), sequence,
    time: text(value.time || new Date().toISOString(), 80),
    source: text(value.source || 'external', 80), kind: text(value.kind || 'change', 80),
    relativePath: text(value.relativePath, 500), model: text(value.model, 300),
    status: text(value.status, 80), summary: text(value.summary, 1000),
    changes: list(value.changes), added: list(value.added), removed: list(value.removed),
    metrics: sanitizeMetrics(value.metrics, text), requirements: list(value.requirements, 100),
    evidenceFile: text(value.evidenceFile || value.manifestFile, 1000),
  };
}

function buildMarkdownReport(state, entries) {
  const byFile = new Map();
  for (const entry of entries) {
    const key = entry.relativePath || entry.model || '(工程级事件)';
    if (!byFile.has(key)) byFile.set(key, []);
    byFile.get(key).push(entry);
  }
  const counts = entries.reduce((out, item) => {
    out[item.kind] = (out[item.kind] || 0) + 1;
    return out;
  }, {});
  const lines = [
    '# 工程模型变更记录', '', `- 工程: \`${state.projectRoot}\``,
    `- 任务: ${escapeMd(state.task.title)}`,
    `- 需求/工单: ${state.task.requirementIds.map(escapeMd).join('，') || '-'}`,
    `- 责任人: ${escapeMd(state.task.owner) || '-'}`,
    `- 记录会话: \`${state.sessionId}\``, `- 开始时间: ${state.startedAt || '-'}`,
    `- 导出时间: ${new Date().toISOString()}`, `- 变更总数: ${state.changeCount}`,
    `- 验证证据数: ${state.evidenceCount}`,
    `- 分类: ${Object.entries(counts).map(([k, v]) => `${k} ${v}`).join('，') || '无'}`,
    `- 交付判断: \`${state.assessment.readiness}\``,
    `- 风险等级: \`${state.assessment.riskLevel}\``,
    `- 未闭环项: ${state.assessment.openRisks.length}`,
    '', '## 变更时间线', '',
  ];
  if (!entries.length) lines.push('尚未记录到变更。', '');
  for (const entry of entries) {
    const target = entry.relativePath || entry.model || '工程';
    lines.push(`### ${entry.sequence}. ${escapeMd(target)}`, '', `- 时间: ${entry.time}`, `- 来源: \`${entry.source}\``);
    lines.push(`- 类型/状态: \`${entry.kind}\`${entry.status ? ` / \`${entry.status}\`` : ''}`);
    if (entry.summary) lines.push(`- 摘要: ${escapeMd(entry.summary)}`);
    if (entry.textDelta) lines.push(`- 文本变化: +${entry.textDelta.addedLines} / -${entry.textDelta.removedLines}，首个变化行 ${entry.textDelta.firstChangedLine}`);
    if (entry.semantic?.status === 'analyzed') {
      lines.push(`- 模型语义变化: 参数 ${entry.semantic.changes.length}，新增块 ${entry.semantic.added.length}，删除块 ${entry.semantic.removed.length}`);
      for (const change of entry.semantic.changes.slice(0, 20)) {
        lines.push(`  - \`${escapeMd(change.block)}\` / \`${escapeMd(change.param)}\`: \`${escapeMd(change.before)}\` -> \`${escapeMd(change.after)}\``);
      }
      for (const block of entry.semantic.added.slice(0, 20)) lines.push(`  - 新增 \`${escapeMd(block)}\``);
      for (const block of entry.semantic.removed.slice(0, 20)) lines.push(`  - 删除 \`${escapeMd(block)}\``);
    } else if (entry.semantic?.status === 'failed') {
      lines.push(`- 模型语义分析: 失败，${escapeMd(entry.semantic.message || '')}`);
    } else if (entry.semantic?.status === 'pending') {
      lines.push('- 模型语义分析: 等待 MATLAB 分析');
    }
    if (entry.beforeHash || entry.afterHash) lines.push(`- 哈希: \`${shortHash(entry.beforeHash)}\` -> \`${shortHash(entry.afterHash)}\``);
    if (entry.beforeSnapshot) lines.push(`- 修改前快照: \`${entry.beforeSnapshot}\``);
    if (entry.afterSnapshot) lines.push(`- 修改后快照: \`${entry.afterSnapshot}\``);
    if (entry.evidenceFile) lines.push(`- 事务证据: \`${entry.evidenceFile}\``);
    if (entry.changes?.length) lines.push(`- 参数变化: ${entry.changes.length} 项`);
    if (entry.added?.length) lines.push(`- 新增块: ${entry.added.length} 项`);
    if (entry.removed?.length) lines.push(`- 删除块: ${entry.removed.length} 项`);
    lines.push('');
  }
  lines.push('## 按文件汇总', '');
  for (const [file, changes] of byFile) lines.push(`- \`${file}\`: ${changes.length} 次`);
  lines.push('', '## 影响与验证汇总', '');
  lines.push(`- 影响文件: ${state.assessment.impactedFiles.length}`);
  lines.push(`- 影响模型: ${state.assessment.impactedModels.length}`);
  lines.push(`- 变化块: ${state.assessment.changedBlocks.length}`);
  lines.push(`- 验证证据: ${state.assessment.verification.length}`);
  for (const risk of state.assessment.openRisks) lines.push(`- 待处理: ${escapeMd(risk)}`);
  lines.push('', '### 定向测试建议', '');
  if (!state.assessment.testRecommendations.length) lines.push('- 未发现可自动关联的测试文件。');
  for (const item of state.assessment.testRecommendations) {
    lines.push(`- \`${escapeMd(item.model || '工程')}\`: ${item.files.map((f) => `\`${escapeMd(f)}\``).join('，') || '补充对应测试'}`);
  }
  lines.push('', '> 原始机器可读记录见同目录 `manifest.json`、`changes.jsonl`、`evidence-index.json` 与 `traceability.json`。');
  return lines.join('\n') + '\n';
}

function shortHash(value) { return value ? String(value).slice(0, 12) : '-'; }
function escapeMd(value) { return String(value).replace(/([\\`*_[\]<>])/g, '\\$1'); }

function sanitizeTask(value = {}) {
  const text = (v, max) => String(v ?? '').replace(/[\r\n]+/g, ' ').trim().slice(0, max);
  const rawIds = Array.isArray(value?.requirementIds) ? value.requirementIds : String(value?.requirementIds || '').split(/[,;，；\s]+/);
  return { title: text(value?.title || '未命名变更任务', 200),
    requirementIds: [...new Set(rawIds.map((id) => text(id, 100)).filter(Boolean))].slice(0, 100),
    owner: text(value?.owner, 100), description: text(value?.description, 1000) };
}

function sanitizeMetrics(value, text) {
  if (!value || typeof value !== 'object') return {};
  return Object.fromEntries(Object.entries(value).slice(0, 30).map(([key, item]) => {
    if (typeof item === 'number' || typeof item === 'boolean') return [text(key, 80), item];
    if (Array.isArray(item)) return [text(key, 80), item.slice(0, 20).map((v) => text(v, 200))];
    return [text(key, 80), text(item, 500)];
  }));
}

function buildAssessment(entries, files, task) {
  const changes = entries.filter((entry) => entry.source !== 'deterministic-verification' && entry.status !== 'rolled_back');
  const checks = entries.filter((entry) => entry.source === 'deterministic-verification');
  const impactedFiles = [...new Set(changes.map((entry) => entry.relativePath).filter(Boolean))];
  const impactedModels = [...new Set(changes.flatMap((entry) => entry.model ? [entry.model]
    : (['.slx', '.mdl'].includes(entry.extension) ? [entry.relativePath] : [])).filter(Boolean))];
  const changedBlocks = [...new Set(changes.flatMap((entry) => [
    ...(entry.semantic?.changes || []).map((item) => item.block),
    ...(entry.semantic?.added || []), ...(entry.semantic?.removed || []),
    ...(entry.changes || []).map((item) => item.block), ...(entry.added || []), ...(entry.removed || []),
  ]).filter(Boolean))];
  const verification = checks.map((entry) => ({ id: entry.id, kind: entry.kind,
    status: entry.status, summary: entry.summary, metrics: entry.metrics, sequence: entry.sequence }));
  const lastChangeSequence = changes.reduce((max, entry) => Math.max(max, Number(entry.sequence) || 0), 0);
  const freshVerification = verification.filter((entry) => (Number(entry.sequence) || 0) > lastChangeSequence);
  const openRisks = [];
  if (!changes.length) openRisks.push('尚未记录到工程变更');
  if (task.title === '未命名变更任务') openRisks.push('任务名称尚未填写');
  for (const entry of changes) {
    if (entry.semantic?.status === 'pending') openRisks.push(`${entry.relativePath}: 模型语义分析尚未完成`);
    if (entry.semantic?.status === 'failed') openRisks.push(`${entry.relativePath}: 模型语义分析失败`);
    if (entry.semantic?.truncated) openRisks.push(`${entry.relativePath}: 模型语义分析结果已截断`);
    if (['rollback_failed', 'manual_recovery_required'].includes(entry.status)) openRisks.push(`${entry.model || entry.relativePath}: 变更事务需要人工恢复`);
  }
  for (const item of freshVerification) if (item.status === 'failed') openRisks.push(`${item.kind}: 验证失败`);
  const hasPassedTest = freshVerification.some((item) => item.kind === 'testrun_report' && item.status === 'passed');
  const hasPassedStandards = freshVerification.some((item) => item.kind === 'standards_report' && item.status === 'passed');
  if (impactedModels.length && verification.length && !freshVerification.length) openRisks.push('验证证据早于最近一次模型变更，必须重新验证');
  if (impactedModels.length && !hasPassedTest) openRisks.push('模型已变更，但尚无通过的 Test Manager 结果');
  if (impactedModels.length && !hasPassedStandards) openRisks.push('模型已变更，但尚无通过的建模规范检查结果');
  const riskLevel = openRisks.some((risk) => /失败|人工恢复/.test(risk)) ? 'high' : (openRisks.length ? 'medium' : 'low');
  const readiness = changes.length && riskLevel === 'low' ? 'ready' : 'not_ready';
  const tracked = [...files.keys()].map((item) => item.replaceAll('\\', '/'));
  const testFiles = tracked.filter((item) => /(^|\/)(test|tests)(\/|$)|(^|\/)(test_|.*_test\.)|\.mldatx$/i.test(item));
  const testRecommendations = impactedModels.map((model) => {
    const base = path.basename(model, path.extname(model)).toLowerCase();
    const matched = testFiles.filter((file) => file.toLowerCase().includes(base));
    return { model, files: matched.length ? matched : testFiles.slice(0, 10) };
  });
  return { riskLevel, readiness, openRisks: [...new Set(openRisks)], impactedFiles,
    impactedModels, changedBlocks, verification, testRecommendations,
    requirementIds: task.requirementIds };
}

function sanitizeSemantic(value) {
  const text = (v, max = 500) => String(v ?? '')
    .replace(/\b(sk-[A-Za-z0-9_-]{12,}|sk-proj-[A-Za-z0-9_-]{12,}|Bearer\s+[A-Za-z0-9._~+/-]+=*)\b/gi, '[已脱敏]')
    .replace(/[\r\n]+/g, ' ').slice(0, max);
  const list = (v, max = 120) => (v == null ? [] : (Array.isArray(v) ? v : [v])).slice(0, max).map((item) => {
    if (typeof item === 'string') return text(item);
    if (!item || typeof item !== 'object') return text(item);
    const param = text(item.param, 200);
    const sensitive = /(token|secret|password|authorization|cookie|api.?key)/i.test(param);
    return { block: text(item.block, 500), param,
      before: sensitive ? '[已脱敏]' : text(item.before, 500),
      after: sensitive ? '[已脱敏]' : text(item.after, 500) };
  });
  const status = ['analyzed', 'failed'].includes(String(value.status)) ? String(value.status) : 'failed';
  return {
    status,
    analyzedAt: text(value.analyzedAt || new Date().toISOString(), 80),
    message: text(value.message, 1000),
    changes: list(value.changes), added: list(value.added), removed: list(value.removed),
    blockCountBefore: Math.max(0, Number(value.blockCountBefore) || 0),
    blockCountAfter: Math.max(0, Number(value.blockCountAfter) || 0),
    truncated: value.truncated === true,
  };
}
