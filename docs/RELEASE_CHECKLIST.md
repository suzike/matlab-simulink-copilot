# Release 验收清单

发布检查必须以最终 `MATLAB-Copilot.mltbx` 为输入，不能只验证仓库源码。

## 自动门禁

```powershell
Set-Location sidecar
npm ci
npx playwright install chromium
npm run release:verify
```

`release:verify` 依次执行：

1. Sidecar Node 单元测试。
2. 36 项 Playwright 桌面与窄屏布局测试，检查工程切换隔离、有界会话墓碑、三态快捷栏、滚轮横移、悬停边界、消息操作条与权限卡间距、空模型下拉、分阶段变更记录器、RFLPV 弹窗、横向溢出和按钮文字越界。
3. 版本一致性、运行时零依赖、Git 清单、UTF-8、UI 脚本语法、打包排除规则和 `.mltbx` 内容检查。

`.mltbx` 只保留运行时源码、MATLAB 验收入口和用户文档；CI、Playwright 用例、Node 单测、发布脚本、`node_modules` 与临时证据目录不得进入安装包。

机器可读静态报告：

```powershell
node scripts/release-check.mjs `
  --artifact MATLAB-Copilot.mltbx `
  --report _verify/quality_gate_results.json
```

## MATLAB R2025b 验收

默认模式不会改变已安装的 Add-On。脚本解包最终 `.mltbx`，直接对包内文件执行类加载、`checkcode`、`copilot_doctor` 和 Echo TCP 全链路；doctor 在验收中使用临时空闲端口，不受当前面板或其他本地服务影响：

```matlab
addpath('matlab')
report = release_acceptance('MATLAB-Copilot.mltbx', ...
    ReportFile='_verify/matlab-release-acceptance.json');
assert(report.status == "PASS")
```

在专用干净 MATLAB 用户环境中执行注册安装验收：

```matlab
report = release_acceptance('MATLAB-Copilot.mltbx', ...
    InstallPackage=true, ...
    ReportFile='_verify/matlab-clean-install.json');
```

如果当前环境已经安装 MATLAB-Copilot，脚本默认拒绝替换。只有确认可覆盖该环境时才设置 `AllowReplace=true`。

替换安装后必须用一个未注入仓库源码路径的新 MATLAB 进程确认真实 Add-On 版本和冷启动路径：

```matlab
s = setupMATLABCopilot("status");
assert(s.ok && s.startupManaged)
assert(contains(which('copilot'), 'MATLAB Add-Ons'))
```

## MATLAB 跨版本 CI

`.github/workflows/quality-gates.yml` 必须在最终提交上完成以下三个 job：

1. `sidecar-ui-release`：Node、Playwright 和静态发布门禁。
2. `MATLAB R2023b compatibility`：R2023b + Simulink 类加载、静态检查和兼容性测试。
3. `MATLAB R2025b compatibility`：R2025b + Simulink 同一组跨版本门禁。

任一 job 未完成、跳过或失败时不得发布正式 Release。

## 文档与截图

README 主图应从当前前端源码可复现生成：

```powershell
Set-Location sidecar
node ..\scripts\capture-doc-screenshots.mjs
```

生成后人工检查三张 v0.14.2 JPG：功能区、变更记录器弹层、RFLPV 弹层、输入框和底栏不得重叠，按钮不得裁切或文字越界。静态 SVG 架构图、数据流图、功能图和会话生命周期图必须与 `AGENTS.md` 中的协议和安全边界一致。

## 发布前人工确认

- GitHub Actions `Quality gates` 通过。
- MATLAB 验收 JSON 状态为 `PASS`。
- Ask / Auto / Plan 权限矩阵在真实 MATLAB 面板中抽查通过。
- 多标签、Fork、Stop、关闭会话和附件清理抽查通过。
- 从当前 `ui/index.html` 可复现生成三张 README 全屏浏览器截图，并人工确认工具栏、三态控件、快捷栏、输入框、记录器与 RFLPV 弹层与 Release 一致。
- 重新生成 `MATLAB-Copilot.mltbx` 与 SHA-256。
- Release 资产来自当前提交，版本号与 README、CHANGELOG、package 和工具箱一致。

## GitHub Release 核验

创建 `vX.Y.Z` 标签和正式 Release 后，至少上传：

- `MATLAB-Copilot.mltbx`
- `SHA256SUMS.txt`

发布完成后重新下载或查询 Release 资产，确认标签指向最终提交、两个附件均存在、`.mltbx` 大小非零，且其 SHA-256 与 `SHA256SUMS.txt` 一致。Release 页面不得保持 Draft 或错误标记为 Pre-release。
