using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Win32;

internal static class Program
{
    internal static readonly string ListPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "DNS Switcher", "lists", "dns-user.txt");
    internal static string Encode(string text) { return Convert.ToBase64String(Encoding.Unicode.GetBytes(text)); }
    internal static string Decode(string text) { return Encoding.Unicode.GetString(Convert.FromBase64String(text)); }
    private static string Resource(string name)
    {
        using (var stream = typeof(Program).Assembly.GetManifestResourceStream(name))
        using (var reader = new StreamReader(stream, Encoding.UTF8)) return reader.ReadToEnd();
    }
    internal static string Run(string action, string profile, string listPath)
    {
        string script = "$OutputEncoding=[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); . ([scriptblock]::Create([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String([Console]::In.ReadToEnd())))) -Action " + action + " -ListPath ([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('" + Encode(listPath) + "'))) -ProfileName ([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('" + Encode(profile) + "')))";
        var info = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe"), "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand " + Encode(script));
        info.UseShellExecute = false;
        info.CreateNoWindow = true;
        info.RedirectStandardOutput = true;
        info.RedirectStandardError = true;
        info.RedirectStandardInput = true;
        info.StandardOutputEncoding = Encoding.UTF8;
        info.StandardErrorEncoding = Encoding.UTF8;
        using (var process = Process.Start(info))
        {
            // Pass embedded scripts over stdin to avoid Windows command-line length limits.
            string backend = Resource("TrayBackend.ps1");
            int bodyStart = backend.IndexOf("$ErrorActionPreference", StringComparison.Ordinal);
            process.StandardInput.Write(Encode("param($Action,$ListPath,$ProfileName)\n$script:DohProbeSource=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('" + Encode(Resource("DohProbe.cs")) + "'))\n" + Resource("TrayCore.ps1").Replace("param([switch]$LibraryOnly)", "") + "\n" + backend.Substring(bodyStart)));
            process.StandardInput.Close();
            var output = process.StandardOutput.ReadToEndAsync();
            var error = process.StandardError.ReadToEndAsync();
            process.WaitForExit();
            Task.WaitAll(output, error);
            if (process.ExitCode != 0) throw new Exception(error.Result + output.Result);
            return output.Result.Trim();
        }
    }

    [STAThread]
    private static int Main(string[] args)
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        if (args.Length == 3 && args[0] == "--apply")
        {
            try { Run("apply", Decode(args[1]), Decode(args[2])); return 0; }
            catch (Exception ex) { MessageBox.Show(ex.Message, "Ошибка переключения DNS", MessageBoxButtons.OK, MessageBoxIcon.Error); return 1; }
        }
        bool created;
        using (var mutex = new Mutex(true, "Local\\DNS-Switcher-Tray", out created))
        {
            if (!created) return 0;
            try { using (var tray = new TrayContext()) Application.Run(tray); }
            catch (Exception ex) { MessageBox.Show(ex.Message, "DNS Switcher", MessageBoxButtons.OK, MessageBoxIcon.Error); return 1; }
        }
        return 0;
    }
}

internal sealed class TrayContext : ApplicationContext
{
    private readonly NotifyIcon icon;
    private readonly Icon appIcon;
    private readonly ContextMenuStrip menu = new ContextMenuStrip();
    private readonly System.Windows.Forms.Timer refreshTimer = new System.Windows.Forms.Timer();
    private DateTime listModified;
    private DateTime lastRefresh = DateTime.MinValue;
    private string activeName = "#unknown";
    private bool disposed;
    private bool busy;
    public TrayContext()
    {
        using (var stream = typeof(Program).Assembly.GetManifestResourceStream("AppIcon.ico"))
        using (var original = new Icon(stream, SystemInformation.SmallIconSize)) appIcon = (Icon)original.Clone();
        menu.Renderer = new DarkMenuRenderer();
        menu.BackColor = DarkMenuRenderer.Background;
        menu.ForeColor = Color.FromArgb(240, 240, 240);
        menu.Font = new Font("Segoe UI", 9F);
        menu.ShowImageMargin = false;
        menu.ShowCheckMargin = true;
        menu.Padding = new Padding(5);
        icon = new NotifyIcon { Icon = appIcon, Text = "DNS Switcher", ContextMenuStrip = menu, Visible = true };
        icon.DoubleClick += async delegate { await ShowStatus(); };
        Reload();
        refreshTimer.Interval = 2000;
        refreshTimer.Tick += delegate {
            if (!busy && !menu.Visible && (File.GetLastWriteTimeUtc(Program.ListPath) != listModified || (DateTime.UtcNow - lastRefresh).TotalSeconds >= 30)) Reload();
        };
        refreshTimer.Start();
    }
    private ToolStripMenuItem Item(string title, EventHandler handler)
    {
        var item = menu.Items.Add(title, null, handler);
        item.Padding = new Padding(10, 5, 10, 5);
        return (ToolStripMenuItem)item;
    }
    private async void Reload()
    {
        if (busy) return;
        SetBusy(true);
        string names = "";
        string error = null;
        DateTime readVersion = File.GetLastWriteTimeUtc(Program.ListPath);
        try { names = await Task.Run(() => Program.Run("menu", "", Program.ListPath)); }
        catch (Exception ex) { error = ex.Message; }
        if (disposed) return;
        lastRefresh = DateTime.UtcNow;
        listModified = readVersion;
        var lines = names.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
        activeName = lines.Length > 0 ? Encoding.UTF8.GetString(Convert.FromBase64String(lines[0])) : "#unknown";
        for (int i = menu.Items.Count - 1; i >= 0; i--) menu.Items[i].Dispose();
        menu.Items.Clear();
        Item("Текущие настройки DNS…", async delegate { await ShowStatus(); });
        menu.Items.Add(new ToolStripSeparator());
        Item("Автоматический DNS", async delegate { await Apply(""); }).Checked = activeName == "#auto";
        for (int i = 1; i < lines.Length; i++)
        {
            string name = Encoding.UTF8.GetString(Convert.FromBase64String(lines[i]));
            Item(name.Replace("&", "&&"), async delegate { await Apply(name); }).Checked = activeName == name;
        }
        menu.Items.Add(new ToolStripSeparator());
        Item("Изменить список DNS…", delegate {
            try { Process.Start(new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "notepad.exe"), "\"" + Program.ListPath + "\"") { UseShellExecute = true }); }
            catch (Exception ex) { Error(ex); }
        });
        Item("Обновить список", delegate { Reload(); });
        var startup = Item("Запускать вместе с Windows", delegate { });
        startup.Checked = StartupEnabled();
        startup.Click += delegate {
            try {
                using (var key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run")) {
                    if (StartupEnabled()) key.DeleteValue("DNS Switcher", false);
                    else key.SetValue("DNS Switcher", "\"" + Application.ExecutablePath + "\"");
                }
                startup.Checked = StartupEnabled();
            } catch (Exception ex) { Error(ex); }
        };
        Item("Выход", delegate { ExitThread(); });
        SetBusy(false);
        if (error != null) icon.ShowBalloonTip(4000, "Не удалось обновить DNS", "Исправьте список или проверьте настройки сети. Автоматический DNS доступен.", ToolTipIcon.Warning);
    }
    private static bool StartupEnabled()
    {
        using (var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run"))
            return key != null && string.Equals(key.GetValue("DNS Switcher") as string, "\"" + Application.ExecutablePath + "\"", StringComparison.OrdinalIgnoreCase);
    }
    private void SetBusy(bool value)
    {
        busy = value;
        menu.Enabled = !value;
        string label = activeName == "#auto" ? "Автоматический DNS" : activeName == "#mixed" ? "Разные DNS на адаптерах" : activeName == "#offline" ? "Нет подключения" : activeName == "#other" ? "Другой DNS" : activeName == "#unknown" ? "Не удалось прочитать DNS" : activeName;
        string tooltip = value ? "DNS Switcher — подождите…" : "DNS Switcher — " + label;
        icon.Text = tooltip.Length > 63 ? tooltip.Substring(0, 60) + "…" : tooltip;
    }
    private async Task ShowStatus()
    {
        if (busy) return;
        SetBusy(true);
        try { var status = await Task.Run(() => Program.Run("status", "", Program.ListPath)); MessageBox.Show(status, "Текущие настройки DNS", MessageBoxButtons.OK, MessageBoxIcon.Information); }
        catch (Exception ex) { Error(ex); }
        finally { SetBusy(false); }
    }
    private async Task Apply(string name)
    {
        if (busy) return;
        SetBusy(true);
        try
        {
            var info = new ProcessStartInfo(Application.ExecutablePath, "--apply \"" + Program.Encode(name) + "\" \"" + Program.Encode(Program.ListPath) + "\"") { UseShellExecute = true, Verb = "runas", WindowStyle = ProcessWindowStyle.Hidden };
            int code = await Task.Run(() => { using (var child = Process.Start(info)) { child.WaitForExit(); return child.ExitCode; } });
            icon.ShowBalloonTip(5000, "DNS Switcher", code == 0 ? "Готово: " + (name.Length == 0 ? "автоматический DNS" : name) : "Переключение не выполнено. Подробности показаны в сообщении об ошибке.", code == 0 ? ToolTipIcon.Info : ToolTipIcon.Warning);
        }
        catch (System.ComponentModel.Win32Exception ex) { if (ex.NativeErrorCode != 1223) Error(ex); }
        catch (Exception ex) { Error(ex); }
        finally { SetBusy(false); Reload(); }
    }
    private static void Error(Exception ex) { MessageBox.Show(ex.Message, "DNS Switcher", MessageBoxButtons.OK, MessageBoxIcon.Error); }
    protected override void Dispose(bool disposing)
    {
        if (disposing) { disposed = true; refreshTimer.Stop(); refreshTimer.Dispose(); icon.Visible = false; icon.Dispose(); appIcon.Dispose(); var font = menu.Font; menu.Dispose(); font.Dispose(); }
        base.Dispose(disposing);
    }
}

internal sealed class DarkMenuRenderer : ToolStripProfessionalRenderer
{
    internal static readonly Color Background = Color.FromArgb(20, 20, 20);
    public DarkMenuRenderer() { RoundedEdges = false; }
    protected override void OnRenderToolStripBackground(ToolStripRenderEventArgs e)
    {
        e.Graphics.Clear(Background);
    }
    protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e)
    {
        if (e.Item.Selected && e.Item.Enabled)
            using (var brush = new SolidBrush(Color.FromArgb(49, 49, 49)))
                e.Graphics.FillRectangle(brush, new Rectangle(2, 0, e.Item.Width - 4, e.Item.Height));
    }
    protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e)
    {
        e.TextColor = e.Item.Enabled ? Color.FromArgb(240, 240, 240) : Color.FromArgb(130, 130, 130);
        base.OnRenderItemText(e);
    }
    protected override void OnRenderSeparator(ToolStripSeparatorRenderEventArgs e)
    {
        using (var pen = new Pen(Color.FromArgb(55, 55, 55)))
            e.Graphics.DrawLine(pen, 10, e.Item.Height / 2, e.Item.Width - 10, e.Item.Height / 2);
    }
    protected override void OnRenderToolStripBorder(ToolStripRenderEventArgs e)
    {
        using (var pen = new Pen(Color.FromArgb(65, 65, 65)))
            e.Graphics.DrawRectangle(pen, 0, 0, e.ToolStrip.Width - 1, e.ToolStrip.Height - 1);
    }
    protected override void OnRenderImageMargin(ToolStripRenderEventArgs e) { }
    protected override void OnRenderItemCheck(ToolStripItemImageRenderEventArgs e)
    {
        var r = e.ImageRectangle;
        using (var pen = new Pen(Color.FromArgb(110, 210, 150), 2F)) {
            e.Graphics.DrawLines(pen, new[] { new Point(r.Left + 2, r.Top + r.Height / 2), new Point(r.Left + 6, r.Bottom - 3), new Point(r.Right - 1, r.Top + 3) });
        }
    }
}
