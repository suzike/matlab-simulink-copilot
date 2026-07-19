#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import vm from 'node:vm';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
const valueAfter = (name) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : null;
};
const artifactArg = valueAfter('--artifact');
const reportArg = valueAfter('--report');
const artifact = artifactArg ? path.resolve(process.cwd(), artifactArg) : null;
const reportFile = reportArg ? path.resolve(process.cwd(), reportArg) : null;
const gates = [];

function gate(id, name, fn) {
  try {
    const evidence = fn();
    gates.push({ gate_id: id, gate_name: name, status: 'PASS', blocking: true, evidence_files: evidence || [], failure_reason: '', required_action: '' });
  } catch (error) {
    gates.push({ gate_id: id, gate_name: name, status: 'FAIL', blocking: true, evidence_files: [], failure_reason: error.message, required_action: '修复后重新运行 release-check.mjs' });
  }
}

function read(rel) {
  return fs.readFileSync(path.join(root, rel), 'utf8');
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function trackedFiles() {
  return execFileSync('git', ['ls-files', '-z'], { cwd: root, encoding: 'utf8' }).split('\0').filter(Boolean).map((p) => p.replaceAll('\\', '/'));
}

gate('REL-001', '版本号一致性', () => {
  const pkg = JSON.parse(read('sidecar/package.json'));
  const lock = JSON.parse(read('sidecar/package-lock.json'));
  const build = read('matlab/build_toolbox.m');
  const readme = read('README.md');
  const changelog = read('CHANGELOG.md');
  const version = pkg.version;
  const buildVersion = build.match(/ToolboxVersion\s*=\s*"([^"]+)"/)?.[1];
  assert(version === lock.version && version === lock.packages?.['']?.version, 'package.json 与 package-lock.json 版本不一致');
  assert(version === buildVersion, 'package.json 与 build_toolbox.m 版本不一致');
  assert(readme.includes(`version-${version}-`) && readme.includes(`/tag/v${version}`), 'README 版本徽章或 Release 链接未更新');
  assert(changelog.includes(`## [${version}]`) && changelog.includes(`[${version}]:`), 'CHANGELOG 缺少当前版本章节或链接');
  return ['sidecar/package.json', 'sidecar/package-lock.json', 'matlab/build_toolbox.m', 'README.md', 'CHANGELOG.md'];
});

gate('REL-002', '运行时零 npm 依赖', () => {
  const pkg = JSON.parse(read('sidecar/package.json'));
  assert(Object.keys(pkg.dependencies || {}).length === 0, 'sidecar.dependencies 必须保持为空');
  return ['sidecar/package.json'];
});

gate('REL-003', '关键源码与图标已跟踪', () => {
  const tracked = new Set(trackedFiles());
  const required = [
    'ui/index.html',
    'matlab/copilot.m',
    'matlab/copilot_doctor.m',
    'matlab/resources/icons/copilot_16.png',
    'matlab/resources/icons/copilot_24.png',
    'sidecar/src/index.js',
    'sidecar/src/permissionServer.js',
    'sidecar/src/matlabPermissionProxy.js',
    'sidecar/src/projectChangeRecorder.js',
    'matlab/+matlabcopilot/ChangeTransaction.m',
    'matlab/+matlabcopilot/ModelFileDiff.m',
  ];
  const missing = required.filter((p) => !tracked.has(p));
  assert(missing.length === 0, `关键文件未纳入 Git: ${missing.join(', ')}`);
  return required;
});

gate('REL-004', 'Git 清单不含构建污染', () => {
  const forbidden = trackedFiles().filter((p) => /(^|\/)(node_modules|_verify|_nm_bak|\.playwright-mcp|slprj)(\/|$)/.test(p) || /\.(log|tmp|slxc)$/i.test(p));
  assert(forbidden.length === 0, `Git 中发现禁止发布的文件: ${forbidden.join(', ')}`);
  return ['.gitignore', 'matlab/build_toolbox.m'];
});

gate('REL-005', 'UI 内联脚本语法', () => {
  const html = read('ui/index.html');
  const scripts = [...html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/gi)].map((m) => m[1]);
  assert(scripts.length >= 2, `预期至少 2 段内联脚本，实际 ${scripts.length}`);
  scripts.forEach((source, i) => new vm.Script(source, { filename: `ui/index.html#script-${i + 1}` }));
  return ['ui/index.html'];
});

gate('REL-006', 'UTF-8 与乱码防退化', () => {
  const textExt = new Set(['.md', '.m', '.js', '.mjs', '.json', '.html', '.xml', '.csv', '.yml', '.yaml', '.txt']);
  const decoder = new TextDecoder('utf-8', { fatal: true });
  const bad = [];
  for (const rel of trackedFiles()) {
    if (!textExt.has(path.extname(rel).toLowerCase())) continue;
    try {
      const source = decoder.decode(fs.readFileSync(path.join(root, rel)));
      if (source.includes('\uFFFD')) bad.push(`${rel}: replacement character`);
    } catch (error) {
      bad.push(`${rel}: ${error.message}`);
    }
  }
  assert(bad.length === 0, `文本编码异常: ${bad.join('; ')}`);
  return ['.gitattributes'];
});

gate('REL-007', '打包排除规则', () => {
  const build = read('matlab/build_toolbox.m');
  for (const token of ['node_modules', '_verify', '.playwright-mcp', '.git', '.github', 'scripts', 'test-ui', '.mltbx']) {
    assert(build.includes(`"${token}"`), `build_toolbox.m 缺少排除项 ${token}`);
  }
  return ['matlab/build_toolbox.m'];
});

if (artifact) {
  gate('REL-008', 'MLTBX 内容清单', () => {
    assert(fs.existsSync(artifact), `安装包不存在: ${artifact}`);
    const members = execFileSync('tar', ['-tf', artifact], { encoding: 'utf8' }).split(/\r?\n/).filter(Boolean).map((p) => p.replaceAll('\\', '/'));
    const required = [
      'fsroot/ui/index.html',
      'fsroot/matlab/copilot.m',
      'fsroot/matlab/resources/icons/copilot_16.png',
      'fsroot/matlab/resources/icons/copilot_24.png',
      'fsroot/sidecar/src/index.js',
      'fsroot/sidecar/src/permissionServer.js',
      'fsroot/sidecar/src/matlabPermissionProxy.js',
      'fsroot/sidecar/src/projectChangeRecorder.js',
      'fsroot/matlab/+matlabcopilot/ChangeTransaction.m',
      'fsroot/matlab/+matlabcopilot/ModelFileDiff.m',
      'metadata/addonProperties.xml',
      'metadata/configuration.xml',
    ];
    const missing = required.filter((p) => !members.includes(p));
    const forbidden = members.filter((p) => /(^|\/)(node_modules|_verify|_nm_bak|\.playwright-mcp|\.git|\.github|scripts|test|test-ui|slprj)(\/|$)/.test(p) || /(^|\/)playwright\.config\.mjs$|\.(log|tmp|slxc|mltbx)$/i.test(p));
    assert(missing.length === 0, `安装包缺少关键文件: ${missing.join(', ')}`);
    assert(forbidden.length === 0, `安装包包含禁止文件: ${forbidden.join(', ')}`);
    return [path.relative(root, artifact).replaceAll('\\', '/')];
  });

  gate('REL-009', 'MLTBX SHA-256', () => {
    const hash = crypto.createHash('sha256').update(fs.readFileSync(artifact)).digest('hex').toLowerCase();
    assert(hash.length === 64, '无法生成 SHA-256');
    const sumsFile = path.join(root, 'SHA256SUMS.txt');
    assert(fs.existsSync(sumsFile), '缺少 SHA256SUMS.txt');
    const expected = fs.readFileSync(sumsFile, 'utf8').split(/\r?\n/).map((line) => line.trim())
      .filter(Boolean).map((line) => line.split(/\s+/, 2))
      .find(([, name]) => name === path.basename(artifact))?.[0]?.toLowerCase();
    assert(expected, `SHA256SUMS.txt 缺少 ${path.basename(artifact)}`);
    assert(hash === expected, `安装包 SHA-256 与 SHA256SUMS.txt 不一致: actual=${hash}, expected=${expected}`);
    return ['SHA256SUMS.txt', `SHA256:${hash}`];
  });
}

const failed = gates.filter((g) => g.status !== 'PASS');
const result = {
  schema_version: 1,
  generated_at: new Date().toISOString(),
  workspace: root,
  artifact: artifact || '',
  status: failed.length ? 'FAIL' : 'PASS',
  gates,
};

if (reportFile) {
  fs.mkdirSync(path.dirname(reportFile), { recursive: true });
  fs.writeFileSync(reportFile, JSON.stringify(result, null, 2) + '\n');
}

for (const g of gates) {
  const suffix = g.status === 'PASS' ? '' : `: ${g.failure_reason}`;
  console.log(`${g.status.padEnd(4)} ${g.gate_id} ${g.gate_name}${suffix}`);
}
console.log(`\nRelease gate: ${result.status} (${gates.length - failed.length}/${gates.length})`);
if (failed.length) process.exitCode = 1;
