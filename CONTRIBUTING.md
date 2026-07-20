# 贡献指南

感谢参与 MATLAB / Simulink Copilot。提交改动前请先确认它符合本项目的目标：在 MATLAB 内提供可审计、权限受控、能够操作真实工程上下文的 AI 助手，而不是另建独立 Web 应用或绕过 MATLAB MCP。

## 开始之前

1. 对较大功能先创建 GitHub Issue，说明使用场景、影响范围和验收方式。
2. Fork 仓库并从最新 `main` 创建功能分支。
3. MATLAB / Simulink 改动先阅读 `AGENTS.md`；发布工作同时阅读 `docs/RELEASE_CHECKLIST.md`。
4. 不提交 API key、token、cookie、MATLAB 会话文件、测试工程或 `_verify/` 临时证据。

## 开发环境

- Windows 11
- MATLAB R2023b 或更高版本，推荐 R2025b，并安装 Simulink
- Node.js 20 或更高版本
- Claude Code 或 Codex CLI（只在真实后端联调时需要）
- Simulink Agentic Toolkit（MATLAB MCP 集成测试需要）

Sidecar 运行时零 npm 依赖；开发测试依赖通过以下命令安装：

```powershell
Set-Location sidecar
npm ci
npx playwright install chromium
```

## 代码边界

- `ui/index.html`：无 CDN 的单文件 `uihtml` 前端。
- `matlab/+matlabcopilot/`：MATLAB 面板、上下文、事务与确定性工程能力。
- `sidecar/src/`：TCP 协议、会话、权限和后端适配器。
- `test/`、`sidecar/test/`、`sidecar/test-ui/`：MATLAB、Node 和浏览器回归。
- `README.md`、`INSTALL.md`、`CHANGELOG.md`、`plan.md`、`AGENTS.md`：用户、安装、版本、计划和维护事实。

协议新增字段必须经过全 ASCII 序列化，并处理 MATLAB JSON 的空值、标量和数组差异。破坏性 MATLAB 操作必须复用 Ask / Auto / Plan 权限语义；不得使用跳过权限的 CLI 参数。

## 验证

提交前至少运行与改动范围匹配的测试。完整本地门禁为：

```powershell
Set-Location sidecar
npm test
npm run test:ui
npm run release:check -- --artifact ../MATLAB-Copilot.mltbx
```

MATLAB 核心测试：

```matlab
addpath('matlab')
r = runtests({'test/ChangeTransactionTest.m', ...
              'test/ModelFileDiffTest.m', ...
              'test/PanelUtilityTest.m', ...
              'test/SetupTest.m'});
assertSuccess(r)
```

涉及打包、安装器、MATLAB 类清单或用户文档时，还必须重新构建 `.mltbx`，执行 `release_acceptance`，并按 `docs/RELEASE_CHECKLIST.md` 验证最终安装包。

## 文档和截图

- 行为、协议、安装方式、测试数量或版本变化时，同步更新对应开发文档。
- README 主图必须由当前 `ui/index.html` 生成，不得复用旧版本截图。
- 可复现截图使用 `node scripts/capture-doc-screenshots.mjs`；提交前人工检查桌面和窄屏没有遮挡、裁切或文字越界。
- 不使用 Mermaid；架构和流程图维护为仓库内 SVG 文件。

## Pull Request

PR 描述应包含：问题与目标、关键实现、风险或兼容性影响、实际执行的测试、界面改动截图。提交信息建议遵循 Conventional Commits，例如：

```text
fix: prevent recorder evidence from crossing model boundaries
feat: add recoverable project change sessions
docs: synchronize v0.13.0 development documents
```

维护者只会在门禁通过、文档与当前行为一致、权限边界未弱化后合并。
