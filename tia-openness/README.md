# tia-openness · 博途（TIA Portal）接入 skill

让 AI agent 通过西门子官方 **Openness API** 直接读写本机博途工程：不点鼠标、不开界面，
就能枚举工程、导出/导入 PLC 块、修改逻辑、**编译核验**并保存。

适用：TIA Portal V15.1 – V20，S7-1200 / S7-1500（S7-300/400 不支持 Openness）。

---

## 一、工作原理（30 秒版）

1. 安装时创建专用本地用户（默认 `TiaOpenness`），把它加入 `Siemens TIA Openness` 组；
2. 编译一个 x64 命令行工具 `TiaOpen.exe`，并把它写进 Openness 防火墙白名单（注册表）；
3. 之后每个动作都以该用户身份、以**全新交互式登录**启动 `TiaOpen.exe`，
   由它打开工程副本 → 导出/导入/编译 → 写日志。

用户自己的 Windows 账户**不需要**加组、**不需要**注销重登，全程不碰用户的 TIA 界面。

---

## 二、系统要求

| 项 | 要求 |
|---|---|
| OS | Windows 10 / 11 x64（TIA V15.1+ 同版本要求） |
| 博途 | 已安装 TIA Portal + Openness；`<安装>\PublicAPI\<ver>\Siemens.Engineering.dll` 存在 |
| 权限 | 首次安装需要管理员；之后每次调用会静默提权（UAC 需允许） |
| 运行时 | 系统自带 .NET Framework 4.x（`csc.exe`，用于编译工具，无需装 SDK） |
| 端口/网络 | 无外联需求，全部本机 |

---

## 三、安装（每台电脑一次）

```powershell
# 解压后进入 tia-openness 目录
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup.ps1
```

脚本会：探测 Openness 版本 → 建 `C:\ProgramData\TiaOpenness` → 编译 `TiaOpen.exe` →
建用户 + 加组 → 写白名单 → 生成 `config.json` → 自检 `info`（会打印当前运行的 TIA 实例）。

要看结果：

```powershell
Get-Content "$env:USERPROFILE\AppData\Local\Temp\tia-openness-setup.log" -Encoding UTF8
```

可选参数：`-DataDir D:\TiaOpen`、`-User TiaBridge`、`-SkipSelfTest`。

### 装进 DeepSeek Harness（DSH）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-skill.ps1
# 默认装到 %USERPROFILE%\.dsh\skills\tia-openness
# 装到某个项目：-Target "D:\proj\.dsh\skills"
```

DSH 会自动发现 `<skills 根>\<name>\SKILL.md`（只扫一层）。装好后在会话里提到"博途 / TIA / PLC 程序"，
agent 就会按本 skill 的流程操作。

### 部署到另一台电脑

1. 把整个 `tia-openness` 文件夹（含 `scripts\`、`references\`、`SKILL.md`）复用到目标机；
2. 在目标机执行一次 `scripts\setup.ps1`（会按该机的 TIA 版本重新编译 + 重新白名单）；
3. 需要让 DSH 用就再跑一次 `install-skill.ps1`。

> 不要把 `C:\ProgramData\TiaOpenness` 整个拷到别的机器：白名单哈希与该机 exe 绑定，重跑 setup 更可靠。

---

## 四、日常用法

一次动作 = 一个 UTF-8 job 文件 + 一次 `run.ps1` 调用：

```powershell
# job：第 1 行 tag，其余行是工具参数
$lines = @("dump01", "dump", "C:\ProgramData\TiaOpenness\work\MyProject\MyProject.ap20")
[IO.File]::WriteAllText("$env:TEMP\job-dump.txt", ($lines -join "`r`n") + "`r`n",
                        (New-Object System.Text.UTF8Encoding($false)))

powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run.ps1 -Job "$env:TEMP\job-dump.txt"

# 结果（含完整工具日志）
Get-Content "C:\ProgramData\TiaOpenness\logs\dump01.status" -Encoding UTF8
```

先复制工程再动手（避免与用户正在打开的文件抢锁）：

```powershell
[IO.File]::WriteAllText("$env:TEMP\stage-src.txt", "D:\proj\My.ap20",
                        (New-Object System.Text.UTF8Encoding($false)))
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\stage-project.ps1 -SrcFile "$env:TEMP\stage-src.txt"
Get-Content "C:\ProgramData\TiaOpenness\work\last-project.txt" -Encoding UTF8
```

工具模式：`info` / `dump` / `export` / `import` / `compile` / `saveas` / `selfcheck` / `attach`
（详见 `SKILL.md`）。

`export` 会同时导出**变量表**（`<软件>\tags\`），`import` 会把它一起导回去
（V15.1+）：所以"新建一个 PLC 变量"也可以完全不开界面——复制同表里已有的
`<SW.Tags.PlcTag>` 节点，改 `Name` / `DataTypeName` / `LogicalAddress`，再 `import` 即可。
配方见 `references/workflow-playbook.md` 第六节。

---

## 五、安全与卸载

- 专用用户密码保存在 `C:\ProgramData\TiaOpenness\config.json`，ACL 仅 Administrators / SYSTEM / 该用户可读。
- 白名单写的是**该 exe 的 SHA-256 + UTC 修改时间**：工具重编译后必须重跑 `setup.ps1`（会自动更新）。
- 卸载：

```powershell
Remove-LocalUser -Name TiaOpenness
Remove-Item "C:\ProgramData\TiaOpenness" -Recurse -Force
# 白名单条目（可选）：删除 HKLM\SOFTWARE\Siemens\Automation\Openness\<ver>\Whitelist\TiaOpen.exe
```

---

## 六、常见问题

| 现象 | 处理 |
|---|---|
| `The application is not white-listed` | 重跑 `setup.ps1`（重新编译并重写白名单） |
| `Owner '...' ... not member of the windows group 'Siemens TIA Openness'` | 不要 attach 别人的 GUI 实例，改用工程副本（默认流程） |
| `GetProcesses count = 0` | 客户端身份不对（服务/S4U 令牌），改用 `run.ps1` |
| 中文路径报"目录名称无效" | 工程放 `C:\ProgramData\TiaOpenness\work`（`stage-project.ps1` 会授权） |
| import 报 `already contains an object` | 用 `overwrite:yes`（默认已开启） |
| import 报 `no tag Import on this Openness version` | 该版 Openness 不支持变量表导入；块仍会导入，变量在界面里加 |
| import 报 `tag import ERR ...` | 变量 XML 有问题（地址冲突 / 类型名错）；看 `\|` 后的原始消息 |

逐条根因与更多坑见 `references/troubleshooting.md`；安全模型（含注册表布局与实测证据）见
`references/security-model.md`；改码与核验配方见 `references/workflow-playbook.md`。

---

## 七、许可与归属

本工具使用西门子 Openness 公共 API，需遵守《Siemens Openness 许可条款》（随 TIA Portal 安装）。
脚本与 `TiaOpen.cs` 为随附自研代码，可自由修改；修改后记得重跑 `setup.ps1` 更新白名单。
