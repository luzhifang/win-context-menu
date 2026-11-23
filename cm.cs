// cm.exe —— 右键菜单增强的动作程序。安装时用系统自带的 csc.exe 编译（C# 5 / .NET Framework 4）。
//
// 每次点击菜单都会启动一次；多选时 Explorer 会给每个选中项各启动一次（最多 15 个），所以要尽量轻：
// 不加载 WinForms，剪贴板和消息框直接调 Win32 API。
//
// 用法:
//   cm.exe <动作> [-V] <路径>        菜单动作，见 Run()
//   cm.exe --jb <exe名> [参数...]    找到最新安装的 JetBrains IDE（如 goland64.exe）再启动它
//   cm.exe --run <程序> [参数...]    不显示控制台窗口启动程序（"应用"里的卸载入口用）
//   -V：路径来自 "%V."（目录/背景/驱动器），末尾多补了一个点，用来避开 "C:\" 结尾反斜杠吃掉引号的问题
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using Microsoft.Win32;

public static class ContextMenuTool
{
    const string Title = "右键工具";
    const int QuietMs = 200;   // 多选合并：队列这么久没有新项目就开始处理。实测 Explorer 相邻两个进程间隔最大约 17 ms
    static readonly Encoding Utf8 = new UTF8Encoding(false);

    // ======================= 入口 =======================
    static int Main()
    {
        string first, rest;
        SplitFirst(SkipToken(Environment.CommandLine), out first, out rest);
        if (first.Length == 0) return 1;
        try
        {
            if (first == "--run")
            {
                string prog, args;
                SplitFirst(rest, out prog, out args);
                Start(prog, args, false);
                return 0;
            }
            if (first == "--jb")
            {
                string exe, args;
                SplitFirst(rest, out exe, out args);
                string path = FindJetBrains(exe);
                if (path == null)
                {
                    Msg("没有找到 " + exe + "，可能已经卸载。\n\n重新运行 install.cmd 可以刷新右键菜单。", MB_ICONERROR);
                    return 2;
                }
                Start(path, args, false);
                return 0;
            }

            string[] argv = Environment.GetCommandLineArgs();   // [0]=exe [1]=动作 ...
            bool v = false;
            string target = null;
            for (int i = 2; i < argv.Length; i++)
            {
                if (argv[i] == "-V") v = true; else target = argv[i];
            }
            if (target == null) return 1;
            Run(first, Normalize(target, v));
            return 0;
        }
        catch (Exception e)
        {
            if (IsUacCancel(e)) return 0;
            Msg(first + " 失败：\n" + e.Message, MB_ICONERROR);
            return 1;
        }
    }

    static string Normalize(string p, bool v)
    {
        if (v && p.EndsWith(".")) p = p.Substring(0, p.Length - 1);
        if (p.Length > 3 && p.EndsWith("\\")) p = p.TrimEnd('\\');
        return p;
    }

    // ======================= 动作 =======================
    static void Run(string action, string path)
    {
        List<string> b;
        switch (action)
        {
            case "CopyWinPath":
                b = Batch(action, path);
                if (b.Count > 0) SetClipboard(string.Join("\r\n", b));
                break;

            case "CopyWslPath":
                b = Batch(action, path);
                if (b.Count > 0) SetClipboard(string.Join("\n", b.ConvertAll(p => WslInfo(p).Path)));
                break;

            case "CopyName":
                b = Batch(action, path);
                if (b.Count > 0) SetClipboard(string.Join("\r\n", b.ConvertAll(p => Path.GetFileName(p))));
                break;

            case "NewFolderWithSelection":
                b = Batch(action, path);
                if (b.Count > 0) NewFolderWithSelection(b);
                break;

            case "Sha256":
                b = Batch(action, path);
                if (b.Count > 0) Sha256(b);
                break;

            case "TakeOwn":
                b = Batch(action, path);
                if (b.Count > 0) TakeOwn(b);
                break;

            case "VSCodeWsl": VSCodeWsl(path); break;
            case "RunInWsl": RunInWsl(path); break;
            case "AdminTerminal": AdminTerminal(path); break;

            // 没有 Windows Terminal 时，终端菜单直接打开对应的控制台窗口
            case "ShellWsl":
            {
                WslPath w = WslInfo(path);
                Start("wsl.exe", DistroArg(w) + "--cd \"" + w.Path + "\"", true);
                break;
            }
            case "ShellPowerShell":
                Start("powershell.exe", "-NoLogo -NoExit -Command Set-Location -LiteralPath '" + path.Replace("'", "''") + "'", true);
                break;
            case "ShellCmd":
                Start("cmd.exe", "/k pushd \"" + path + "\"", true);
                break;

            default:
                Msg("未知动作: " + action, MB_ICONERROR);
                break;
        }
    }

    static void NewFolderWithSelection(List<string> items)
    {
        string parent = Path.GetDirectoryName(items[0]);
        const string baseName = "新建文件夹";
        string dest = Path.Combine(parent, baseName);
        for (int i = 2; Directory.Exists(dest) || File.Exists(dest); i++)
            dest = Path.Combine(parent, baseName + " (" + i + ")");
        Directory.CreateDirectory(dest);
        var failed = new List<string>();
        foreach (string it in items)
        {
            try
            {
                string to = Path.Combine(dest, Path.GetFileName(it));
                if (Directory.Exists(it)) Directory.Move(it, to); else File.Move(it, to);
            }
            catch (Exception e) { failed.Add(it + " : " + e.Message); }
        }
        if (failed.Count > 0) Msg("以下项目移动失败：\n" + string.Join("\n", failed), MB_ICONWARNING, "用所选项目新建文件夹");
    }

    static void Sha256(List<string> files)
    {
        files = files.FindAll(File.Exists);
        if (files.Count == 0) return;
        long total = 0;
        foreach (string f in files) total += new FileInfo(f).Length;

        // 超过 1 秒还没算完才弹出提示，小文件不会闪一下
        var hint = Hint.Show(1000, "正在计算 SHA256（共 " + (total / (1024.0 * 1024 * 1024)).ToString("0.00") + " GB）……\r\n\r\n" +
            "算完后本窗口会自动关闭并显示结果。\r\n点「取消」停止计算。", "SHA256");
        var sw = Stopwatch.StartNew();
        var lines = new List<string>();
        try
        {
            var buf = new byte[1 << 20];   // 流式计算，内存不随文件大小增长
            foreach (string f in files)
            {
                using (var s = new FileStream(f, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 4096, FileOptions.SequentialScan))
                using (var h = new SHA256CryptoServiceProvider())
                {
                    int n;
                    while ((n = s.Read(buf, 0, buf.Length)) > 0)
                    {
                        if (hint.Cancelled) return;
                        h.TransformBlock(buf, 0, n, null, 0);
                    }
                    h.TransformFinalBlock(buf, 0, 0);
                    var sb = new StringBuilder(64);
                    foreach (byte x in h.Hash) sb.Append(x.ToString("x2"));
                    lines.Add(sb + "  " + Path.GetFileName(f));
                }
            }
        }
        finally { hint.Close(); }

        SetClipboard(string.Join("\r\n", lines));
        string took = sw.ElapsedMilliseconds < 1000 ? "" : "，耗时 " + sw.Elapsed.TotalSeconds.ToString("0.0") + " 秒";
        Msg(string.Join("\n", lines) + "\n\n（已复制到剪贴板，格式同 sha256sum" + took + "）", MB_ICONINFORMATION, "SHA256");
    }

    // 耗时操作的提示框：在后台线程上，delayMs 后操作还没结束才显示；结束时由主线程关闭。
    // 用户点「取消」时 Cancelled 变为 true，点「确定」只是关掉提示、操作继续。
    sealed class Hint
    {
        volatile bool cancelled;
        readonly ManualResetEvent done = new ManualResetEvent(false);
        uint threadId;
        Thread thread;
        public bool Cancelled { get { return cancelled; } }

        public static Hint Show(int delayMs, string text, string title)
        {
            var h = new Hint();
            h.thread = new Thread(() =>
            {
                h.threadId = GetCurrentThreadId();
                if (h.done.WaitOne(delayMs)) return;
                int r = MessageBoxW(IntPtr.Zero, text, title, MB_OKCANCEL | MB_ICONINFORMATION | MB_SETFOREGROUND);
                if (r == IDCANCEL && !h.done.WaitOne(0)) h.cancelled = true;
            });
            h.thread.IsBackground = true;   // 主线程结束时不必等它
            h.thread.Start();
            return h;
        }

        public void Close()
        {
            done.Set();
            for (int i = 0; i < 20 && !thread.Join(i == 0 ? 0 : 50); i++)   // 消息框可能正在创建，稍等重试
            {
                EnumThreadWindows(threadId, (w, l) =>
                {
                    var cls = new StringBuilder(16);
                    GetClassNameW(w, cls, cls.Capacity);
                    if (cls.ToString() == "#32770") PostMessageW(w, WM_CLOSE, IntPtr.Zero, IntPtr.Zero);   // 对话框窗口类
                    return true;
                }, IntPtr.Zero);
            }
        }
    }

    static void TakeOwn(List<string> items)
    {
        // *S-1-5-32-544 = Administrators 组，用 SID 避免中文系统里组名被本地化
        var cmds = new List<string>();
        foreach (string it in items)
        {
            if (Directory.Exists(it))
                cmds.Add("takeown /f \"" + it + "\" /r /d y && icacls \"" + it + "\" /grant *S-1-5-32-544:F /t /c /q");
            else
                cmds.Add("takeown /f \"" + it + "\" && icacls \"" + it + "\" /grant *S-1-5-32-544:F /c /q");
        }
        RunAs("cmd.exe", "/s /c \" " + string.Join(" & ", cmds) + " & echo. & pause \"");
    }

    static void VSCodeWsl(string path)
    {
        WslPath w = WslInfo(path);
        string distro = w.Distro ?? DefaultDistro();
        if (distro == null) throw new Exception("没有找到 WSL 发行版。");
        string[] parts = w.Path.Split('/');
        for (int i = 0; i < parts.Length; i++) parts[i] = Uri.EscapeDataString(parts[i]);
        string uri = "vscode-remote://wsl+" + distro + string.Join("/", parts);
        string flag = File.Exists(path) ? "--file-uri" : "--folder-uri";
        string code = Config("vscode") ??
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Programs\Microsoft VS Code\Code.exe");
        Start(code, flag + " " + uri, false);
    }

    static void RunInWsl(string path)
    {
        WslPath w = WslInfo(path);
        int k = w.Path.LastIndexOf('/');
        string dir = k > 0 ? w.Path.Substring(0, k) : "/";
        string q = "'" + w.Path.Replace("'", "'\\''") + "'";
        string sh = "bash " + q + "; rc=$?; echo; read -rsn1 -p '[退出码 '$rc'] 按任意键关闭...'";
        Start("wsl.exe", DistroArg(w) + "--cd \"" + dir + "\" -e bash -c \"" + sh + "\"", true);
    }

    static void AdminTerminal(string path)
    {
        string wt = Config("wt");
        if (wt != null)
        {
            string d = path.EndsWith("\\") ? path + "." : path;   // "C:\" -> "C:\."，避免结尾反斜杠转义掉引号
            try { RunAs(wt, "-d \"" + d + "\" powershell.exe -NoLogo"); return; }
            catch (Exception e) { if (IsUacCancel(e)) return; }
        }
        RunAs("powershell.exe", "-NoLogo -NoExit -Command Set-Location -LiteralPath '" + path.Replace("'", "''") + "'");
    }

    // ======================= WSL 路径 =======================
    class WslPath { public string Distro; public string Path; }

    // C:\a\b -> (默认发行版, /mnt/c/a/b)；\\wsl.localhost\Ubuntu\home -> (Ubuntu, /home)
    static WslPath WslInfo(string p)
    {
        Match m = Regex.Match(p, @"^\\\\wsl(?:\.localhost|\$)\\([^\\]+)(.*)$", RegexOptions.IgnoreCase);
        if (m.Success)
        {
            string r = m.Groups[2].Value.Replace('\\', '/');
            return new WslPath { Distro = m.Groups[1].Value, Path = r.Length == 0 ? "/" : r };
        }
        m = Regex.Match(p, @"^([A-Za-z]):(.*)$");
        if (m.Success)
            return new WslPath { Path = "/mnt/" + m.Groups[1].Value.ToLowerInvariant() + m.Groups[2].Value.Replace('\\', '/').TrimEnd('/') };
        return new WslPath { Path = p.Replace('\\', '/') };
    }

    static string DistroArg(WslPath w) { return w.Distro != null ? "-d " + w.Distro + " " : ""; }

    static string DefaultDistro()
    {
        using (var lx = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Lxss"))
        {
            string id = lx == null ? null : lx.GetValue("DefaultDistribution") as string;
            if (id == null) return null;
            using (var d = lx.OpenSubKey(id)) return d == null ? null : d.GetValue("DistributionName") as string;
        }
    }

    // ======================= 多选合并 =======================
    // Explorer 对每个选中项各启动一次本程序。用两个命名互斥体把这些调用合并成一批：
    // 第一个到达的进程当 leader，等队列安静后统一处理；其余进程写完队列就退出。
    static List<string> Batch(string key, string item)
    {
        string queue = Path.Combine(Path.GetTempPath(), "cm-queue-" + key + ".txt");
        var result = new List<string>();
        using (var append = new Mutex(false, @"Local\cm-append-" + key))
        using (var lead = new Mutex(false, @"Local\cm-lead-" + key))
        {
            bool isLeader;
            Wait(append);
            try
            {
                File.AppendAllText(queue, DateTime.UtcNow.Ticks + "\t" + item + "\n", Utf8);
                try { isLeader = lead.WaitOne(0); }
                catch (AbandonedMutexException) { isLeader = true; }
            }
            finally { append.ReleaseMutex(); }
            if (!isLeader) return result;

            long last = new FileInfo(queue).Length;
            while (true)
            {
                Thread.Sleep(QuietMs);
                long len = new FileInfo(queue).Length;
                if (len == last) break;
                last = len;
            }

            string[] lines;
            Wait(append);
            try
            {
                lines = File.ReadAllLines(queue, Utf8);
                File.Delete(queue);
                lead.ReleaseMutex();
            }
            finally { append.ReleaseMutex(); }

            long cutoff = DateTime.UtcNow.AddSeconds(-30).Ticks;   // 忽略上次异常退出残留的旧条目
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (string l in lines)
            {
                int t = l.IndexOf('\t');
                long ticks;
                if (t > 0 && long.TryParse(l.Substring(0, t), out ticks) && ticks >= cutoff)
                {
                    string p = l.Substring(t + 1);
                    if (seen.Add(p)) result.Add(p);
                }
            }
        }
        return result;
    }

    static void Wait(Mutex m)
    {
        try { m.WaitOne(); } catch (AbandonedMutexException) { }
    }

    // ======================= JetBrains =======================
    // 返回最新版本的 <安装目录>\bin\<exe>，找不到返回 null。install.ps1 也调用它来检测是否已安装。
    // 安装目录带版本号（如 "GoLand 2026.2.1"），大版本升级会装到新目录，所以每次点击时才查找。
    public static string FindJetBrains(string exe)
    {
        var dirs = new List<string>();

        // 1. 官方安装程序：HKLM（或仅当前用户安装时的 HKCU）\SOFTWARE\JetBrains\<产品>\<build号>，默认值是安装目录
        foreach (RegistryHive hive in new[] { RegistryHive.LocalMachine, RegistryHive.CurrentUser })
        {
            try
            {
                using (var root = RegistryKey.OpenBaseKey(hive, RegistryView.Registry64))
                using (var jb = root.OpenSubKey(@"SOFTWARE\JetBrains"))
                {
                    if (jb == null) continue;
                    foreach (string product in jb.GetSubKeyNames())
                        using (var pk = jb.OpenSubKey(product))
                        {
                            if (pk == null) continue;
                            foreach (string build in pk.GetSubKeyNames())
                                using (var bk = pk.OpenSubKey(build))
                                {
                                    string d = bk == null ? null : bk.GetValue("") as string;
                                    if (!string.IsNullOrEmpty(d)) dirs.Add(d);
                                }
                        }
                }
            }
            catch (Exception) { }
        }

        // 2. 常见安装位置：默认目录、Toolbox 2.x（%LOCALAPPDATA%\Programs\<IDE>）、旧版 Toolbox（apps\<IDE>\ch-0\<build>）
        string pf = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        string la = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        AddSubDirs(dirs, Path.Combine(pf, "JetBrains"), 1);
        AddSubDirs(dirs, Path.Combine(la, "Programs"), 1);
        AddSubDirs(dirs, Path.Combine(la, @"JetBrains\Toolbox\apps"), 3);

        string best = null;
        Version bestVer = null;
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (string d in dirs)
        {
            string full;
            try { full = Path.GetFullPath(d).TrimEnd('\\'); }
            catch (Exception) { continue; }
            if (!seen.Add(full)) continue;
            string p = Path.Combine(Path.Combine(full, "bin"), exe);
            if (!File.Exists(p)) continue;
            Version v = BuildOf(full);
            if (best == null || v > bestVer) { best = p; bestVer = v; }
        }
        return best;
    }

    // build.txt 内容形如 "GO-262.11879.101"
    static Version BuildOf(string dir)
    {
        try
        {
            string s = File.ReadAllText(Path.Combine(dir, "build.txt")).Trim();
            int i = s.IndexOf('-');
            if (i >= 0) s = s.Substring(i + 1);
            Version v;
            if (Version.TryParse(s, out v)) return v;
        }
        catch (Exception) { }
        return new Version(0, 0);
    }

    static void AddSubDirs(List<string> list, string root, int depth)
    {
        if (depth <= 0 || !Directory.Exists(root)) return;
        string[] subs;
        try { subs = Directory.GetDirectories(root); }
        catch (Exception) { return; }
        foreach (string s in subs)
        {
            list.Add(s);
            AddSubDirs(list, s, depth - 1);
        }
    }

    // ======================= 配置 =======================
    // cm.config 由 install.ps1 写入：每行 key=value（vscode、wt）
    static Dictionary<string, string> config;

    static string Config(string key)
    {
        if (config == null)
        {
            config = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            try
            {
                foreach (string l in File.ReadAllLines(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "cm.config"), Encoding.UTF8))
                {
                    int i = l.IndexOf('=');
                    if (i > 0) config[l.Substring(0, i).Trim()] = l.Substring(i + 1).Trim();
                }
            }
            catch (Exception) { }
        }
        string v;
        return config.TryGetValue(key, out v) && v.Length > 0 ? v : null;
    }

    // ======================= 进程 =======================
    static void Start(string file, string args, bool newWindow)
    {
        var psi = new ProcessStartInfo(file, args);
        psi.UseShellExecute = newWindow;
        if (!newWindow) psi.CreateNoWindow = true;
        using (Process.Start(psi)) { }
    }

    static void RunAs(string file, string args)
    {
        var psi = new ProcessStartInfo(file, args);
        psi.UseShellExecute = true;
        psi.Verb = "runas";
        using (Process.Start(psi)) { }
    }

    // 用户在 UAC 弹窗里点了"否"（Win32 错误 1223）
    static bool IsUacCancel(Exception e)
    {
        for (; e != null; e = e.InnerException)
        {
            var w = e as Win32Exception;
            if (w != null && w.NativeErrorCode == 1223) return true;
        }
        return false;
    }

    // ======================= Win32：消息框、剪贴板 =======================
    const uint MB_OKCANCEL = 0x1, MB_ICONERROR = 0x10, MB_ICONWARNING = 0x30, MB_ICONINFORMATION = 0x40, MB_SETFOREGROUND = 0x10000;
    const int IDCANCEL = 2;
    const uint WM_CLOSE = 0x0010;

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);

    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumThreadWindows(uint threadId, EnumWindowsProc fn, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr hWnd, StringBuilder name, int max);
    [DllImport("user32.dll")] static extern bool PostMessageW(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();

    static void Msg(string text, uint icon, string title = Title)
    {
        MessageBoxW(IntPtr.Zero, text, title, icon | MB_SETFOREGROUND);
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr CreateWindowExW(int exStyle, string cls, string name, int style, int x, int y, int w, int h,
        IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
    [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr hWnd);
    [DllImport("user32.dll")] static extern bool OpenClipboard(IntPtr hWnd);
    [DllImport("user32.dll")] static extern bool EmptyClipboard();
    [DllImport("user32.dll")] static extern IntPtr SetClipboardData(uint format, IntPtr hMem);
    [DllImport("user32.dll")] static extern bool CloseClipboard();
    [DllImport("kernel32.dll")] static extern IntPtr GlobalAlloc(uint flags, UIntPtr bytes);
    [DllImport("kernel32.dll")] static extern IntPtr GlobalLock(IntPtr hMem);
    [DllImport("kernel32.dll")] static extern bool GlobalUnlock(IntPtr hMem);
    [DllImport("kernel32.dll")] static extern IntPtr GlobalFree(IntPtr hMem);

    static void SetClipboard(string text)
    {
        // 剪贴板必须由一个窗口持有（OpenClipboard(NULL) 时 SetClipboardData 会失败），建一个不可见的消息窗口
        IntPtr hwnd = CreateWindowExW(0, "STATIC", "", 0, 0, 0, 0, 0, new IntPtr(-3) /* HWND_MESSAGE */,
            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        try
        {
            bool opened = false;
            for (int i = 0; i < 20 && !(opened = OpenClipboard(hwnd)); i++) Thread.Sleep(50);   // 可能被别的程序短暂占用
            if (!opened) throw new Exception("剪贴板正被其他程序占用，请稍后再试。");
            try
            {
                EmptyClipboard();
                IntPtr h = GlobalAlloc(0x0002 /* GMEM_MOVEABLE */, (UIntPtr)((text.Length + 1) * 2));
                IntPtr p = GlobalLock(h);
                Marshal.Copy(text.ToCharArray(), 0, p, text.Length);
                Marshal.WriteInt16(p, text.Length * 2, 0);
                GlobalUnlock(h);
                if (SetClipboardData(13 /* CF_UNICODETEXT */, h) == IntPtr.Zero)
                {
                    GlobalFree(h);
                    throw new Exception("写入剪贴板失败。");
                }
            }
            finally { CloseClipboard(); }
        }
        finally { if (hwnd != IntPtr.Zero) DestroyWindow(hwnd); }
    }

    // ======================= 命令行 =======================
    // 拆出第一个参数（可带引号），其余原样保留
    static void SplitFirst(string s, out string first, out string rest)
    {
        if (s.Length > 0 && s[0] == '"')
        {
            int j = s.IndexOf('"', 1);
            if (j < 0) j = s.Length;
            first = s.Substring(1, j - 1);
            rest = j + 1 < s.Length ? s.Substring(j + 1).TrimStart() : "";
        }
        else
        {
            int j = s.IndexOf(' ');
            first = j < 0 ? s : s.Substring(0, j);
            rest = j < 0 ? "" : s.Substring(j + 1).TrimStart();
        }
    }

    // 跳过命令行中的第一个 token（自身 exe 路径）
    static string SkipToken(string cl)
    {
        int i;
        if (cl.StartsWith("\"")) { i = cl.IndexOf('"', 1); i = i < 0 ? cl.Length : i + 1; }
        else { i = cl.IndexOf(' '); if (i < 0) i = cl.Length; }
        return cl.Substring(i).TrimStart();
    }
}
