# 改码 playbook：从"看懂了"到"改完能编译"

本文把所有改动步骤写成可复制的配方。核心口诀：
**先复制 → 再 dump/export → 只改 XML 里最小的一处 → import 覆盖 → compile 必须 Success → save → 备份回拷。**

---

## 一、导出 XML 的结构地图

```
<Document>
  <Engineering version="V20" />
  <DocumentInfo>…</DocumentInfo>
  <SW.Blocks.FB ID="0">              ← OB / FB / FC / DB 各一种标签
    <AttributeList>
      <Interface><Sections>…</Sections></Interface>   ← 块接口（Input/Output/InOut/Static/Temp/Constant）
      <MemoryLayout>Optimized</MemoryLayout>
      <Name>测速</Name>
      <Number>8</Number>
      <ProgrammingLanguage>SCL</ProgrammingLanguage>   ← LAD / SCL / STL / DB
    </AttributeList>
    <ObjectList>
      <MultilingualText ID="1" CompositionName="Comment">…</MultilingualText>   ← 块注释
      <SW.Blocks.CompileUnit ID="3" CompositionName="CompileUnits">           ← 一个"网络"
        <AttributeList>
          <NetworkSource><StructuredText xmlns="…/StructuredText/v4">
            …token 流…
          </StructuredText></NetworkSource>
        </AttributeList>
      </SW.Blocks.CompileUnit>
    </ObjectList>
  </SW.Blocks.FB>
</Document>
```

- 全局 DB 是 `SW.Blocks.GlobalDB`，其接口 `Section` 里每个 `<Member Name Datatype [StartValue] />`；
- 实例 DB（`FB_Logic_DB` 等）通常由编译自动生成，**不要手改**；
- LAD 块的网络体是 `FlgNet`（`Part` / `Instruction` / `Wire` / `NameCon`），结构复杂；
- `ID` / `UId` 只要在文件内唯一即可，新加的编号取"当前最大 + 1"。

---

## 二、SCL 的 token 语法（改代码必须懂这个）

SCL 源码在 XML 里**不是一段文本，而是 token 序列**。常用节点：

| 节点 | 含义 | 例 |
|---|---|---|
| `<Access Scope="…">` | 一个"取值表达式" | 变量、常量、函数调用 |
| `<Access Scope="LocalVariable">` | 块内变量（`#x`、`#x.y`） | `<Symbol><Component Name="mm_PerCycle"/></Symbol>` |
| `<Access Scope="GlobalVariable">` | 全局变量（`"DB".x`、`"Tag"`） | 带引号的名字加 `<BooleanAttribute Name="HasQuotes">true</BooleanAttribute>` |
| `<Access Scope="LiteralConstant">` | 字面量 | `<Constant><ConstantValue>0.0378</ConstantValue></Constant>` |
| `<Access Scope="Call">` | 调用 FB/FC | 见下 |
| `<Component Name="…"/>` | 访问路径中的一段（`a.b.c` 三段） | |
| `<Token Text="…"/>` | 运算符/标点/关键字 | `:=` `+` `*` `<` `(` `)` `;` `THEN` `:=` |
| `<Blank [Num="n"]/>` | 空格（`Num` 表示连续空格数） | |
| `<NewLine/>` | 换行 | |
| `<LineComment><Text>…</Text></LineComment>` | `//` 注释（**可以是多行整段文本**） | |
| `<Access Scope="Call"><CallInfo BlockType="FB" Name="FB_Logic">…` | 调用 | 见下 |

调用示例（`10ms` 里调用 FB_Logic，带实例 DB 与命名参数）：

```xml
<Access Scope="Call" UId="133">
  <CallInfo UId="134" BlockType="FB" Name="FB_Logic">
    <Instance Scope="GlobalVariable" UId="135">
      <Component Name="FB_Logic_DB" UId="136">
        <BooleanAttribute Name="HasQuotes" UId="137">true</BooleanAttribute>
      </Component>
    </Instance>
    <Token Text="(" UId="138" />
    <Parameter Name="Run" UId="139"> …表达式… </Parameter>
    …
  </CallInfo>
</Access>
```

**规律**：空白被显式记录（`Blank`/`NewLine`），所以"排版"是数据的一部分；
表达式里的每个操作数都是 `Access`，中间用 `Token Text="运算符"` 串起来。
写代码就是拼这些节点——不需要缩进对齐，TIA 会重新排版。

---

## 三、五个可直接照抄的改法

### 1) 改一个字面量（最安全）

```xml
<!-- 前 -->
<Access Scope="LiteralConstant" UId="37"><Constant UId="38"><ConstantValue UId="39">0.0378</ConstantValue></Constant></Access>
<!-- 后：只改数字 -->
…<ConstantValue UId="39">0.06</ConstantValue>…
```

### 2) 改一个运算符/关键字

```xml
<Token Text="*" UId="42" />   →   <Token Text="/" UId="42" />
```

### 3) 改变量名（`Component`）

```xml
<Component Name="Speed" UId="33" />  →  <Component Name="Velocity" UId="33" />
```
> 全局变量改名后还要能对上变量表；块内变量要同时改 `<Interface>` 里的 `Member`。
> **改接口会让块的所有调用点报错**，除非同步改调用参数——所以优先"改值/改逻辑"而不是"改接口"。

### 4) 追加一行新逻辑（新网络）

在 `<ObjectList>` 里追加一个 `CompileUnit`（`ID` 取现有最大值 +1，`UId` 取全文件最大 +100 起步）：

```xml
<SW.Blocks.CompileUnit ID="500" CompositionName="CompileUnits">
  <AttributeList>
    <NetworkSource><StructuredText xmlns="http://www.siemens.com/automation/Openness/SW/NetworkSource/StructuredText/v4">
      <Access Scope="GlobalVariable" UId="501"><Symbol UId="502">
        <Component Name="Auto" UId="503"><BooleanAttribute Name="HasQuotes" UId="504">true</BooleanAttribute></Component>
        <Token Text="." UId="505" /><Component Name="Start" UId="506" />
      </Symbol></Access>
      <Blank UId="507" /><Token Text=":=" UId="508" /><Blank UId="509" />
      <Access Scope="LiteralConstant" UId="510"><Constant UId="511"><ConstantValue UId="512">0</ConstantValue></Constant></Access>
      <Token Text=";" UId="513" /><NewLine UId="514" />
    </StructuredText></NetworkSource>
  </AttributeList>
</SW.Blocks.CompileUnit>
```
（等价于 SCL：`"Auto".Start := 0;`）

### 5) 把注释掉的旧代码"复活"

导出里常见这种（整段旧算法被塞进一个 `LineComment`）：

```xml
<LineComment Inserted="true" UId="25"><Text UId="26"> IF #上次位置 = 0 THEN … END_IF; </Text></LineComment>
```

做法：把该 `LineComment` 替换成对应 token 序列（手工拼，或参考同文件其它 `Access`）。
**不建议**在有大量注释块的块上做大规模重写——先 `export` 备份，改坏了可直接 `import` 回原文件。

---

## 四、改 LAD / FBD

`FlgNet` 里是图形网络：`<Part Name="Contact" UId="…">`、`<Wire UId="…"><Powerrail/><NameCon UId="…" Name="in"/></Wire>`。
改一个触点/线圈的变量还算可控（改 `Access` 里的 `Component`），**增删分支、改串并联极易搞坏网络**。
建议：

- 小改（改触点变量、改比较值）→ 直接改 XML；
- 大改 → 不要动 LAD，把新逻辑写成 **新的 SCL 块**（或 SE 块），从 OB/FB 里调用；
- 无论哪种，最后都必须 `compile` 通过。

---

## 五、新增块 / 删除块

- **新增**：复制一个同类块的 XML（同 `ProgrammingLanguage`），改 `<Name>`（唯一）与 `<Number>`（唯一，且不与系统块冲突），
  把 `ID`/`UId` 全部改成本文件内不重复的值，删掉不需要的 `CompileUnit` 或替换 `NetworkSource`，
  再 `import … overwrite:yes`。被调用的块才会进编译；孤立的新块也会被编译。
- **删除**：当前工具没有删除模式。要删块请在 TIA GUI 里删，或用"新建空工程 + 导入需要的块"的方式重建。
- **改块号**：改 `<Number>` 即可（调用关系按名字，不按块号），但 OB 的块号与调用事件绑定，别乱改。

---

## 六、DB 与变量表

- 全局 DB 的初值：`<Section Name="Static"><Member Name="x" Datatype="DInt" StartValue="5" />`；
  改 `StartValue` 不改变运行中的当前值（下载后才生效），也别改 `Datatype`。
- 变量表导出为 `<Document><SW.Tags.PlcTagTable>`；改地址/名称后 `import` 同名覆盖。
- 变量名改动会连带影响所有引用该变量的代码——**先用 `export` 出来的 XML 做全文 grep 确认引用面**（见下）。

---

## 七、核验（每一步都要做）

1. `import` 后看 `errors = 0`；
2. `compile` 必须 `State = Success`、`ErrorCount = 0`；`WarningCount` 要复核（常见"变量未使用"可接受，接口/类型警告必须看）；
3. **再 `export` 一次改后的块，与原 XML 做 diff**——这是"我到底改了什么"的唯一可信证据；
4. 结构性检查（人看）：改动是否影响 HMI 地址、是否改到安全/驱动通信块（`SINA_POS_V90`、`FB_PN352` 这类）、
   时间常数是否带单位换算、除法是否可能除零、沿触发是否依赖扫描周期；
5. 落盘 `save:yes` 后复跑一次 `compile`（确认保存后的状态一致）。

### 全文检索（离线静态分析的主力）

```powershell
$out = "C:\ProgramData\TiaOpenness\out\exp1\G2_PLC_1\blocks"
Select-String -Path "$out\*.xml" -Pattern "FB_Logic|速度测量|0\.0378" -Encoding UTF8 |
  Select-Object Filename,LineNumber,Line | Format-List
```
注意：XRef（跨引用）需要 GUI，离线只能用名字 grep 近似。

---

## 八、交付回用户

1. 先把用户原工程整个文件夹**复制一份备份**（带日期后缀，别覆盖）；
2. 把暂存区 `C:\ProgramData\TiaOpenness\work\<工程>\` 里改好的文件夹复制回用户目录；
3. 告诉用户：在 TIA 里重新打开工程（若已打开需先关闭，否则文件锁），检查后编译下载；
4. 本工具**不做下载到 PLC**（需要 TIA 的下载对话框/硬件连接），下载由用户在 GUI 完成。

---

## 九、常见改码任务的最小闭环（示例）

| 用户要求 | 最小步骤 |
|---|---|
| "把某段算法改成 X" | stage → export 该块 → 改 token → import overwrite → compile → save → 回拷 |
| "这个块为什么报警/不动作" | stage → dump + export → 读 XML / grep 变量 → 报告，不动工程 |
| "检查整个工程有没有隐患" | stage → export 全部 → 静态扫描（除零、未初始化、时间常数、DB 冲突）→ 报告 |
| "加一个手动/自动切换" | stage → 新增 SCL FC 或 FB → import → 在调用点加 `Call`（LAD 里加 `Part Name="Call"`，风险高）→ compile |
| "改一个参数初值" | stage → export 该 DB → 改 `StartValue` → import → compile → save |

最后一条建议：**任何一次交付都要有"改动前/改动后"两份 export 目录**，
两者 diff 就是给用户的变更说明。
