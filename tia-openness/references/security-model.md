# Openness 安全模型：为什么必须"专用用户 + 白名单"

这份文档解释 `setup.ps1` 为什么这样做，以及在别的机器上出错时该看哪一层。
所有结论都来自对 `Siemens.Automation.Opns.Loader.Impl.dll` 的反编译与实机实验（TIA V20 / Windows 11 x64）。

---

## 一、Openness 的三道闸门

一个客户端进程（`TiaOpen.exe`）想连上 TIA Portal，必须同时满足：

| 闸门 | 判定者 | 判定依据 | 失败时的异常 |
|---|---|---|---|
| ① 白名单 | 客户端侧 Loader（`...Opns.Loader.Impl.dll`） | 注册表里存在与**当前 exe** 完全匹配的条目 | `EngineeringSecurityException` + *The application is not white-listed…* |
| ② 客户端令牌在组内 | 客户端侧 | **调用进程令牌**里是否有 `Siemens TIA Openness` 组 | `EngineeringSecurityException` + *Owner '…' of this process is not member of the windows group…* |
| ③ 目标实例属主在组内（仅 attach 已运行实例时） | 服务端 | **被附加的 TIA 进程属主令牌**里是否有该组 | 同上，但报文里的 Owner 是 GUI 的账户 |

③ 是很多人踩的坑：`Attach()` 到"用户自己开着的 TIA"时，检查的是**用户会话令牌**。
如果把账户加进组之前用户就登录了，他的令牌是旧快照 → attach 必然失败，
除非用户注销重登。这也是本 skill 坚持"离线副本、不 attach"的原因。

---

## 二、闸门①：白名单的精确格式（反编译结论）

键路径（**只读 HKLM 64 位视图**，键名是 `<major>.<minor>`，不是产品名）：

```
HKLM\SOFTWARE\Siemens\Automation\Openness\<major>.<minor>\Whitelist\<exe 文件名>\<任意子键名>
    Path         REG_SZ     exe 全路径
    DateModified REG_SZ     exe 的 LastWriteTimeUtc，格式 yyyy/MM/dd HH:mm:ss.fff
    FileHash     REG_SZ     Base64(SHA-256(exe 文件字节))
```

几个致命细节：

- 版本目录取 `Assembly.GetName().Version` 的 `major/100` 与 `major%100` → V20 得 `20.0`。
  写 `V20.0` 之类的别名**不会被读到**。
- `DateModified` 必须是 **UTC**。写本地时间会静默不匹配（我们最初就栽在这里：
  本地 `2026/11/20 17:19:40.954` vs 正确 UTC `2026/11/20 09:19:40.954`）。
- 比较是 `路径(忽略大小写) + 文件名 + LastWriteTimeUtc + SHA-256` 全等；
  **重编译 exe 后旧条目自动失效**，必须重写。
- 非交互会话（服务、计划任务、无桌面）弹不出授权对话框，错误信息就是
  *The application is not white-listed and the Openness Access dialog can´t be shown since the application is not running in UserInteractive mode.*
  → 只能程序化写注册表（`whitelist.ps1` 干这个）。
- TIA 自己写的正规工具是 `<TIA>\Bin\Siemens.Automation.Opns.Firewall.exe /a RegKey=… Path=… DateModified=… FileHash=…`；
  我们的脚本直接写注册表，效果等价且不依赖 TIA 运行。

> 结论：**exe 一旦改动就必须重跑 `setup.ps1`（或 `whitelist.ps1 -Exe <路径>`）**。

---

## 三、闸门②：为什么不能"借用"管理员令牌

`Siemens TIA Openness` 组的成员资格来自**登录时生成的访问令牌**。以下几种常见"捷径"实测全部无效：

| 尝试 | 结果 |
|---|---|
| 加组后直接提权（`Start-Process -Verb RunAs`） | 令牌是同一登录会话的快照，**不含新组** |
| 计划任务 `LogonType=Interactive` | 复用已有交互令牌，仍不含新组 |
| 计划任务 `LogonType=S4U` / 服务 `LocalSystem` | 能生成新令牌、**含组**，但：S4U 是"网络登录"，令牌特权被过滤（`SeTcb`/`SeCreateToken` 显示"启用成功"实际仍禁用），且 `TiaPortal.GetProcesses()` 返回 0；服务运行在 session 0，同样枚举不到 GUI 实例 |
| 给已有令牌加组 | `SetTokenInformation(TokenGroups)` → `ERROR_INVALID_PARAMETER(87)`；`NtSetInformationToken` → `STATUS_INVALID_INFO_CLASS(0xC0000003)`。**TokenGroups 是只读信息类** |
| 自造令牌 | 需要 `SeCreateTokenPrivilege`；提权管理员、SYSTEM（开机登录会话）都没有该特权；LSA 授权只对**之后**的登录生效。放弃 |

### 可行的组合：新建本地用户 + 全新交互式登录

- 新用户第一次登录时生成**全新令牌** → 天然带组（`setup.ps1` 建用户并加组）；
- 通过 `Start-Process -Credential` / `CreateProcessWithTokenW(LOGON_WITH_PROFILE)` 启动 → 属于**交互式登录会话**（`AuthenticationId` 是新的 logon LUID，有窗口站 `winsta0\default`）；
- 该身份 `TiaPortal.GetProcesses()` 能正常看到用户的 GUI 实例（实测 count=2），
  `Projects.Open()` 打开副本也能正常工作。
- 不需要管理员权限也能跑（`elevated=False` 依然可以）——只是安装步骤需要管理员。

> 这就是为什么 `setup.ps1` 建一个 `TiaOpenness` 用户并把密码写进 `config.json`：
> 它换来的是"干净的新登录令牌"，而不是给用户机器开一个管理员后门。
> 该用户只加入 `Siemens TIA Openness` 一个组（不加入 Administrators）。

---

## 四、为什么是"离线副本"而不是"接管用户界面"

1. 闸门③：用户当前登录令牌很可能不含组（加组发生在登录之后）；
2. 文件锁：用户 TIA 已打开工程，`Projects.Open` 同一路径会冲突；
3. 可回滚：副本坏了重新复制即可，用户原工程始终干净；
4. 速度：`WithoutUserInterface` 模式 30–40 秒一次动作，不占用用户屏幕。

交付时把副本覆盖回用户目录（先备份原件），用户重开 TIA 即可下载到 PLC。

---

## 五、凭据与权限清单

| 内容 | 位置 | 保护 |
|---|---|---|
| 专用用户密码 | `C:\ProgramData\TiaOpenness\config.json` | ACL：仅 Administrators/SYSTEM/该用户 |
| 白名单条目 | HKLM 注册表 | 需要管理员写入 |
| 工程副本 | `C:\ProgramData\TiaOpenness\work\` | `icacls` 授 modify 给专用用户 |
| 日志 | `C:\ProgramData\TiaOpenness\logs\` | 普通文件 |

风险面：任何能读到 `config.json` 的人都能以该身份运行 Openness 工具。
它只有 `Siemens TIA Openness` 组成员身份（+ Users），不具管理员权限；
需要撤销时按 README 的"卸载"步骤删用户/删目录/删白名单项即可。

---

## 六、版本适配

- `Siemens.Engineering.dll` 的路径从注册表
  `HKLM\SOFTWARE\Siemens\Automation\Openness\<ver>\PublicAPI\<ver>\Siemens.Engineering` 读取；
- `setup.ps1` 自动枚举已安装版本并取**最高**的一个（多版本共存时优先新版本）；
- 白名单版本键按探测到的版本号展开（`20.0`、`19.0`…），不会误写到别的版本；
- 如果机器上装了多个版本而你想用旧版本，手动把 `config.json` 的 `tiaVersion`/`dll` 改成旧版本，
  然后重跑 `whitelist.ps1 -Exe <exe>`（exe 不变时白名单无需重写，只是版本键不同）。
