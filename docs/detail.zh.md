# 博途 PLC 接入（TIA Openness）

安装这个插件后，DSH 里会多一个 `tia-openness` skill 和一个只读诊断工具
`tia_openness_status`。前者让 agent 能通过西门子 Openness API 直接读写本机的
博途工程，不打开 TIA 界面；后者先回答"这台机器现在能不能跑、下一步执行什么命令"。

## 它做了什么

- **注册 skill**：把包内 `tia-openness/`（`SKILL.md` + `references/` + `scripts/`）
  作为运行时 skill 注册给 agent，并声明资源根目录就是该文件夹——所以 `SKILL.md`
  里写的 `scripts\setup.ps1`、`references\troubleshooting.md` 这类相对路径，在包装到
  任何位置之后都能解析。
- **注册一个只读工具**：`tia_openness_status`（无参数）。它只读路径和环境变量，
  不起进程、不改文件，返回：skill 目录、四个脚本是否齐全、数据目录
  `C:\ProgramData\TiaOpenness` 是否存在、`bin\TiaOpen.exe` 是否已编译、
  `config.json` 是否已生成、本机装了哪些 `Portal V*`、以及 `nextStep`（下一步该执行
  的确切命令）。
- 两件事都不碰 PLC 工程本身：真正干活的是 skill 的 PowerShell 脚本，由 agent 作为
  可见动作调用。

## 前置条件

1. Windows。
2. 博途 **TIA Portal V15.1–V20**（装的时候勾选 Openness 组件），目标 CPU 为
   S7-1200 / S7-1500。
3. 对 `C:\ProgramData\TiaOpenness` 与 `HKLM\SOFTWARE\Siemens\Automation\Openness`
   有管理员权限（一次性配置要用）。
4. Node.js ≥ 22（宿主自带，普通用户无需单独安装）。

## 一次性配置

插件装好后，先让 agent 调一次 `tia_openness_status`。如果 `nextStep` 显示未配置，
在**管理员** PowerShell 里执行（脚本会自己提权）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<插件安装位置>\tia-openness\scripts\setup.ps1"
```

`setup.ps1` 会做三件事：创建专用本地用户（默认 `TiaOpenness`）、用 .NET 编译器把
`scripts\tools\TiaOpen.cs` 编译成 `C:\ProgramData\TiaOpenness\bin\TiaOpen.exe`、
把该 exe 的 **SHA-256 + 修改时间**写进 Openness 防火墙白名单，并生成
`C:\ProgramData\TiaOpenness\config.json`（含该用户口令）。

> 改过 `TiaOpen.cs` 之后必须重跑 `setup.ps1`——白名单绑的是 exe 的哈希，
> 重新编译出来的 exe 不重写白名单会被 Openness 拒绝启动。

## 日常用法

skill 里的固定套路（细节见 `tia-openness/SKILL.md`）：

1. `scripts\stage-project.ps1 -Project "<.ap1x 路径>"` —— 复制一份工程副本到
   `C:\ProgramData\TiaOpenness\work\` 并授权给专用用户（原工程不动）。
2. 写一个 job 文件，交给 `scripts\run.ps1 -Job <file> -DataDir <dataDir>` 执行。
3. job 里可以做的动作：`info`（工程与块清单）、`dump`、`export`（块 XML 与变量表
   XML）、`import`（块 XML 与 V15.1+ 的变量表 XML）、`compile`（编译核验）、
   `saveas`、`selfcheck`。
4. 退出码：`0` 成功 / `2` 用法错误 / `3` 工具失败（含 import/compile 有错误）/
   `4` 超时 / `5` 未提权 / `6` 启动失败。工具日志在
   `C:\ProgramData\TiaOpenness\logs\<tag>.log`。

## 能做什么，不能做什么

能：列工程/设备/块分组；导出块为 SCL 或 LAD 的 XML；改 SCL 源码与接口；导入块；
新建 DB 与其成员；导入/导出 PLC 变量表（V15.1+）；编译并读取逐条错误/警告；另存工程。
调用系统指令（如 `MC_Power`）不需要额外文件，按名字解析。

不能：下载到 PLC、在线监视/强制、HMI/WinCC、硬件组态与报文选择、创建工艺对象
（TO）、从全局库拖入库块（`SINA_POS`、`FB_PN352` 等）、删除块。这几类仍需在
TIA 界面里做一次，之后由工具接管迭代。

## 安全模型

- 每次动作都以专用用户身份**全新登录**启动一次 `TiaOpen.exe`，跑完即退出；
  不常驻、不开端口。
- 交互的是 `work\` 下的**工程副本**，原工程不被修改。
- Openness 白名单按 exe 的 SHA-256 + 修改时间校验，换 exe 必须重跑 `setup.ps1`。
- 口令保存在 `C:\ProgramData\TiaOpenness\config.json`，插件本身不读取、不传输它。

## 验证状态

- 包内 `node --test test/smoke.mjs` 全绿；`tia_openness_status` 在真实机器上返回正确结果
  （能识别装在非 `C:\Program Files` 盘符下的博途，并能发现"exe 比随包源码旧"）。
- `TiaOpen.cs` 整文件 `csc` 编译 0 个语法错误（只缺 Siemens 类型），新增方法体做过桩编译。
- **块的 dump / export / import / compile 已在真实 TIA Portal V20 工程上跑通**；
  本次新增的**变量表导入**只在代码层面验证过，还没有在真实工程上走过一轮往返。

因此首次在目标机器上使用时，建议先 `export` 一次变量表 → 原样 `import` → `compile`，
确认这三步都过、且 `IMPORT TOTAL imported = N errors = 0`，再开始改程序。
另外：改过 `TiaOpen.cs` 之后 `tia_openness_status` 会提示 `exe matches shipped source: no`，
此时必须重跑 `setup.ps1`（重编译 + 重写白名单）。

## 卸载

从 DSH 卸载插件即可；skill 与工具随之消失。如需彻底清理，手动删除
`C:\ProgramData\TiaOpenness`、`setup.ps1` 创建的本地用户，以及注册表里对应的
Openness 白名单项（`HKLM\SOFTWARE\Siemens\Automation\Openness\<版本>\Whitelist\TiaOpen.exe`）。
