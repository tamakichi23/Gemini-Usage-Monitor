using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using Microsoft.Win32;

[assembly: AssemblyTitle("Gemini Usage Monitor")]
[assembly: AssemblyDescription("Independent Gemini usage monitor with a Windows taskbar display")]
[assembly: AssemblyCompany("Tamakichi23")]
[assembly: AssemblyProduct("Gemini Usage Monitor")]
[assembly: AssemblyVersion("0.1.11.0")]
[assembly: AssemblyFileVersion("0.1.11.0")]

internal static class GeminiUsageAddon
{
    private static int Main(string[] args)
    {
        if (args.Length > 0 && String.Equals(args[0], "--cleanup-legacy-registration", StringComparison.OrdinalIgnoreCase))
        {
            RemoveLegacyRegistration();
            return 0;
        }

        string installRoot = AppDomain.CurrentDomain.BaseDirectory;
        bool uninstall = args.Length > 0 && String.Equals(args[0], "--uninstall", StringComparison.OrdinalIgnoreCase);
        string scriptName = uninstall ? "uninstall-gemini-addon.ps1" : "start-gemini-addon.ps1";
        string scriptPath = Path.Combine(installRoot, scriptName);
        if (!File.Exists(scriptPath))
        {
            return 2;
        }

        string systemRoot = Environment.GetFolderPath(Environment.SpecialFolder.System);
        string powershellPath = Path.Combine(systemRoot, "WindowsPowerShell\\v1.0\\powershell.exe");
        if (!File.Exists(powershellPath))
        {
            return 3;
        }

        StringBuilder commandLine = new StringBuilder();
        commandLine.Append("-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ");
        commandLine.Append(QuoteArgument(scriptPath));
        if (!uninstall)
        {
            for (int index = 0; index < args.Length; index++)
            {
                commandLine.Append(' ');
                commandLine.Append(QuoteArgument(args[index]));
            }
        }

        ProcessStartInfo startInfo = new ProcessStartInfo();
        startInfo.FileName = powershellPath;
        startInfo.Arguments = commandLine.ToString();
        startInfo.WorkingDirectory = installRoot;
        startInfo.UseShellExecute = false;
        startInfo.CreateNoWindow = true;
        startInfo.WindowStyle = ProcessWindowStyle.Hidden;

        try
        {
            using (Process process = Process.Start(startInfo))
            {
                process.WaitForExit();
                return process.ExitCode;
            }
        }
        catch
        {
            return 4;
        }
    }

    private static void RemoveLegacyRegistration()
    {
        RegistryView[] views = new RegistryView[] { RegistryView.Registry64, RegistryView.Registry32 };
        foreach (RegistryView view in views)
        {
            using (RegistryKey userHive = RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, view))
            {
                using (RegistryKey uninstallKey = userHive.OpenSubKey("Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall", true))
                {
                    if (uninstallKey == null)
                    {
                        continue;
                    }

                    using (RegistryKey legacyEntry = uninstallKey.OpenSubKey("GeminiUsageAddon"))
                    {
                        if (legacyEntry != null)
                        {
                            legacyEntry.Close();
                            uninstallKey.DeleteSubKeyTree("GeminiUsageAddon");
                        }
                    }
                }
            }
        }
    }

    private static string QuoteArgument(string value)
    {
        StringBuilder result = new StringBuilder();
        result.Append('"');
        int backslashes = 0;
        for (int index = 0; index < value.Length; index++)
        {
            char character = value[index];
            if (character == '\\')
            {
                backslashes++;
            }
            else if (character == '"')
            {
                result.Append('\\', backslashes * 2 + 1);
                result.Append('"');
                backslashes = 0;
            }
            else
            {
                result.Append('\\', backslashes);
                result.Append(character);
                backslashes = 0;
            }
        }
        result.Append('\\', backslashes * 2);
        result.Append('"');
        return result.ToString();
    }
}
