# MBSE RFLPV 工程流程

`matlabcopilot.MBSEWorkflow` 把需求、三层架构、层间分配和验证证据收敛到当前 MATLAB 工程。工程内 CSV/JSON 是可版本化设计源，`.slreqx/.slx/.sldd/.mldatx` 和验证报告是可重建工件。

## 流程与门禁

```text
R Requirements
    |
    v  Implement links
F Functional architecture
    |
    v  F -> L Allocation Set
L Logical architecture
    |
    v  L -> P Allocation Set
P Physical architecture + Profile
    |
    v  requirement-scoped evidence
V Verification report
```

每个阶段均执行同一状态机：

```text
draft -> proposed -> approved -> generated -> executed -> confirmed
```

- `proposed`：设计源结构、唯一性、引用和覆盖关系已校验，同时保存源文件 SHA-256。
- `approved`：用户通过 MATLAB 本地权限卡明确批准该版本提案。
- `generated`：工程内已生成可重复运行的 MATLAB 构建脚本。
- `executed`：真实 MATLAB/Simulink 工件已生成，尚待确认。
- `confirmed`：工件已回读验证，下一阶段才会解锁。

批准后修改当前阶段设计源，后续批准、生成、执行或确认都会被拒绝。点击“重新提案”会重新校验并绑定新哈希，同时作废当前及全部下游阶段状态。

## 工程文件

```text
mbse/
  mbse-workflow.json
  requirements/requirements.csv
  architecture/functional-architecture.json
  architecture/logical-architecture.json
  architecture/physical-architecture.json
  verification-plan.json
  scripts/buildRequirements.m
  scripts/buildFunctional.m
  scripts/buildLogical.m
  scripts/buildPhysical.m
  scripts/runVerification.m
  generated/
    requirements/SystemRequirements.slreqx
    architecture/*.slx
    architecture/*Interfaces.sldd
    architecture/*.mldatx
    architecture/*Profile.xml
    verification/verification-report.json
    verification/verification-report.md
```

`mbse-workflow.json` 的 `ownedArtifacts` 是生成物所有权清单。工作流只能重建自己登记过的文件；同名但未登记的工件会触发 `UnownedArtifact`，不会被覆盖。

## 设计源格式

### R: Requirements

CSV 表头固定为 `ID,Title,Description`；也可使用包含 `id/title/text` 的 JSON 数组。需求 ID 必须非空且唯一。

```csv
ID,Title,Description
REQ-001,Measure temperature,The system shall measure coolant temperature.
REQ-002,Control cooling,The system shall command cooling from measured temperature.
```

### F: Functional

```json
{
  "schemaVersion": 1,
  "modelName": "ThermalControllerFunctional",
  "functions": [
    {
      "name": "MeasureTemperature",
      "description": "Acquire coolant temperature",
      "requirements": ["REQ-001"],
      "inputs": [],
      "outputs": ["Temperature"]
    }
  ],
  "connections": [
    {
      "source": "MeasureTemperature/Temperature",
      "destination": "ComputeCoolingCommand/Temperature"
    }
  ]
}
```

每条需求至少由一个功能引用。连接端点必须使用 `Component/Port`，且只允许已声明的输出连到已声明的输入。

### L: Logical

```json
{
  "schemaVersion": 1,
  "modelName": "ThermalControllerLogical",
  "elements": [
    {
      "name": "SensingUnit",
      "description": "Logical sensing role",
      "functions": ["MeasureTemperature"],
      "requirements": ["REQ-001"],
      "inputs": [],
      "outputs": ["Temperature"]
    }
  ],
  "connections": []
}
```

`functions` 必须引用 F 层真实存在的功能，且所有上游功能都必须至少分配一次。构建结果包含 Logical 模型、接口字典和 F→L Allocation Set。

### P: Physical

```json
{
  "schemaVersion": 1,
  "modelName": "ThermalControllerPhysical",
  "profileName": "ThermalControllerPhysicalProfile",
  "components": [
    {
      "name": "TemperatureSensor",
      "description": "Physical temperature sensor",
      "logicalElements": ["SensingUnit"],
      "requirements": ["REQ-001"],
      "inputs": [],
      "outputs": ["Temperature"],
      "properties": {
        "massKg": 0.1,
        "powerW": 0.5,
        "cost": 20
      }
    }
  ],
  "connections": []
}
```

`logicalElements` 必须引用 L 层元素并全覆盖上游逻辑架构。构建结果包含 Physical 模型、接口字典、L→P Allocation Set 和组件属性 Profile。

### V: Verification

```json
{
  "schemaVersion": 1,
  "verificationItems": [
    {
      "id": "VER-001",
      "requirementId": "REQ-001",
      "method": "architecture_trace",
      "artifact": "",
      "reviewed": false
    },
    {
      "id": "VER-002",
      "requirementId": "REQ-002",
      "method": "matlab_test",
      "artifact": "test/ThermalControllerTest.m",
      "reviewed": false
    }
  ]
}
```

| `method` | 判定规则 |
|---|---|
| `architecture_trace` | 需求在设计源中存在 R→F→L→P 链，且两个 Allocation Set 的实际映射与设计源完全一致 |
| `matlab_test` | `runtests(artifact)` 返回非空结果且所有测试通过 |
| `test_manager` | Simulink Test 可用，`.mldatx` 执行结果至少一项通过且零失败 |
| `artifact_review` | `artifact` 文件存在且提案中 `reviewed=true` |

验证项 ID 必须唯一，每条需求至少需要一个验证项。任一验证失败都会使 V 阶段无法确认。

## MATLAB API

UI 使用者通过工具栏 `◇` 操作。构建脚本和测试可直接调用静态 API：

```matlab
state = matlabcopilot.MBSEWorkflow.status(projectRoot);
result = matlabcopilot.MBSEWorkflow.apply(projectRoot, "propose", "L", struct());
state = matlabcopilot.MBSEWorkflow.executeLogical(projectRoot, state);
matlabcopilot.MBSEWorkflow.saveState(projectRoot, state);
```

`apply` 的写入动作在 Panel 中均经过本地权限卡；Plan 模式强制拒绝。状态事件会同时进入审计和活动的工程变更记录器。

## 验证

```powershell
& 'D:\Software\Matlab2025b\bin\matlab.exe' -batch `
  "addpath('matlab'); r=runtests('test/MBSEWorkflowTest.m'); assertSuccess(r)"
```

回归测试使用 R2025b 真实创建需求集、三层架构、接口字典、分配集、Profile 和验证报告，并覆盖重复执行、陌生工件覆盖保护、设计源漂移与旧状态迁移。
