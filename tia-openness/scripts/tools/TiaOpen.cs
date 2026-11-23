// TiaOpen.cs - TIA Portal Openness helper (C# 5 compatible, x64)
// Usage: TiaOpen.exe <logPath> <mode> [args...]
//   info                              print identity, versions, running instances
//   dump     <projectPath>            open project (no UI), dump devices/blocks/tags, close
//   export   <projectPath> <outDir> [filter]
//   import   <projectPath> <inDir> [save:yes|no] [overwrite:yes|no]
//            imports <inDir>\<software>\blocks\**\*.xml (blocks)
//            and     <inDir>\<software>\tags\**\*.xml   (tag tables, V15.1+)
//   compile  <projectPath> [save:yes|no]
//   saveas   <srcProject> <dstDirectory>
//   attach   <pid>                    attach to a running GUI instance and dump
//   selfcheck <projectPath>           open, dump, compile, close (no save)
using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Text;
using Siemens.Engineering;
using Siemens.Engineering.HW;
using Siemens.Engineering.HW.Features;
using Siemens.Engineering.SW;
using Siemens.Engineering.SW.Blocks;
using Siemens.Engineering.SW.Tags;

class TiaOpen
{
    static StreamWriter Lw;
    static string logPath = "tiaopen.log";

    static void L(string s)
    {
        string line = DateTime.Now.ToString("HH:mm:ss.fff") + " " + s;
        try { Console.WriteLine(line); } catch { }
        try { if (Lw != null) { Lw.WriteLine(line); Lw.Flush(); } } catch { }
    }

    static void LErr(string s)
    {
        L("ERR " + s);
    }

    static void LEx(Exception ex)
    {
        L("EXC " + ex.GetType().FullName + " | " + ex.Message);
        Exception inner = ex.InnerException;
        int depth = 0;
        while (inner != null && depth < 5)
        {
            L("  inner: " + inner.GetType().FullName + " | " + inner.Message);
            inner = inner.InnerException;
            depth++;
        }
    }

    static int Main(string[] a)
    {
        if (a.Length < 2)
        {
            Console.WriteLine("usage: TiaOpen.exe <logPath> <mode> [args...]");
            return 2;
        }
        logPath = a[0];
        try { Lw = new StreamWriter(logPath, false, new UTF8Encoding(false)); } catch { }
        string mode = a[1];
        L("== TiaOpen " + mode + " ==");
        L("identity = " + SafeIdentity());
        try { L("session  = " + System.Diagnostics.Process.GetCurrentProcess().SessionId); } catch { }
        try { L("userInteractive = " + Environment.UserInteractive); } catch { }
        try { L("log = " + logPath); } catch { }

        int rc = 0;
        try
        {
            switch (mode)
            {
                case "info": rc = CmdInfo(); break;
                case "dump": rc = CmdDump(a); break;
                case "export": rc = CmdExport(a); break;
                case "import": rc = CmdImport(a); break;
                case "compile": rc = CmdCompile(a); break;
                case "saveas": rc = CmdSaveAs(a); break;
                case "attach": rc = CmdAttach(a); break;
                case "selfcheck": rc = CmdSelfCheck(a); break;
                default: LErr("unknown mode " + mode); rc = 2; break;
            }
        }
        catch (Exception ex) { LEx(ex); rc = 3; }
        L("== done rc=" + rc + " ==");
        try { if (Lw != null) Lw.Close(); } catch { }
        return rc;
    }

    static string SafeIdentity()
    {
        try { return System.Security.Principal.WindowsIdentity.GetCurrent().Name; } catch { return "?"; }
    }

    // ---------- helpers ----------

    static TiaPortal NewInstance()
    {
        L("creating TiaPortal(WithoutUserInterface) ...");
        TiaPortal tia = new TiaPortal(TiaPortalMode.WithoutUserInterface);
        L("INSTANCE OK");
        return tia;
    }

    static Project OpenProject(TiaPortal tia, string path)
    {
        FileInfo fi = new FileInfo(path);
        if (!fi.Exists) throw new FileNotFoundException("project not found: " + path);
        L("opening project " + path);
        Project p = tia.Projects.Open(fi);
        L("OPEN OK name=" + p.Name);
        return p;
    }

    static List<PlcSoftware> FindPlcSoftware(Project p)
    {
        List<PlcSoftware> list = new List<PlcSoftware>();
        foreach (Device d in p.Devices)
        {
            foreach (DeviceItem item in d.DeviceItems)
            {
                try
                {
                    SoftwareContainer sc = item.GetService<SoftwareContainer>();
                    if (sc == null) continue;
                    PlcSoftware sw = sc.Software as PlcSoftware;
                    if (sw != null) list.Add(sw);
                }
                catch (Exception) { }
            }
        }
        return list;
    }

    static string RelPath(string root, string full)
    {
        if (string.IsNullOrEmpty(full) || full.Length <= root.Length) return ".";
        return full.Substring(root.Length).TrimStart('\\', '/');
    }

    static void DumpGroup(PlcBlockGroup g, string prefix, ref int total)
    {
        foreach (PlcBlock b in g.Blocks)
        {
            total++;
            string lang = "?";
            try { lang = b.ProgrammingLanguage.ToString(); } catch { }
            string num = "?";
            try { num = b.Number.ToString(); } catch { }
            L(prefix + "block " + b.Name + " | number=" + num + " | lang=" + lang);
        }
        foreach (PlcBlockUserGroup sub in g.Groups)
        {
            L(prefix + "[group] " + sub.Name);
            DumpGroup(sub, prefix + "  ", ref total);
        }
    }

    static void DumpTags(PlcSoftware sw)
    {
        try
        {
            foreach (PlcTagTable tt in sw.TagTableGroup.TagTables)
            {
                int n = 0;
                try { n = tt.Tags.Count; } catch { }
                L("  [tags] " + tt.Name + " | count=" + n);
            }
        }
        catch (Exception ex) { L("  tags ERR " + ex.Message); }
    }

    static void DumpProject(Project p)
    {
        L("PROJECT name=" + p.Name);
        try { L("  path = " + p.Path); } catch { }
        int devices = 0;
        try { devices = p.Devices.Count; } catch { }
        L("  devices = " + devices);
        foreach (Device d in p.Devices)
        {
            L("  DEVICE " + d.Name);
            try { L("    typeIdentifier = " + d.TypeIdentifier); } catch { }
            int idx = 0;
            foreach (DeviceItem item in d.DeviceItems)
            {
                idx++;
                string cls = "?";
                try { cls = item.Classification.ToString(); } catch { }
                L("    item[" + idx + "] " + item.Name + " (" + cls + ")");
                SoftwareContainer sc = null;
                try { sc = item.GetService<SoftwareContainer>(); } catch { }
                if (sc == null) continue;
                PlcSoftware sw = sc.Software as PlcSoftware;
                if (sw == null) { L("      Software: " + sc.Software.GetType().Name); continue; }
                L("      PlcSoftware: " + sw.Name);
                int total = 0;
                DumpGroup(sw.BlockGroup, "        ", ref total);
                L("      total blocks = " + total);
                DumpTags(sw);
            }
        }
    }

    static string SafeName(string s)
    {
        char[] bad = Path.GetInvalidFileNameChars();
        StringBuilder sb = new StringBuilder();
        foreach (char c in s) sb.Append(Array.IndexOf(bad, c) >= 0 ? '_' : c);
        return sb.ToString();
    }

    static void ExportGroup(PlcBlockGroup g, string rootDir, string rel, string filter, int[] stats)
    {
        string dir = rel.Length == 0 ? rootDir : Path.Combine(rootDir, rel);
        Directory.CreateDirectory(dir);
        foreach (PlcBlock b in g.Blocks)
        {
            try
            {
                string nameText = b.Name;
                if (filter.Length > 0 && nameText.IndexOf(filter, StringComparison.OrdinalIgnoreCase) < 0) continue;
                string file = Path.Combine(dir, SafeName(nameText) + ".xml");
                b.Export(new FileInfo(file), ExportOptions.None);
                stats[0]++;
                L("export block " + (rel.Length == 0 ? "" : rel + "/") + nameText + " -> " + file);
            }
            catch (Exception ex) { stats[1]++; L("export ERR " + b.Name + " | " + ex.Message); }
        }
        foreach (PlcBlockUserGroup sub in g.Groups)
        {
            ExportGroup(sub, rootDir, rel.Length == 0 ? sub.Name : Path.Combine(rel, sub.Name), filter, stats);
        }
    }

    static bool HasEnumName(Type t, string name)
    {
        try
        {
            foreach (string n in Enum.GetNames(t)) { if (n == name) return true; }
        }
        catch (Exception) { }
        return false;
    }

    static ImportOptions ImportMode(bool overwrite)
    {
        if (!overwrite) return ImportOptions.None;
        if (HasEnumName(typeof(ImportOptions), "Override"))
        {
            try { return (ImportOptions)Enum.Parse(typeof(ImportOptions), "Override"); } catch (Exception) { }
        }
        return ImportOptions.None;
    }

    static void ImportDir(PlcBlockGroup rootGroup, string dir, ImportOptions mode, int[] stats)
    {
        foreach (string file in Directory.GetFiles(dir, "*.xml"))
        {
            try
            {
                FileInfo fi = new FileInfo(file);
                rootGroup.Blocks.Import(fi, mode);
                stats[0]++;
                L("imported " + file);
            }
            catch (Exception ex) { stats[1]++; L("import ERR " + file + " | " + ex.Message); }
        }
        foreach (string sub in Directory.GetDirectories(dir))
        {
            string name = Path.GetFileName(sub);
            PlcBlockUserGroup g = null;
            foreach (PlcBlockUserGroup existing in rootGroup.Groups)
            {
                if (string.Equals(existing.Name, name, StringComparison.OrdinalIgnoreCase)) { g = existing; break; }
            }
            if (g == null)
            {
                try { g = rootGroup.Groups.Create(name); L("created group " + name); }
                catch (Exception ex) { L("group ERR " + name + " | " + ex.Message); continue; }
            }
            ImportDir(g, sub, mode, stats);
        }
    }

    // ---------- tag tables (export / import) ---------------------------------
    // Everything below is reflection based on purpose: the Tags API differs
    // between V15.1 and V20 (Import overloads, group composition types), and a
    // missing member must degrade to a clear log line instead of a crash.

    static object GetProp(object o, string name)
    {
        if (o == null) return null;
        try
        {
            PropertyInfo pi = o.GetType().GetProperty(name);
            return (pi == null) ? null : pi.GetValue(o, null);
        }
        catch { return null; }
    }

    static string NameOf(object o)
    {
        object n = GetProp(o, "Name");
        return (n == null) ? "" : Convert.ToString(n);
    }

    static string MsgOf(Exception ex)
    {
        if (ex is TargetInvocationException && ex.InnerException != null) ex = ex.InnerException;
        return ex.GetType().Name + ": " + ex.Message;
    }

    static MethodInfo FindFileImport(object composition)
    {
        if (composition == null) return null;
        foreach (MethodInfo mi in composition.GetType().GetMethods())
        {
            if (mi.Name != "Import") continue;
            ParameterInfo[] ps = mi.GetParameters();
            if (ps.Length >= 1 && ps[0].ParameterType == typeof(FileInfo)) return mi;
        }
        return null;
    }

    static void ExportTagDir(object group, string dir, int[] stats)
    {
        if (group == null) return;
        Directory.CreateDirectory(dir);
        IEnumerable tables = GetProp(group, "TagTables") as IEnumerable;
        if (tables != null)
        {
            foreach (object tt in tables)
            {
                string name = NameOf(tt);
                if (name.Length == 0) name = "tagtable";
                try
                {
                    MethodInfo exp = tt.GetType().GetMethod("Export",
                        new Type[] { typeof(FileInfo), typeof(ExportOptions) });
                    if (exp == null) { stats[1]++; L("tag export ERR " + name + " | no Export method"); continue; }
                    string file = Path.Combine(dir, SafeName(name) + ".xml");
                    exp.Invoke(tt, new object[] { new FileInfo(file), ExportOptions.None });
                    stats[0]++;
                    L("export tag table " + name + " -> " + file);
                }
                catch (Exception e) { stats[1]++; L("tag export ERR " + name + " | " + MsgOf(e)); }
            }
        }
        IEnumerable subs = GetProp(group, "Groups") as IEnumerable;
        if (subs == null) return;
        foreach (object sub in subs)
        {
            string nm = NameOf(sub);
            if (nm.Length == 0) continue;
            ExportTagDir(sub, Path.Combine(dir, SafeName(nm)), stats);
        }
    }

    static void ImportTagDir(object group, string dir, ImportOptions mode, int[] stats)
    {
        if (group == null) return;
        object tables = GetProp(group, "TagTables");
        string[] files = Directory.GetFiles(dir, "*.xml");
        if (files.Length > 0)
        {
            MethodInfo import = FindFileImport(tables);
            if (import == null)
            {
                // Older Openness builds have no tag Import at all: warn, do not
                // fail the run - the blocks still imported fine.
                L("no tag Import on this Openness version - " + files.Length
                  + " file(s) skipped in " + dir + " (add the tags in the GUI)");
            }
            else
            {
                ParameterInfo[] pars = import.GetParameters();
                foreach (string file in files)
                {
                    object[] argv = (pars.Length >= 2)
                        ? new object[] { new FileInfo(file), mode }
                        : new object[] { new FileInfo(file) };
                    try { import.Invoke(tables, argv); stats[0]++; L("imported tag table " + file); }
                    catch (Exception e) { stats[1]++; L("tag import ERR " + Path.GetFileName(file) + " | " + MsgOf(e)); }
                }
            }
        }
        object groups = GetProp(group, "Groups");
        foreach (string sub in Directory.GetDirectories(dir))
        {
            string name = Path.GetFileName(sub);
            object target = null;
            if (groups != null)
            {
                IEnumerable exist = groups as IEnumerable;
                if (exist != null)
                {
                    foreach (object g in exist)
                    {
                        if (string.Equals(NameOf(g), name, StringComparison.OrdinalIgnoreCase)) { target = g; break; }
                    }
                }
                if (target == null)
                {
                    MethodInfo create = groups.GetType().GetMethod("Create", new Type[] { typeof(string) });
                    if (create != null)
                    {
                        try { target = create.Invoke(groups, new object[] { name }); L("created tag group " + name); }
                        catch (Exception e) { L("tag group ERR " + name + " | " + MsgOf(e)); }
                    }
                }
            }
            if (target != null) ImportTagDir(target, sub, mode, stats);
            else L("skip tag subfolder " + name + " (group could not be resolved)");
        }
    }

    static void ImportTagTables(PlcSoftware sw, string tagDir, ImportOptions mode, int[] stats)
    {
        if (!Directory.Exists(tagDir)) { L("no tags folder " + tagDir + " (skipped)"); return; }
        object group = null;
        try { group = sw.TagTableGroup; }
        catch (Exception ex) { L("tag group ERR " + ex.Message); stats[1]++; return; }
        ImportTagDir(group, tagDir, mode, stats);
    }

    static string Arg(string[] a, int i, string def)
    {
        return (a.Length > i) ? a[i] : def;
    }

    // ---------- compile (reflection based, version tolerant) ----------

    static void DoCompile(PlcSoftware sw)
    {
        Type ic = null;
        try
        {
            Assembly asm = sw.GetType().Assembly;
            foreach (Type t in asm.GetTypes())
            {
                if (t.FullName == "Siemens.Engineering.Compiler.ICompilable") { ic = t; break; }
            }
        }
        catch (Exception ex) { L("compile: type scan failed " + ex.Message); }
        if (ic == null)
        {
            foreach (Assembly asm in AppDomain.CurrentDomain.GetAssemblies())
            {
                try
                {
                    foreach (Type t in asm.GetTypes())
                    {
                        if (t.FullName == "Siemens.Engineering.Compiler.ICompilable") { ic = t; break; }
                    }
                }
                catch { }
                if (ic != null) break;
            }
        }
        if (ic == null) { L("compile: ICompilable not available in this Openness version"); return; }

        object svc = null;
        foreach (MethodInfo mi in sw.GetType().GetMethods())
        {
            if (!mi.IsGenericMethodDefinition || mi.Name != "GetService") continue;
            try
            {
                object got = mi.MakeGenericMethod(ic).Invoke(sw, null);
                if (got != null && ic.IsInstanceOfType(got)) { svc = got; break; }
            }
            catch (Exception) { }
        }
        if (svc == null && ic.IsInstanceOfType(sw)) svc = sw;
        if (svc == null) { L("compile: no ICompilable service on " + sw.Name); return; }

        MethodInfo compile = ic.GetMethod("Compile");
        if (compile == null) { L("compile: Compile() not found"); return; }
        L("compiling " + sw.Name + " ...");
        object result = compile.Invoke(svc, null);
        DumpCompileResult(result);
    }

    static void DumpCompileResult(object result)
    {
        if (result == null) { L("compile: null result"); return; }
        Type rt = result.GetType();
        foreach (string propName in new string[] { "State", "ErrorCount", "WarningCount" })
        {
            try
            {
                PropertyInfo pi = rt.GetProperty(propName);
                if (pi != null) L("compile " + propName + " = " + pi.GetValue(result, null));
            }
            catch (Exception) { }
        }
        object msgs = null;
        try
        {
            PropertyInfo pi = rt.GetProperty("Messages");
            if (pi != null) msgs = pi.GetValue(result, null);
        }
        catch (Exception) { }
        IEnumerable en = msgs as IEnumerable;
        int n = 0, shown = 0;
        if (en != null)
        {
            foreach (object m in en)
            {
                n++;
                if (shown >= 200) continue;
                shown++;
                string sev = "", pathText = "", text = "";
                try
                {
                    Type mt = m.GetType();
                    PropertyInfo p1 = mt.GetProperty("State"); if (p1 != null) sev = Convert.ToString(p1.GetValue(m, null));
                    PropertyInfo p2 = mt.GetProperty("Path"); if (p2 != null) pathText = Convert.ToString(p2.GetValue(m, null));
                    PropertyInfo p3 = mt.GetProperty("Message"); if (p3 != null) text = Convert.ToString(p3.GetValue(m, null));
                }
                catch (Exception) { }
                L("  msg[" + sev + "] " + pathText + " | " + text);
            }
        }
        L("compile messages = " + n + (n > shown ? " (showed " + shown + ")" : ""));
    }

    // ---------- commands ----------

    static int CmdInfo()
    {
        try
        {
            Assembly ea = typeof(TiaPortal).Assembly;
            L("Openness assembly = " + ea.GetName().Name + " " + ea.GetName().Version);
            L("assembly location = " + ea.Location);
            L("runtime = .NET " + Environment.Version);
        }
        catch (Exception ex) { L("assembly probe failed: " + ex.Message); }
        try
        {
            IList<TiaPortalProcess> procs = TiaPortal.GetProcesses();
            L("GetProcesses count = " + procs.Count);
            for (int i = 0; i < procs.Count; i++)
            {
                TiaPortalProcess p = procs[i];
                string proj = "<none>";
                try { if (p.ProjectPath != null) proj = p.ProjectPath.ToString(); } catch { }
                string mode = "?";
                try { mode = p.Mode.ToString(); } catch { }
                L("  [" + i + "] pid=" + p.Id + " mode=" + mode + " project=" + proj);
            }
        }
        catch (Exception ex) { LEx(ex); return 3; }
        return 0;
    }

    static int CmdDump(string[] a)
    {
        string projectPath = Arg(a, 2, "");
        if (projectPath.Length == 0) { LErr("dump needs projectPath"); return 2; }
        TiaPortal tia = NewInstance();
        try
        {
            Project p = OpenProject(tia, projectPath);
            DumpProject(p);
            L("closing project (no save)");
            p.Close();
            L("CLOSE OK");
        }
        finally { try { tia.Dispose(); L("DISPOSE OK"); } catch { } }
        return 0;
    }

    static int CmdExport(string[] a)
    {
        string projectPath = Arg(a, 2, "");
        string outDir = Arg(a, 3, "");
        string filter = Arg(a, 4, "");
        if (projectPath.Length == 0 || outDir.Length == 0) { LErr("export needs projectPath and outDir"); return 2; }
        Directory.CreateDirectory(outDir);
        TiaPortal tia = NewInstance();
        try
        {
            Project p = OpenProject(tia, projectPath);
            foreach (PlcSoftware sw in FindPlcSoftware(p))
            {
                L("== software " + sw.Name);
                int[] stats = new int[2];
                ExportGroup(sw.BlockGroup, Path.Combine(outDir, SafeName(sw.Name), "blocks"), "", filter, stats);
                L("exported blocks = " + stats[0] + " errors = " + stats[1]);
                try
                {
                    string tagDir = Path.Combine(outDir, SafeName(sw.Name), "tags");
                    int[] tagStats = new int[2];
                    ExportTagDir(sw.TagTableGroup, tagDir, tagStats);
                    L("exported tag tables = " + tagStats[0] + " errors = " + tagStats[1]);
                }
                catch (Exception ex) { L("tag group ERR " + ex.Message); }
            }
            L("closing project (no save)");
            p.Close();
            L("CLOSE OK");
        }
        finally { try { tia.Dispose(); L("DISPOSE OK"); } catch { } }
        return 0;
    }

    static int CmdImport(string[] a)
    {
        string projectPath = Arg(a, 2, "");
        string inDir = Arg(a, 3, "");
        string saveFlag = Arg(a, 4, "yes");
        string overwriteFlag = Arg(a, 5, "yes");
        if (projectPath.Length == 0 || inDir.Length == 0) { LErr("import needs projectPath and inDir"); return 2; }
        bool overwrite = !string.Equals(overwriteFlag, "no", StringComparison.OrdinalIgnoreCase);
        L("import mode = " + (overwrite ? "overwrite" : "create only"));
        L("ImportOptions available = " + string.Join(", ", Enum.GetNames(typeof(ImportOptions))));
        ImportOptions mode = ImportMode(overwrite);
        int totalErr = 0;
        int totalOk = 0;
        TiaPortal tia = NewInstance();
        try
        {
            Project p = OpenProject(tia, projectPath);
            foreach (PlcSoftware sw in FindPlcSoftware(p))
            {
                L("== software " + sw.Name);
                int[] stats = new int[2];
                string root = Path.Combine(inDir, SafeName(sw.Name), "blocks");
                if (Directory.Exists(root))
                {
                    ImportDir(sw.BlockGroup, root, mode, stats);
                    L("imported blocks = " + stats[0] + " errors = " + stats[1]);
                }
                else L("no blocks folder " + root + " (skipped)");

                int[] tagStats = new int[2];
                string tagRoot = Path.Combine(inDir, SafeName(sw.Name), "tags");
                if (Directory.Exists(tagRoot))
                {
                    ImportTagTables(sw, tagRoot, mode, tagStats);
                    L("imported tag tables = " + tagStats[0] + " errors = " + tagStats[1]);
                }
                else L("no tags folder " + tagRoot + " (skipped)");

                totalOk += stats[0] + tagStats[0];
                totalErr += stats[1] + tagStats[1];
            }
            L("IMPORT TOTAL imported = " + totalOk + " errors = " + totalErr);
            if (string.Equals(saveFlag, "yes", StringComparison.OrdinalIgnoreCase))
            {
                L("saving project ...");
                p.Save();
                L("SAVE OK");
            }
            L("closing project");
            p.Close();
            L("CLOSE OK");
        }
        finally { try { tia.Dispose(); L("DISPOSE OK"); } catch { } }
        return (totalErr > 0) ? 3 : 0;
    }

    static int CmdCompile(string[] a)
    {
        string projectPath = Arg(a, 2, "");
        string saveFlag = Arg(a, 3, "no");
        if (projectPath.Length == 0) { LErr("compile needs projectPath"); return 2; }
        TiaPortal tia = NewInstance();
        try
        {
            Project p = OpenProject(tia, projectPath);
            foreach (PlcSoftware sw in FindPlcSoftware(p))
            {
                L("== software " + sw.Name);
                DoCompile(sw);
            }
            if (string.Equals(saveFlag, "yes", StringComparison.OrdinalIgnoreCase))
            {
                p.Save();
                L("SAVE OK");
            }
            L("closing project");
            p.Close();
            L("CLOSE OK");
        }
        finally { try { tia.Dispose(); L("DISPOSE OK"); } catch { } }
        return 0;
    }

    static int CmdSaveAs(string[] a)
    {
        string src = Arg(a, 2, "");
        string dstDir = Arg(a, 3, "");
        if (src.Length == 0 || dstDir.Length == 0) { LErr("saveas needs src project and destination directory"); return 2; }
        TiaPortal tia = NewInstance();
        try
        {
            Project p = OpenProject(tia, src);
            Directory.CreateDirectory(dstDir);
            L("saving as " + dstDir);
            p.SaveAs(new DirectoryInfo(dstDir));
            L("SAVEAS OK");
            p.Close();
            L("CLOSE OK");
        }
        finally { try { tia.Dispose(); L("DISPOSE OK"); } catch { } }
        return 0;
    }

    static int CmdAttach(string[] a)
    {
        string pidText = Arg(a, 2, "");
        if (pidText.Length == 0) { LErr("attach needs pid"); return 2; }
        int pid = int.Parse(pidText);
        IList<TiaPortalProcess> procs = TiaPortal.GetProcesses();
        TiaPortalProcess target = null;
        foreach (TiaPortalProcess p in procs)
        {
            if (p.Id == pid) { target = p; break; }
        }
        if (target == null) { LErr("pid " + pid + " not found in GetProcesses"); return 3; }
        L("attaching to pid " + pid);
        using (TiaPortal tia = target.Attach())
        {
            L("ATTACH OK");
            foreach (Project p in tia.Projects) DumpProject(p);
        }
        L("DETACH OK");
        return 0;
    }

    static int CmdSelfCheck(string[] a)
    {
        string projectPath = Arg(a, 2, "");
        if (projectPath.Length == 0) { LErr("selfcheck needs projectPath"); return 2; }
        TiaPortal tia = NewInstance();
        try
        {
            Project p = OpenProject(tia, projectPath);
            DumpProject(p);
            foreach (PlcSoftware sw in FindPlcSoftware(p)) DoCompile(sw);
            p.Close();
            L("CLOSE OK (no save)");
        }
        finally { try { tia.Dispose(); L("DISPOSE OK"); } catch { } }
        return 0;
    }
}
