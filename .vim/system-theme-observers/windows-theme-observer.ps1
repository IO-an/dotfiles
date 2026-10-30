$ErrorActionPreference = 'Stop'

# Waits on a real Windows registry notification; no polling loop is used.
$source = @'
using System;
using System.Runtime.InteropServices;

public static class VimSystemThemeRegistryObserver
{
    private static readonly IntPtr HKEY_CURRENT_USER =
        new IntPtr(unchecked((int)0x80000001));
    private const int KEY_NOTIFY = 0x0010;
    private const uint REG_NOTIFY_CHANGE_LAST_SET = 0x00000004;
    private const string SUBKEY = @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int RegOpenKeyEx(
        IntPtr hKey, string subKey, uint options, int desiredAccess, out IntPtr result);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern int RegNotifyChangeKeyValue(
        IntPtr hKey, bool watchSubtree, uint notifyFilter, IntPtr eventHandle, bool asynchronous);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern int RegCloseKey(IntPtr hKey);

    public static void Run()
    {
        IntPtr key;
        int result = RegOpenKeyEx(HKEY_CURRENT_USER, SUBKEY, 0, KEY_NOTIFY, out key);
        if (result != 0)
            throw new InvalidOperationException("RegOpenKeyEx failed with code " + result);

        try
        {
            while (true)
            {
                result = RegNotifyChangeKeyValue(
                    key, false, REG_NOTIFY_CHANGE_LAST_SET, IntPtr.Zero, false);
                if (result != 0)
                    throw new InvalidOperationException("RegNotifyChangeKeyValue failed with code " + result);

                Console.WriteLine("changed");
                Console.Out.Flush();
            }
        }
        finally
        {
            RegCloseKey(key);
        }
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp
[VimSystemThemeRegistryObserver]::Run()
