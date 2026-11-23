# dsh-tia-openness

[![DSH plugin](https://img.shields.io/badge/DeepSeek%20Harness-plugin-0f172a)](https://github.com/awesome-dsh-plugin/awesome-dsh-plugin)
[![TIA Portal](https://img.shields.io/badge/TIA%20Portal-V15.1--V20-22d3ee)](https://support.industry.siemens.com/)
[![Platform](https://img.shields.io/badge/platform-Windows%20x64-blue)](#要求)

一个 **[DeepSeek Harness](https://github.com/deepseek-ai)** 插件（bundle）：装进 DSH 之后，
agent 就能通过**西门子 TIA Portal Openness API** 直接读写本机的博途工程——列工程与块、
导出/编辑/导入块 XML 与变量表 XML、编译核验、另存——**全程不用打开 TIA 界面**。

同时它只是一个**可独立使用的 skill**：不装插件，把 `tia-openness/` 文件夹放进
`%USERPROFILE%\.dsh\skills\` 也行。

```
仓库根 = 插件包
├── index.js              宿主侧：注册 skill + 一个只读诊断工具
├── cordis.patch.yml      bundle 补丁层（一条 insert）
├── package.json          name: dsh-tia-openness，dsh.bundle.patch 指向上面那个文件
├── locale/{zh,en}.json   商城卡片文案
├── icon.svg              包内图标
├── docs/detail.{zh,en}.md 详情页
├── test/smoke.mjs        不依赖 DSH 的冒烟测试
└── tia-openness/         skill 本体
    ├── SKILL.md
    ├── references/{workflow-playbook,security-model,troubleshooting}.md
    └── scripts/{setup,run,stage-project,whitelist}.ps1 + tools/TiaOpen.cs
```

## 它注册了什么

| 注册项 | 作用 |
| --- | --- |
| skill `tia-openness` | 把 `tia-openness/` 作为 skill 载荷注册，`resourceBase` 指向该目录，所以 `SKILL.md` 里的 `scripts\setup.ps1` 等相对路径在包装到任何位置后都能解析 |
| 工具 `tia_openness_status` | 只读诊断，无参数：报告脚本是否齐全、`C:\ProgramData\TiaOpenness` 里的工具链是否已编译/配置、本机装了哪些 `Portal V*`、以及下一步该执行的**确切命令** |

插件本身**不**把 PowerShell 启动包装成常驻服务：真正的工程操作是一次特权、分钟级的
可见动作，由 agent 通过 skill 发起，用户能看见、能中断。

## 要求

- Windows x64
- 博途 **TIA Portal V15.1–V20**（安装时勾选 Openness 组件），目标 CPU 为 S7-1200 / S7-1500
- 一次性配置需要管理员权限（写 `C:\ProgramData\TiaOpenness` 与 Openness 白名单）
- Node.js ≥ 22（DSH 自带）

## 安装

**作为插件**（推荐）：市场里搜 `dsh-tia-openness`，或从本仓库安装：

```powershell
# 在 DSH 里用 plugin_manager 安装本目录（绝对路径）
# 或用 CLI：
dsh plugin install "C:\path\to\tia-openness-skill"
```

**作为 skill**：只把 skill 放进用户级目录，不用插件：

```powershell
.\tia-openness\scripts\install-skill.ps1
# 等价于：把 tia-openness\ 整个文件夹复制到 %USERPROFILE%\.dsh\skills\
```

> 目录名就是 skill 名（`install-skill.ps1` 取的是文件夹名），所以 `tia-openness`
> 这一层不能少。

## 一次性配置

装好后先调一次 `tia_openness_status`；若提示未配置，在**管理员** PowerShell 执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<安装位置>\tia-openness\scripts\setup.ps1"
```

它会：建专用本地用户（默认 `TiaOpenness`）→ 编译 `scripts\tools\TiaOpen.cs` 成
`C:\ProgramData\TiaOpenness\bin\TiaOpen.exe` → 把该 exe 的 **SHA-256 + 修改时间**
写进 Openness 白名单 → 生成 `C:\ProgramData\TiaOpenness\config.json`。

改过 `TiaOpen.cs` 之后**必须重跑 `setup.ps1`**：白名单绑的是 exe 哈希。

## 用法

```powershell
# 1) 复制工程副本并授权（原工程不动）
.\tia-openness\scripts\stage-project.ps1 -Project "D:\proj\Line1.ap18"

# 2) 写一个 job 文件，交给 run.ps1 执行
.\tia-openness\scripts\run.ps1 -Job job.json -DataDir "C:\ProgramData\TiaOpenness"
```

job 支持的动作：`info` / `dump` / `export` / `import`（块 XML + V15.1+ 变量表 XML）/
`compile` / `saveas` / `selfcheck`。退出码 `0` 成功、`2` 用法、`3` 工具失败（含
import/compile 报错）、`4` 超时、`5` 未提权、`6` 启动失败；日志在
`C:\ProgramData\TiaOpenness\logs\<tag>.log`。

细节见 [`tia-openness/SKILL.md`](tia-openness/SKILL.md) 与
[`references/workflow-playbook.md`](tia-openness/references/workflow-playbook.md)。

## 能做什么 / 不能做什么

| 能做 | 不能做（仍需 GUI 一次） |
| --- | --- |
| 列工程、设备、块分组 | 下载到 PLC / 在线监视 |
| 导出块为 SCL 或 LAD 的 XML | HMI / WinCC |
| 改 SCL 逻辑与接口、导入块 | 硬件组态与报文选择 |
| 新建 DB 与成员、改接口变量 | 创建工艺对象（TO） |
| 导入/导出 PLC 变量表（V15.1+） | 从全局库拖入库块（`SINA_POS`、`FB_PN352`） |
| 编译并逐条读错误/警告 | 删除块 |
| 另存工程 | — |

调用系统指令（`MC_Power` 等）不需要额外文件，Openness 按名字解析；但指令指向的
工艺对象必须已经存在，否则编译必错。

## 安全模型

- 每次动作都以专用用户**全新登录**启动一次 `TiaOpen.exe`，跑完即退；不常驻、不开端口。
- 只操作 `work\` 下的**工程副本**，原工程不被修改。
- Openness 白名单按 exe 的 SHA-256 + 修改时间校验。
- 口令存在 `C:\ProgramData\TiaOpenness\config.json`，插件不读取、不传输。
- 详见 [`tia-openness/references/security-model.md`](tia-openness/references/security-model.md)。

## 验证状态

- 包内 `node --test test/smoke.mjs` 4 项全绿；`index.js` 通过 `node --check`。
- `tia_openness_status` 在真实机器上验证过：能识别装在 `D:\TIA` 的博途（读 Openness
  注册表而不是只扫 `C:\Program Files`），也能报出"安装的 exe 比随包源码旧"。
- `TiaOpen.cs` 整文件 `csc` 编译 0 个语法错误（只缺 Siemens 类型），新增方法体桩编译 `exit 0`。
- **块的 dump / export / import / compile 已在真实 TIA Portal V20 工程上跑通**；
  本版本新增的**变量表导入**只做了代码级验证，尚未在真实工程上完成一轮往返。
- 远端文件与本地暂存逐字节一致（发布脚本自带校验）。

首次在目标机器使用时，建议先 `export` 一次变量表 → 原样 `import` → `compile`，
确认 `IMPORT TOTAL imported = N errors = 0` 且编译无错，再开始改程序。
改过 `TiaOpen.cs` 后 `tia_openness_status` 会提示 `exe matches shipped source: no`，
此时必须重跑 `setup.ps1`（重编译 + 重写白名单）。

## 许可

插件代码（`index.js`、`cordis.patch.yml`、`test/`、`locale/`、`docs/`）随本仓库发布，
可自由使用与修改。skill 载荷（`tia-openness/`）按其自身 `README.md` 的说明使用。
