# 排障手册：症状 → 根因 → 处理

先看两个日志位置：

- 安装/白名单：`%USERPROFILE%\AppData\Local\Temp\tia-openness-setup.log`（提权脚本自己写的，UTF-8）
- 每次动作：`C:\ProgramData\TiaOpenness\logs\<tag>.status`（`run.ps1` 汇总，含完整工具日志）

所有日志都是 **UTF-8 无 BOM**，读的时候必须 `Get-Content -Encoding UTF8`，否则中文乱码。

---

## A. Openness / TIA 相关

| 症状（原文） | 根因 | 处理 |
|---|---|---|
| `The application is not white-listed and the Openness Access dialog can´t be shown since the application is not running in UserInteractive mode.` | 白名单条目缺失 / 哈希或修改时间不匹配 / 版本键写错 | 重跑 `setup.ps1`；或 `whitelist.ps1 -Exe "<exe 全路径>"`。核对 `HKLM\SOFTWARE\Siemens\Automation\Openness\20.0\Whitelist\<exe>\<子键>` 三个值 |
| `Security error … Owner 'X' of this process is not member of the windows group 'Siemens TIA Openness'` | ① 客户端令牌不在组（用错身份）；② **attach 时**目标 TIA 实例属主令牌不在组 | ① 用 `run.ps1`（专用用户）而不是服务/计划任务；② 不要 attach，走副本 |
| `GetProcesses count = 0` | 客户端是网络登录令牌（S4U/服务）或不在组 | 同上；确认 status 头几行 `identity = <机器>\TiaOpenness` |
| `Siemens.Engineering.NonRecoverableException | Connection to TiaPortal failed.` | 客户端会话不对（session 0 / 无桌面 / 令牌异常），或 TIA 安装损坏 | 用 `run.ps1`；确认 `userInteractive = True`；必要时重启 `SiemensTiaAdminV3` 服务 |
| `非交互会话里连不上，报 Security error（非白名单）` | 同上：S4U/ SYSTEM 令牌 | 换专用用户交互式登录 |
| `Projects.Open` 报文件被占用 / 打不开 | 用户的 TIA GUI 已打开同一工程 | 用 `stage-project.ps1` 复制副本再开 |
| 动作卡住 > 2 分钟 | 首次启动 TIA 内核慢（AUTO 更新、服务未启动） | 首次给 3–5 分钟；后续 30–40 秒。别并发 |
| `compile State = Error` | 导入的 XML 有语法/接口不一致 | 看 messages 里的 `Path`/`Message`；`export` 后再 `import` 原样文件可作为对照 |
| `import` 报 `Cannot import object with Simatic ML ID '0' … already contains an object with the same values for the identifier(s) 'Name, Namespace'` | 同名块已存在且未覆盖 | `import … overwrite:yes`（默认已开） |
| `import` 报 `The block is inconsistent / 需要重新编译` | 块被外部修改后未编译 | 正常：`compile` 一次即可 |
| `saveas` 报参数类型错（`CS1502`） | `Project.SaveAs` 只接受 `DirectoryInfo` | 代码里用 `new DirectoryInfo(dir)`；工具用法 `saveas <src> <目标目录>` |
| 日志 `no tag Import on this Openness version` | 该版本的 `PlcTagTableComposition` 没有 `Import(FileInfo)` 重载（工具是反射找的） | 不是错误：块照常导入；变量只能在 GUI 里加。V15.1+ 一般都有 |
| 日志 `tag import ERR <文件> \| Siemens.Engineering.…: <消息>` | 变量 XML 本身有问题：地址冲突、`DataTypeName` 不认识、节点结构不对 | 看 `\|` 后面的原始消息；对照同一张表里**已有变量**的写法改；地址必须唯一且位/字节粒度对得上 |
| 日志 `created tag group <名>` 之后又报导入失败 | XML 里的表名与目标分组不一致，或组名非法 | 表名放在 `<AttributeList><Name>`，分组靠**目录层级**表达 |
| 日志 `skip tag subfolder <名> (group could not be resolved)` | 该 Openness 版本的 `TagTableGroup` 没有 `Groups.Create` | 把变量表放到已有的分组里，或直接在顶层 `tags\` 下放文件 |
| `import` 退出码 3 但块都导进去了 | 变量表有错误（`IMPORT TOTAL … errors = N`，N>0） | 正常设计：块成功 + 变量失败也算失败。修完变量 XML 重导 |

### 白名单随手核查

```powershell
$k = "HKLM:\SOFTWARE\Siemens\Automation\Openness\20.0\Whitelist\TiaOpen.exe"
Get-ChildItem $k | ForEach-Object { $_.PSChildName; Get-ItemProperty $_.PSPath | Format-List Path,DateModified,FileHash }
# 对照真实值：
$f = Get-Item "C:\ProgramData\TiaOpenness\TiaOpen.exe"
$f.LastWriteTimeUtc.ToString("yyyy/MM/dd HH:mm:ss.fff")
[Convert]::ToBase64String((Get-FileHash $f.FullName -Algorithm SHA256).Hash -split '(..)' | ? {$_} | % {[Convert]::ToByte($_,16)})
```

---

## B. PowerShell / 编译脚本相关（本 skill 已内置规避，自己改脚本时注意）

| 症状 | 根因 | 处理 |
|---|---|---|
| `warning CS2008: 未指定源文件` / `error CS1562: 无法为没有源文件的生成指定 /out` | 通过 `Start-Process -ArgumentList` 传含引号的数组参数，PowerShell 5.1 解析不可靠 | 用 **csc 响应文件**：把每个参数写成一行，`Start-Process $csc -ArgumentList ('@"{0}"' -f $rsp)` |
| 编译"成功"但行为没变 | **csc 把错误写到 stdout，不是 stderr** | 必须同时读 `*.out` 与 `*.err` |
| `error CS0016: 无法写入输出文件 … 因为另一个进程正在使用此文件` | 上一次的 exe 还在跑 | `Get-Process TiaOpen | Stop-Process -Force`；或先编译到 `<name>.build.exe` 再 `Move-Item -Force` |
| 脚本里的中文路径变乱码/找不到路径 | **BOM 的锅**：Windows PowerShell 5.1 读无 BOM 的 UTF-8 `.ps1` 会按 ANSI 解码 | 脚本正文只写 ASCII；中文路径写进 **UTF-8 配置文件**，脚本用 `Get-Content -Encoding UTF8` 读 |
| 读日志中文乱码 | `Get-Content` 默认 ANSI 解码 | 一律 `-Encoding UTF8` |
| `(Get-Content $f)[0]` 只拿到第一个字符 | 对**单行文件** `Get-Content` 返回单个字符串，`[0]` 是字符索引 | `@(Get-Content $f -Encoding UTF8 | Where-Object { $_.Trim() })[0].Trim()` |
| `Start-Process -Verb RunAs -RedirectStandardOutput` 报参数集错误 | 两者不能同时用 | 提权脚本自己写日志文件 |
| `-Credential` 启动后 `$proc.ExitCode` 为空 | `Start-Process -PassThru` 对提权/凭据进程拿不到退出码 | 从工具日志正则 `== done rc=(\d+) ==` 取 |
| `Start-Process -Credential` 报"拒绝访问" | 调用方未提权 | 该调用必须在提权脚本里做 |
| `目录名称无效` / 目标进程起不来 | workdir 对目标用户不可访问（比如 `C:\Users\<A>\Desktop`） | 把 workdir 指到 `C:\ProgramData\TiaOpenness`（脚本已 `icacls`） |
| `Start-Service` 报"无法启动服务"但进程确实跑了 | 服务进程不调用 `StartServiceCtrlDispatcher` | 只要日志有内容就当成功；靠日志判断 |
| 在 DSH 沙箱里 `& TiaOpen.exe` 崩溃 `-532462766`(0xE0434352) | 受限 Job 里 .NET 进程无法正常初始化 | 一律经 `run.ps1`（提权 + 专用用户）启动 |
| DSH 里写 `%USERPROFILE%\AppData\Local\Temp` 被拒 | 沙箱只允许 DSH 私有 temp 与工作区 | 用 `$env:TEMP`（DSH 私有）或工作区；提权脚本的日志另说 |
| `Get-CimInstance Win32_Process` 报"无法从客户端中访问 CIM 资源" | 非提权会话 | 用 `Get-Process`，或读 PEB 的 `CommandLine` |

---

## C. 在"别的电脑上"装不上时的顺序排查

1. **有没有 Openness**：`Get-ItemProperty HKLM:\SOFTWARE\Siemens\Automation\Openness\<ver>\PublicAPI\<ver>` 能否读到 `Siemens.Engineering` 路径？
   （注意：TIA 常装在 `D:\` 等自定义盘，也有 32/64 位两个视图。）
2. **组存在吗**：`Get-LocalGroup -Name "Siemens TIA Openness"`。不存在说明 Openness 组件没装。
3. **用户建成了吗**：`Get-LocalUser TiaOpenness`，`Get-LocalGroupMember "Siemens TIA Openness"`。
4. **白名单写了吗**：见上面 A 节最后一段。
5. **编译成功了吗**：`C:\ProgramData\TiaOpenness\build.rsp` 与 `logs\build.out`。
6. **自检**：`run.ps1` 跑 job（`info`），看 `identity`/`session`/`userInteractive`/`GetProcesses count`。
7. **权限**：`icacls C:\ProgramData\TiaOpenness` 里专用用户是否有 modify。

---

## D. 需要"停掉一切"时的清理

```powershell
Get-ScheduledTask -TaskName 'TiaOpenness*' -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false
Get-Service -Name 'TiaOpenness*' -ErrorAction SilentlyContinue | Stop-Service -Force
Get-Process TiaOpen -ErrorAction SilentlyContinue | Stop-Process -Force
Remove-Item "C:\ProgramData\TiaOpenness\work\*" -Recurse -Force -ErrorAction SilentlyContinue
```

（本 skill 不装服务、不建计划任务；上面是给早期实验残留物兜底用的。）
