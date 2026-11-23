/**
 * dsh-tia-openness — host half of the TIA Portal Openness plugin.
 *
 * What this file does
 * -------------------
 * Two registrations, both from the payload that ships next to it:
 *
 *   1. the `tia-openness` skill (`./tia-openness/SKILL.md` plus its
 *      `references/` and `scripts/`), registered as a runtime skill whose
 *      resource base is that directory, so the relative paths written in
 *      SKILL.md keep resolving after the package is installed anywhere;
 *   2. one read-only tool, `tia_openness_status`, which answers the question an
 *      agent asks before it starts: is this machine even able to run the skill
 *      (TIA Portal present? one-time setup done? what is the next command?).
 *
 * Why a skill and not a service
 * -----------------------------
 * The PLC work is done by `scripts\run.ps1`, which starts a whitelisted x64
 * tool as a dedicated local user — a privileged, GUI-less, minutes-long job.
 * Modelling that as a host service would put a PowerShell spawn inside DSH's
 * boot; modelling it as a skill keeps it where it belongs: an agent action the
 * user can see, approve and interrupt. The tool below only reads paths.
 *
 * Disciplines
 * -----------
 *   * `apply()` never throws — a synchronous throw fails this loader entry's
 *     fiber and the boot audit reports "Failed to load plugins".
 *   * only `node:*` builtins: a third-party DSH plugin cannot import
 *     `@deepseek-ai/*`, everything official lives inside app.asar.
 *   * no log noise. Nothing is printed when the plugin is healthy.
 */
import { execFileSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const PACKAGE_ID = "dsh-tia-openness";
const SKILL_NAME = "tia-openness";
const STATUS_TOOL_NAME = "tia_openness_status";

/** Where the skill payload ships. `new URL(".", ...)` keeps the trailing slash. */
const packageRoot = fileURLToPath(new URL(".", import.meta.url));
const skillDir = join(packageRoot, SKILL_NAME);
const skillFile = join(skillDir, "SKILL.md");

/**
 * The skill's scripts default `-DataDir` to C:\ProgramData\TiaOpenness. Keep
 * that default so a plugin install and a plain `install-skill.ps1` install
 * share one toolchain instead of building the exe twice.
 */
const DEFAULT_DATA_DIR = "C:\\ProgramData\\TiaOpenness";

const FALLBACK_DESCRIPTION =
  "通过 TIA Portal Openness API 免 GUI 读写本机博途工程（V15.1–V20，S7-1200/1500）：列出工程与块、导出/编辑/导入块 XML、编译核验并保存。";

const FALLBACK_WHEN_TO_USE =
  "用户提到博途/TIA Portal/S7-1200/S7-1500/.ap1x 工程，要求读取、分析、修改、编译核验或交付 PLC 程序时。首次使用须先跑 scripts\\setup.ps1。";

/** `--` separated frontmatter of SKILL.md, only the scalars we need. */
function parseFrontmatter(text) {
  const match = /^---\r?\n([\s\S]*?)\r?\n---/.exec(text);
  if (match === null) return {};

  const values = {};
  const lines = match[1].split(/\r?\n/);
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    const entry = /^([A-Za-z0-9_-]+):[ \t]*(.*)$/.exec(line);
    if (entry === null) continue;

    const key = entry[1];
    const inline = entry[2].trim();
    if (inline !== "" && inline !== "|" && inline !== ">") {
      values[key] = inline.replace(/^(['"])([\s\S]*)\1$/, "$2").trim();
      continue;
    }

    // Block scalar: every following line that is blank or indented belongs to it.
    const block = [];
    for (index += 1; index < lines.length; index += 1) {
      const inner = lines[index];
      if (inner.trim() !== "" && !/^[ \t]/.test(inner)) {
        index -= 1;
        break;
      }
      block.push(inner.trim());
    }
    values[key] = block.join(inline === "|" ? "\n" : " ").trim();
  }
  return values;
}

function readSkill() {
  if (!existsSync(skillFile)) {
    throw new Error(`skill payload missing: ${skillFile}`);
  }
  const content = readFileSync(skillFile, "utf8");
  const meta = parseFrontmatter(content);
  return {
    content,
    description: typeof meta.description === "string" && meta.description !== "" ? meta.description : FALLBACK_DESCRIPTION,
    whenToUse: typeof meta.whenToUse === "string" && meta.whenToUse !== "" ? meta.whenToUse : FALLBACK_WHEN_TO_USE,
    name: typeof meta.name === "string" && meta.name !== "" ? meta.name : SKILL_NAME,
  };
}

function dataDir() {
  const fromEnvironment = String(process.env.DSH_TIA_OPENNESS_DATA ?? "").trim();
  return fromEnvironment === "" ? DEFAULT_DATA_DIR : fromEnvironment;
}

/** File size in bytes, or null when the file is missing or unreadable. */
function fileSize(path) {
  try {
    return statSync(path).size;
  } catch {
    return null;
  }
}

function dshHome() {
  const fromEnvironment = String(process.env.DSH_HOME ?? "").trim();
  return fromEnvironment === "" ? join(homedir(), ".dsh") : fromEnvironment;
}

/**
 * Installed TIA Portal Openness versions.
 *
 * The registry is the authoritative source: `scripts\setup.ps1` discovers a
 * version the same way (`HKLM\SOFTWARE\Siemens\Automation\Openness\<major>.<minor>\
 * PublicAPI\<assembly version>` with the assembly path in the value named
 * `Siemens.Engineering`), and TIA is routinely installed outside Program Files —
 * it can live on another drive entirely. A Program Files scan is kept only as a
 * fallback for hosts where `reg` cannot run.
 *
 * Never throws; an empty result means "nothing detected", not "broken".
 */
function tiaPortalVersions() {
  const versions = new Set();
  const assemblies = new Set();

  const hives = [
    "HKLM\\SOFTWARE\\Siemens\\Automation\\Openness",
    "HKLM\\SOFTWARE\\WOW6432Node\\Siemens\\Automation\\Openness",
  ];
  for (const hive of hives) {
    let output = "";
    try {
      output = execFileSync("reg", ["query", hive, "/s", "/v", "Siemens.Engineering"], {
        encoding: "utf8",
        timeout: 5000,
        windowsHide: true,
        stdio: ["ignore", "pipe", "ignore"],
      });
    } catch {
      continue;
    }
    for (const line of output.split(/\r?\n/)) {
      const value = /REG_SZ\s+(.+?Siemens\.Engineering\.dll)\s*$/i.exec(line.trim());
      if (value === null) continue;
      assemblies.add(value[1]);
    }
  }

  // Versions come from the key path shape, so read them back from the same hive
  // without depending on each value's presence.
  for (const hive of hives) {
    let output = "";
    try {
      output = execFileSync("reg", ["query", hive], { encoding: "utf8", timeout: 5000, windowsHide: true, stdio: ["ignore", "pipe", "ignore"] });
    } catch {
      continue;
    }
    for (const line of output.split(/\r?\n/)) {
      const key = /\\Openness\\(\d+\.\d+)\s*$/i.exec(line.trim());
      if (key !== null) versions.add(key[1]);
    }
  }

  return { versions: [...versions].sort(), assemblies: [...assemblies] };
}

/** Last-resort directory scan, used only when the registry yielded nothing. */
function tiaPortalRoots() {
  const found = [];
  for (const root of ["C:\\Program Files\\Siemens\\Automation", "C:\\Program Files (x86)\\Siemens\\Automation"]) {
    if (!existsSync(root)) continue;
    let entries = [];
    try {
      entries = readdirSync(root, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of entries) {
      if (entry.isDirectory() && /^Portal\s+V/i.test(entry.name)) found.push(join(root, entry.name));
    }
  }
  return found;
}

/** Read-only probe behind the status tool. Never throws. */
function probe(skill) {
  const state = {
    summary: "",
    plugin: PACKAGE_ID,
    skill: skill.name,
    skillRegistered: true,
    skillDirectory: skillDir,
    skillFileFound: existsSync(skillFile),
    skillScripts: ["setup.ps1", "run.ps1", "stage-project.ps1", "whitelist.ps1"].filter((name) =>
      existsSync(join(skillDir, "scripts", name)),
    ),
    dataDirectory: dataDir(),
    dataDirectoryExists: existsSync(dataDir()),
    toolBuilt: existsSync(join(dataDir(), "TiaOpen.exe")),
    configWritten: existsSync(join(dataDir(), "config.json")),
    toolchainStale: false,
    tiaPortalInstalled: false,
    tiaPortalVersions: [],
    tiaOpennessAssemblies: [],
    tiaPortalRoots: [],
    dshHome: dshHome(),
    nextStep: "",
  };

  try {
    const openness = tiaPortalVersions();
    state.tiaPortalVersions = openness.versions;
    state.tiaOpennessAssemblies = openness.assemblies;
    state.tiaPortalInstalled = openness.versions.length > 0 || openness.assemblies.length > 0;
    if (!state.tiaPortalInstalled) {
      state.tiaPortalRoots = tiaPortalRoots();
      state.tiaPortalInstalled = state.tiaPortalRoots.length > 0;
    }
  } catch {
    /* unknown is reported as not installed */
  }

  const setupCommand = `powershell -NoProfile -ExecutionPolicy Bypass -File "${join(skillDir, "scripts", "setup.ps1")}"`;
  const ready = state.toolBuilt && state.configWritten;

  // setup.ps1 stages a copy of TiaOpen.cs next to the exe, so the two sizes say
  // whether the installed exe predates the source that shipped with this package.
  // A stale exe also means a stale whitelist entry, which Openness rejects.
  const stagedSourceBytes = fileSize(join(dataDir(), "TiaOpen.cs"));
  const packagedSourceBytes = fileSize(join(skillDir, "scripts", "tools", "TiaOpen.cs"));
  state.toolchainStale =
    state.toolBuilt &&
    stagedSourceBytes !== null &&
    packagedSourceBytes !== null &&
    stagedSourceBytes !== packagedSourceBytes;
  state.stagedSourceBytes = stagedSourceBytes;
  state.packagedSourceBytes = packagedSourceBytes;
  const tiaDescription =
    state.tiaPortalVersions.length > 0
      ? `${state.tiaPortalVersions.join(", ")}${
          state.tiaOpennessAssemblies.length > 0 ? ` (${state.tiaOpennessAssemblies[0]})` : ""
        }`
      : state.tiaPortalRoots.length > 0
        ? state.tiaPortalRoots.join("; ")
        : "not detected";

  if (!state.tiaPortalInstalled) {
    state.nextStep =
      "No TIA Portal Openness installation was found under " +
      "HKLM\\SOFTWARE\\Siemens\\Automation\\Openness, so the skill cannot run here yet. " +
      "Install TIA Portal (V15.1-V20) with the Openness option on the target machine, then re-run this probe.";
  } else if (!ready) {
    state.nextStep =
      "TIA Portal is present but the one-time setup has not run (or the exe was rebuilt after an edit of TiaOpen.cs). " +
      `Run this once, elevated (it relaunches itself and writes the Openness whitelist): ${setupCommand}`;
  } else if (state.toolchainStale) {
    state.nextStep =
      `The installed TiaOpen.exe predates the TiaOpen.cs shipped with this package (staged ${state.stagedSourceBytes} bytes ` +
      `vs packaged ${state.packagedSourceBytes}), so it is missing the newer modes and its whitelist entry is stale. ` +
      `Re-run the one-time setup, elevated: ${setupCommand}`;
  } else {
    state.nextStep =
      "Toolchain is ready. Stage the project with scripts\\stage-project.ps1, write a job file and run " +
      "scripts\\run.ps1 -Job <file> -DataDir <dataDir> as described in SKILL.md.";
  }

  const lines = [
    `plugin: ${state.plugin} (skill "${state.skill}" registered)`,
    `skill directory: ${state.skillDirectory}`,
    `scripts present: ${state.skillScripts.length === 0 ? "none" : state.skillScripts.join(", ")}`,
    `data directory: ${state.dataDirectory}${state.dataDirectoryExists ? "" : " (not created yet)"}`,
    `TiaOpen.exe built: ${state.toolBuilt ? "yes" : "no"}`,
    `exe matches shipped source: ${state.toolchainStale ? "no (rebuild needed)" : "yes"}`,
    `config.json written: ${state.configWritten ? "yes" : "no"}`,
    `TIA Portal Openness: ${tiaDescription}`,
    "",
    `next step: ${state.nextStep}`,
  ];
  state.summary = lines.join("\n");
  return state;
}

/** Register the one payload that matters: the skill itself. */
function registerSkill(ctx, skill) {
  const register = (scope) => {
    const skills = scope?.skills;
    if (skills === null || skills === undefined || typeof skills.register !== "function") return;
    skills.register({
      name: skill.name,
      description: skill.description,
      whenToUse: skill.whenToUse,
      content: skill.content,
      source: "custom",
      invocation: { modelInvocable: true, userInvocable: true },
      // Relative paths in SKILL.md (references\, scripts\) resolve against this.
      resourceBase: { kind: "directory", path: skillDir },
    });
  };

  if (typeof ctx?.inject === "function") {
    ctx.inject(["skills"], register);
    return;
  }
  register(ctx);
}

function registerStatusTool(ctx, skill) {
  const register = (scope) => {
    const tools = scope?.tools;
    if (tools === null || tools === undefined || typeof tools.register !== "function") return;
    tools.register({
      name: STATUS_TOOL_NAME,
      description:
        "Diagnose the tia-openness skill bundled by dsh-tia-openness: where the skill payload and its scripts live, " +
        "whether the one-time Openness setup (TiaOpen.exe + config.json in C:\\ProgramData\\TiaOpenness) has been built " +
        "on this machine, whether any TIA Portal (V15.1-V20) is installed, and the exact next command to run. " +
        "Call it before starting PLC work, or when the skill's scripts fail to start.",
      parameters: {
        type: "object",
        properties: {},
        additionalProperties: false,
      },
      output: {
        schema: {
          type: "object",
          additionalProperties: true,
          properties: {
            summary: { type: "string" },
            plugin: { type: "string" },
            skill: { type: "string" },
            skillDirectory: { type: "string" },
            dataDirectory: { type: "string" },
            tiaPortalInstalled: { type: "boolean" },
            tiaPortalVersions: { type: "array", items: { type: "string" } },
            tiaOpennessAssemblies: { type: "array", items: { type: "string" } },
            toolBuilt: { type: "boolean" },
            toolchainStale: { type: "boolean" },
            configWritten: { type: "boolean" },
            nextStep: { type: "string" },
          },
          required: ["summary", "nextStep"],
        },
        render(_args, value) {
          const text = typeof value?.summary === "string" && value.summary !== "" ? value.summary : "no diagnosis available";
          return [{ type: "text", text }];
        },
      },
      execute() {
        try {
          return probe(skill);
        } catch (error) {
          return {
            summary: `probe failed: ${error instanceof Error ? error.message : String(error)}`,
            nextStep: "The plugin could not read its own paths; reinstall the bundle.",
          };
        }
      },
    });
  };

  if (typeof ctx?.inject === "function") {
    ctx.inject(["tools"], register);
    return;
  }
  register(ctx);
}

export function apply(ctx) {
  try {
    const skill = readSkill();
    registerSkill(ctx, skill);
    registerStatusTool(ctx, skill);
  } catch {
    /* apply() must not throw, whatever happens */
  }
}

export default { name: PACKAGE_ID, apply };
