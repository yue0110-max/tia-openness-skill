---
name: tia-openness
description: 通过 TIA Portal Openness API 直接接入本机博途（TIA Portal V15–V20，S7-1200/1500）读写 PLC 程序：列出工程与块、导出/编辑/导入块 XML、编译核验并保存。当用户要求"接入博途/连上 TIA/分析我 PLC 程序/改程序/检查能否编译通过"，或需要在装有 TIA Portal 的 Windows 机器上做 PLC 代码审查与修改时使用。
whenToUse: 用户提到博途/TIA Portal/S7-1200/S7-1500/.ap1x 工程，要求读取、分析、修改、编译核验或交付 PLC 程序时。首次在机器上使用须先做一次性安装（scripts\setup.ps1）。
---

# 博途（TIA Portal Openness）接入

本 skill 让 agent 在不点鼠标、不开 TIA 界面的前提下操作博途工程：
枚举工程结构与块、把块导出成 XML、编辑后导入、编译核验、保存，最终把结果交回用户的工程目录。

核心机制：一个专用本地用户（默认 `TiaOpenness`，已在 `Siemens TIA Openness` 组内）+ 一个被
Openness 防火墙白名单的 x64 工具 `TiaOpen.exe`，通过 `run.ps1` 以该用户身份启动。
**用户自己的桌面会话不需要重新登录，也不需要给它加组**（详见 `references/security-model.md`）。

## 0. 先确认环境

- Windows + 已安装 TIA Portal（V15.1/V16/V17/V18/V19/V20 任一）+ Openness 组件。
- 安装目录里存在 `PublicAPI\<ver>\Siemens.Engineering.dll`（`setup.ps1` 会自动探测注册表）。
- 需要管理员权限（安装一次性步骤会静默提权；UAC 要求用户点确认时按提示走）。

## 1. 一次性安装

```powershell
# 以管理员身份运行（脚本内部会自己再提权一次，所以普通启动即可）
Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" `
  -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"<skill>\scripts\setup.ps1") -Verb RunAs
```

随后轮询日志（真实用户临时目录，不是 DSH 私有 temp）：

```powershell
Get-Content -LiteralPath "$env:USERPROFILE\AppData\Local\Temp\tia-openness-setup.log" -Encoding UTF8
```

安装做的事：探测 Openness 版本 → 建 `C:\ProgramData\TiaOpenness` 并编译 `TiaOpen.exe`
→ 建本地用户 `TiaOpenness` 并加入 `Siemens TIA Openness` 组 → 写白名单注册表
→ 生成 `config.json`（含该用户密码）→ 自检 `info`。

自定义：`-DataDir D:\TiaOpen -User TiaBridge`。重复运行是幂等的。

## 2. 把工程复制到暂存区（安全副本）

**永远不要直接改用户正在 TIA 里打开的工程**（文件锁 + 无法回滚）。先复制：

```powershell
# 1) 把工程路径写进 UTF-8 文件（路径含中文时不要走命令行参数）
$proj = "D:\work\MyProject\MyProject.ap20"
[IO.File]::WriteAllText("$env:TEMP\stage-src.txt", $proj, (New-Object System.Text.UTF8Encoding($false)))

# 2) 提权复制（会把整个工程文件夹复制到 C:\ProgramData\TiaOpenness\work\<文件夹名>）
Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" `
  -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"<skill>\scripts\stage-project.ps1",
    '-SrcFile',"$env:TEMP\stage-src.txt") -Verb RunAs

# 3) 读复制结果
Get-Content -LiteralPath "C:\ProgramData\TiaOpenness\work\last-project.txt" -Encoding UTF8
```

## 3. 用 job 文件执行动作

每次动作 = 一个 UTF-8 job 文件（第 1 行 tag，第 2 行起是工具参数）+ 一次提权调用 `run.ps1`，
结果在 `C:\ProgramData\TiaOpenness\logs\<tag>.status`（含完整工具日志）。

```powershell
$job = "$env:TEMP\job-dump.txt"
$lines = @("dump01", "dump", "C:\ProgramData\TiaOpenness\work\MyProject\MyProject.ap20")
[IO.File]::WriteAllText($job, ($lines -join "`r`n") + "`r`n", (New-Object System.Text.UTF8Encoding($false)))

Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" `
  -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"<skill>\scripts\run.ps1",'-Job',$job) -Verb RunAs

# 轮询（单次执行 30–120 秒，首次启动 TIA 内核更久）
Get-Content -LiteralPath "C:\ProgramData\TiaOpenness\logs\dump01.status" -Encoding UTF8
```

### 工具模式（`TiaOpen.exe <log> <mode> ...`）

| 模式 | 参数 | 作用 |
|---|---|---|
| `info` | – | 身份、会话、当前运行的 TIA 实例 |
| `dump` | `<工程>` | 设备/软件/块分组/块(名称,块号,语言)/变量表/变量数 |
| `export` | `<工程> <输出目录> [名字过滤]` | 块导出为 XML（按分组建目录）+ 变量表 XML（含变量表子分组） |
| `import` | `<工程> <导出目录> [save:yes\|no] [overwrite:yes\|no]` | 导入块 XML **和变量表 XML**（默认覆盖同名对象、默认保存）；有任何错误时退出码 3 |
| `compile` | `<工程> [save:yes\|no]` | 编译并打印 `State/ErrorCount/WarningCount` 与每条消息 |
| `saveas` | `<工程> <目标目录>` | 另存为（副本/归档） |
| `selfcheck` | `<工程>` | dump + compile，不保存（体检用） |
| `attach` | `<pid>` | 附加到运行中的 GUI 实例（通常不需要，且常被安全模型拒绝） |

## 4. 标准改码流程（分析 → 改 → 核验 → 交付）

1. `stage-project.ps1` 复制工程到暂存区。
2. `dump` → 记录设备、PLC 软件名、块清单（块名/块号/语言）。
3. `export` 到 `C:\ProgramData\TiaOpenness\out\<批次>` → 得到每个块的 XML 和 `tags\` 下的变量表 XML。
4. 用 read/edit 工具改 XML。SCL 块的源码在 XML 里是明文（`<StructuredText>` 或 `SCL` 文本节点），
   改逻辑最稳；LAD/FBD 改 XML 结构易错，优先把逻辑放 SCL 或新建 SCL 块。
   要**新建 PLC 变量**就把 `<SW.Tags.PlcTag>` 节点复制一份改 `Name`/`DataTypeName`/`LogicalAddress`（详见 playbook 第六节）。
5. `import <工程> <批次目录> save:no overwrite:yes` → 看 `IMPORT TOTAL imported = N errors = 0`
   （同一次 import 会先导块、再导 `tags\` 下的变量表）。
6. `compile <工程> save:no` → 必须 `State = Success`、`ErrorCount = 0`。
7. 通过后 `compile <工程> save:yes`（或 import 带 save:yes）落盘。
8. 把暂存区里改好的工程文件夹复制回用户目录（先备份原工程），让用户在 TIA 里重新打开并下载。

**回滚**：暂存区副本本身就是未改动的原始状态；需要回退时重新 `stage-project.ps1` 覆盖即可。
关键改动前后各 `export` 一次，用 diff 对比 XML 是最可靠的"改了什么"证据。

## 5. 硬约束（踩过的坑，务必遵守）

- **不要直接改用户打开的工程**：先复制。TIA 会对 `.apXX` 加锁，且 Openness 保存会与 GUI 冲突。
- **不要试图 `attach` 别人的 GUI 实例**：安全校验读的是 GUI 进程属主令牌里的
  `Siemens TIA Openness` 组；用户桌面会话是在加组之前登录的，必然失败。走离线副本。
- **不要在 DSH 沙箱里直接 `&` 运行 `TiaOpen.exe`**：DSH 受限 Job 里 .NET 进程会崩（0xE0434352）。
  一律经 `run.ps1`（提权 + 专用用户）启动。
- **只改暂存副本**；交付前备份用户原工程。
- **每次重编译 `TiaOpen.exe` 都要重新白名单**（白名单绑 SHA-256 + UTC 修改时间），
  重跑 `setup.ps1` 即可，或 `whitelist.ps1 -Exe <exe 全路径>`。
- **串行执行作业**：一个 job 一个 TIA 实例，别并发跑多个 dump/compile。
- **日志/配置都是 UTF-8（无 BOM）**：读文件必须 `Get-Content -Encoding UTF8`；
  交给提权脚本的路径走 UTF-8 配置文件而不是命令行参数（中文路径会被 ANSI 解码破坏）。
- **变量表导入是 V15.1+ 的可选能力**：日志出现 `no tag Import on this Openness version`
  表示该版本没有 `Import`，变量只能在 GUI 里加（块导入仍然成功）；出现 `tag import ERR <文件> | ...`
  时后面跟的是 Openness 原始消息，最常见是**地址冲突**或 `DataTypeName` 拼错。
- **`import` 有任何错误时退出码 3**：看日志最后一行 `IMPORT TOTAL imported = N errors = M`，
  M > 0 就别急着 compile，先修 XML 再重导。

## 6. 排障速查

| 现象 | 原因 | 处理 |
|---|---|---|
| `The application is not white-listed ... not running in UserInteractive mode` | 白名单缺失/哈希不匹配 | 重跑 `setup.ps1`；确认注册表 `HKLM\SOFTWARE\Siemens\Automation\Openness\<ver>\Whitelist\<exe>\...` |
| `Owner '...' of this process is not member of the windows group 'Siemens TIA Openness'` | 目标 TIA 实例属主不在组内 | 别 attach；改用离线副本（本项目默认路径） |
| `GetProcesses count = 0` | 客户端是网络登录令牌（S4U/服务）或用户不在组 | 用 `setup.ps1` 的专用用户 + `run.ps1`（交互式登录） |
| `Connection to TiaPortal failed.` | 客户端会话/权限不对 | 同上；确认以 `TiaOpenness` 身份运行（日志第一行 identity） |
| `error CS0016: 无法写入输出文件` | 旧 `TiaOpen.exe` 仍在运行 | `Get-Process TiaOpen | Stop-Process -Force` 后重跑 `setup.ps1` |
| import 报 `composition already contains an object` | 未覆盖导入 | `import ... overwrite:yes`（默认已是 yes） |
| 日志 `no tag Import on this Openness version` | 该版 Openness 没有变量表导入 | 只导块；变量在 GUI 里加 |
| 日志 `tag import ERR ... \| ...` | 变量地址冲突 / `DataTypeName` 不认识 / XML 结构不对 | 对照同表已有变量的写法改；地址必须不重复 |
| `目录名称无效` / 访问被拒 | 目标用户无权访问该路径 | 工程放 `C:\ProgramData\TiaOpenness\work`（`stage-project.ps1` 自动处理 ACL） |

更多细节：`references/security-model.md`（安全模型与注册表布局证据）、
`references/troubleshooting.md`（逐条症状-根因-修复）、
`references/workflow-playbook.md`（改 SCL/块号/备份/批量导出的具体做法）。

## 7. 目录结构

```
tia-openness/
  SKILL.md
  README.md                      ← 给用户看的安装说明（含其它电脑部署）
  references/
    security-model.md
    troubleshooting.md
    workflow-playbook.md
  scripts/
    setup.ps1            一次性安装（探测/编译/建用户/白名单/配置/自检）
    whitelist.ps1        单独写 Openness 白名单
    stage-project.ps1    复制工程到暂存区并授权
    run.ps1              以专用用户执行 job
    install-skill.ps1    把本 skill 装到 DSH 的 skills 目录
    tools/TiaOpen.cs     Openness 命令行工具源码（setup 时编译）
```

数据目录（不要手改）：`C:\ProgramData\TiaOpenness\`
`config.json`、`TiaOpen.exe`、`work\`（工程副本）、`out\`（导出）、`logs\`（作业日志）、`jobs\`。
