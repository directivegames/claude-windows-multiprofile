<#
.SYNOPSIS
    Keeps Claude profile windows named and grouped separately on the taskbar.
.PARAMETER ValidateOnly
    Compile the Windows helper without inspecting or changing windows.
.PARAMETER Once
    Update currently running windows once, then exit.
#>
[CmdletBinding()]
param([switch]$ValidateOnly, [switch]$Once)
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
namespace ClaudeProfileLabels {
    [StructLayout(LayoutKind.Sequential)]
    public struct PropertyKey {
        public Guid Format;
        public uint Id;
        public PropertyKey(uint id) {
            Format = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"); Id = id;
        }
    }
    [StructLayout(LayoutKind.Explicit, Size = 24)]
    public struct PropVariant {
        [FieldOffset(0)] public ushort Type;
        [FieldOffset(8)] public IntPtr Value;
    }
    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPropertyStore {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int GetAt(uint index, out PropertyKey key);
        [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
        [PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant value);
        [PreserveSig] int Commit();
    }
    public static class Windows {
        private delegate bool EnumCallback(IntPtr hwnd, IntPtr data);
        [DllImport("user32.dll")] private static extern bool EnumWindows(EnumCallback callback, IntPtr data);
        [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hwnd);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
        [DllImport("user32.dll")] private static extern IntPtr GetWindow(IntPtr hwnd, uint command);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetClassName(IntPtr hwnd, StringBuilder name, int size);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int size);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr SendMessageTimeout(IntPtr hwnd, uint msg, IntPtr wparam,
            string text, uint flags, uint timeout, out UIntPtr result);
        [DllImport("shell32.dll", PreserveSig = true)]
        private static extern int SHGetPropertyStoreForWindow(IntPtr hwnd, ref Guid iid,
            [MarshalAs(UnmanagedType.Interface)] out IPropertyStore store);
        [DllImport("ole32.dll")] private static extern int PropVariantClear(ref PropVariant value);
        private static void Put(IPropertyStore store, uint id, string text) {
            PropertyKey key = new PropertyKey(id);
            PropVariant value = new PropVariant();
            value.Type = 31; // VT_LPWSTR
            value.Value = Marshal.StringToCoTaskMemUni(text);
            try { Marshal.ThrowExceptionForHR(store.SetValue(ref key, ref value)); }
            finally { PropVariantClear(ref value); }
        }
        private static string Read(IPropertyStore store, uint id) {
            PropertyKey key = new PropertyKey(id);
            PropVariant value;
            Marshal.ThrowExceptionForHR(store.GetValue(ref key, out value));
            try { return value.Type == 31 ? Marshal.PtrToStringUni(value.Value) : null; }
            finally { PropVariantClear(ref value); }
        }
        public static IntPtr[] Find(uint processId) {
            List<IntPtr> windows = new List<IntPtr>();
            EnumWindows(delegate(IntPtr hwnd, IntPtr data) {
                uint pid;
                GetWindowThreadProcessId(hwnd, out pid);
                if (pid == processId && IsWindowVisible(hwnd) && GetWindow(hwnd, 4) == IntPtr.Zero) {
                    StringBuilder name = new StringBuilder(256);
                    GetClassName(hwnd, name, name.Capacity);
                    if (name.ToString().StartsWith("Chrome_WidgetWin_")) windows.Add(hwnd);
                }
                return true;
            }, IntPtr.Zero);
            return windows.ToArray();
        }
        public static void Label(IntPtr hwnd, string title, string appId, string relaunch, string icon) {
            StringBuilder current = new StringBuilder(2048);
            GetWindowText(hwnd, current, current.Capacity);
            if (current.ToString() != title) {
                UIntPtr result;
                if (SendMessageTimeout(hwnd, 0x000C, IntPtr.Zero, title, 0x22, 500, out result) == IntPtr.Zero)
                    throw new InvalidOperationException("Could not update the Claude window title.");
            }
            Guid iid = typeof(IPropertyStore).GUID;
            IPropertyStore store;
            Marshal.ThrowExceptionForHR(SHGetPropertyStoreForWindow(hwnd, ref iid, out store));
            try {
                if (Read(store, 5) != appId || Read(store, 4) != title || Read(store, 2) != relaunch) {
                    Put(store, 2, relaunch);
                    Put(store, 4, title);
                    if (!String.IsNullOrEmpty(icon)) Put(store, 3, icon);
                    Put(store, 5, appId);
                    Marshal.ThrowExceptionForHR(store.Commit());
                }
            } finally { Marshal.ReleaseComObject(store); }
        }
    }
}
'@
if ($ValidateOnly) { Write-Output 'Windows helper compiled successfully.'; return }

$mapPath = Join-Path $PSScriptRoot 'profiles.json'
if (-not (Test-Path -LiteralPath $mapPath)) { throw "Missing profile map: $mapPath. Run Setup.ps1 first." }
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$mutex = New-Object Threading.Mutex($false, "Local\ClaudeProfileTaskbarLabels-$sid")
$ownsMutex = $false
try {
    try { $ownsMutex = $mutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) { return }
    $lastSeen = Get-Date
    do {
        $cfg = Get-Content -LiteralPath $mapPath -Raw | ConvertFrom-Json
        $processes = @(Get-CimInstance Win32_Process -Filter "Name='Claude.exe'" |
            Where-Object { $_.CommandLine -and $_.CommandLine -notmatch '(?:^|\s)--type=' })
        $matched = 0
        foreach ($proc in $processes) {
            $dataPath = Join-Path $env:APPDATA 'Claude'
            if ($proc.CommandLine -match '(?:^|\s)--user-data-dir(?:=|\s+)(?:"([^"]+)"|([^\s]+))') {
                $dataPath = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
            }
            $profile = $cfg.profiles.PSObject.Properties | Where-Object {
                $_.Value.dataDir.TrimEnd('\') -ieq $dataPath.TrimEnd('\')
            } | Select-Object -First 1
            if (-not $profile) { continue }
            $matched++
            $name = $profile.Name
            $title = "Claude ($name)"
            $sha = [Security.Cryptography.SHA256]::Create()
            try {
                $bytes = [Text.Encoding]::UTF8.GetBytes($dataPath.TrimEnd('\').ToLowerInvariant())
                $hash = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').Substring(0, 24)
            } finally { $sha.Dispose() }
            $appId = "Claude.MultiProfile.$hash"
            $vbs = Join-Path $PSScriptRoot 'launch.vbs'
            $relaunch = '"{0}" "{1}" "{2}"' -f (Join-Path $env:WINDIR 'System32\wscript.exe'), $vbs, $dataPath
            if ($profile.Value.configDir) { $relaunch += ' "{0}"' -f $profile.Value.configDir }
            $iconPath = Join-Path $PSScriptRoot 'claude.ico'
            $icon = if (Test-Path -LiteralPath $iconPath) { "$iconPath,0" } else { '' }
            foreach ($hwnd in [ClaudeProfileLabels.Windows]::Find([uint32]$proc.ProcessId)) {
                try {
                    [ClaudeProfileLabels.Windows]::Label($hwnd, $title, $appId, $relaunch, $icon)
                    if ($Once) { Write-Output "Labeled window: $title" }
                } catch { Write-Warning "${title}: $($_.Exception.Message)" }
            }
        }
        if ($matched -gt 0) { $lastSeen = Get-Date }
        if (-not $Once) { Start-Sleep -Seconds 3 }
    } while (-not $Once -and ((Get-Date) - $lastSeen).TotalSeconds -lt 30)
} finally {
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
