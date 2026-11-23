# tia-openness-skill

一个 **DeepSeek Harness（DSH）skill**：让 AI agent 通过西门子官方 **TIA Portal Openness API** 直接读写本机博途工程——不点鼠标、不开界面，就能枚举工程、导出/导入 PLC 块与变量表、改逻辑、**编译核验**并保存。

适用：TIA Portal **V15.1 – V20**，**S7-1200 / S7-1500**（S7-300/400 不支持 Openness）。

## 仓库结构

```
tia-openness/               ← skill 本体（文件夹名即 skill 名，勿改）
├── SKILL.md                ← agent 读取的入口说明
├── README.md               ← 完整安装 / 用法 / FAQ
├── references/
│   ├── security-model.md   ← 安全模型（专用用户、防火墙白名单、注册表布局）
│   ├── troubleshooting.md  ← 踩坑与根因
│   └── workflow-playbook.md← 改码与编译核验配方
└── scripts/
    ├── setup.ps1           ← 首次安装：编译 TiaOpen.exe + 建用户 + 写白名单
    ├── install-skill.ps1   ← 装进 DSH（%USERPROFILE%\.dsh\skills\tia-openness）
    ├── run.ps1             ← 执行一次 job（info/dump/export/import/compile/...）
    ├── stage-project.ps1   ← 把工程复制到受控工作目录，避免抢锁
    ├── whitelist.ps1       ← 单独刷新 Openness 白名单
    └── tools/TiaOpen.cs    ← x64 命令行工具源码（setup.ps1 用 csc.exe 编译）
```

## 快速开始

```powershell
# 1) 本机一次性安装（需要管理员；检测 TIA 版本并编译工具）
powershell -NoProfile -ExecutionPolicy Bypass -File .\tia-openness\scripts\setup.ps1

# 2) 注册到 DSH
powershell -NoProfile -ExecutionPolicy Bypass -File .\tia-openness\scripts\install-skill.ps1
```

装好后在 DSH 会话里提到「博途 / TIA / PLC 程序」，agent 即按本 skill 的流程操作。
安装日志：`$env:USERPROFILE\AppData\Local\Temp\tia-openness-setup.log`。

## 设计要点

- **专用本地用户**（默认 `TiaOpenness`）承担 Openness 调用；你自己的账户**不需要**加 `Siemens TIA Openness` 组，也不用注销重登。
- 每个动作都以该用户身份、全新交互式登录启动 `TiaOpen.exe`，只操作**工程副本**，全程不碰你正在用的 TIA 界面。
- 工具以 **SHA-256 + 修改时间**登记进 Openness 防火墙白名单；改了 `TiaOpen.cs` 必须重跑 `setup.ps1`。
- 无外联需求，全部在本机完成。

详细说明见 [tia-openness/README.md](tia-openness/README.md)。

## 许可

本工具调用西门子 Openness 公共 API，受《Siemens Openness 许可条款》（随 TIA Portal 安装）约束。
仓库内的 PowerShell 脚本与 `TiaOpen.cs` 为自研代码，可自由修改。
