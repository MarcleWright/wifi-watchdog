using System;
using System.IO;
using System.Reflection;
using System.Management.Automation;
using System.Management.Automation.Runspaces;

[assembly: AssemblyTitle("Wi-Fi Watchdog")]
[assembly: AssemblyDescription("Wi-Fi automatic recovery background monitor")]
[assembly: AssemblyProduct("Wi-Fi Watchdog")]
[assembly: AssemblyCompany("marclewang")]
[assembly: AssemblyVersion("1.0.0.0")]

internal static class WifiWatchdogHost
{
    [STAThread]
    private static int Main(string[] args)
    {
        string root = AppDomain.CurrentDomain.BaseDirectory;
        bool checkOnly = false;
        string config = Path.Combine(root, "config.json");
        try
        {
            for (int i = 0; i < args.Length; i++)
            {
                if (args[i] == "--check") checkOnly = true;
                else if (args[i] == "--config" && i + 1 < args.Length) config = Path.GetFullPath(args[++i]);
                else throw new ArgumentException("Unsupported argument.");
            }
            string script = Path.Combine(root, "WifiWatchdog.ps1");
            if (!File.Exists(script)) throw new FileNotFoundException("Watchdog script missing.");
            var initial = InitialSessionState.CreateDefault();
            initial.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;
            using (var runspace = RunspaceFactory.CreateRunspace(initial))
            using (var shell = PowerShell.Create())
            {
                runspace.Open();
                shell.Runspace = runspace;
                // Host the existing engine in this EXE; do not create a powershell.exe child.
                // Discard console streams so long-running monitoring cannot accumulate host output.
                shell.AddScript("param($path, $config, $check) $ErrorActionPreference = 'Stop'; & $path -ConfigPath $config -CheckOnly:$check *> $null")
                    .AddArgument(script).AddArgument(config).AddArgument(checkOnly);
                shell.Invoke();
                if (shell.HadErrors) throw new InvalidOperationException("Watchdog invocation failed.");
            }
            return 0;
        }
        catch (Exception error)
        {
            try
            {
                Directory.CreateDirectory(Path.Combine(root, "logs"));
                var now = DateTimeOffset.Now;
                string type = error.GetType().FullName.Replace("\\", "\\\\").Replace("\"", "\\\"");
                string record = "{\"Timestamp\":\"" + now.ToString("o") + "\",\"Level\":\"ERROR\",\"Event\":\"host_failure\","
                    + "\"Message\":\"Background host exited with an error.\",\"Data\":{\"ErrorType\":\"" + type + "\"}}";
                File.AppendAllText(Path.Combine(root, "logs", "watchdog-" + now.UtcDateTime.ToString("yyyyMMdd-HH") + ".jsonl"),
                    record + Environment.NewLine, new System.Text.UTF8Encoding(false));
            }
            catch { /* Preserve the nonzero exit code if logging itself is unavailable. */ }
            return 1;
        }
    }
}
