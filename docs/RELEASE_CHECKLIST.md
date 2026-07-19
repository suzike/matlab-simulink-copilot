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
2. 22 项 Playwright 桌面与窄屏布局测试，检查三态快捷栏、滚轮横移、悬停边界、空模型下拉、变更记录器任务证据、横向溢出和按钮文字越界。
3. 版本一致性、运行时零依赖、Git 清单、UTF-8、UI 脚本语法、打包排除规则和 `.mltbx` 内容检查。

`.mltbx` 只保留运行时源码、MATLAB 验收入口和用户文档；CI、Playwright 用例、Node 单测、发布脚本、`node_modules` 与临时证据目录不得进入安装包。

机器可读静态报告：

```powershell
node scripts/release-check.mjs `
  --artifact MATLAB-Copilot.mltbx `
  --report _verify/quality_gate_results.json
```

## MATLAB R2025b 验收

默认模式不会改变已安装的 Add-On。脚本解包最终 `.mltbx`，直接对包内文件执行类加载、`checkcode`、`copilot_doctor` 和 Echo TCP 全链路：

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

## 发布前人工确认

- GitHub Actions `Quality gates` 通过。
- MATLAB 验收 JSON 状态为 `PASS`。
- Ask / Auto / Plan 权限矩阵在真实 MATLAB 面板中抽查通过。
- 多标签、Fork、Stop、关闭会话和附件清理抽查通过。
- MATLAB R2025b 从当前源码重新 `exportapp` 两张 README 主图，并人工确认工具栏、三态控件、快捷栏和权限卡与 Release 一致。
- 重新生成 `MATLAB-Copilot.mltbx` 与 SHA-256。
- Release 资产来自当前提交，版本号与 README、CHANGELOG、package 和工具箱一致。
