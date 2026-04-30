# 64 位系统上 32 位 powershell 的 ProgramFiles 可能指向 (x86)；优先 ProgramW6432 指向原生 Program Files
function Get-ProgramFilesNodeInstallRoot {
    [CmdletBinding()]
    param()
    $root = $env:ProgramFiles
    if (-not [string]::IsNullOrEmpty($env:ProgramW6432)) {
        $root = $env:ProgramW6432
    }
    return $root
}

# 广播 WM_SETTINGCHANGE，使新进程尽早读到更新后的 Machine/User 环境变量（当前会话 PATH 仍可能为缓存）
function Send-EnvironmentChangeBroadcast {
    [CmdletBinding()]
    param()
    # 多次点载时避免重复 Add-Type 报错
    if (-not ('OpenClawInstaller.NativeMethods' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace OpenClawInstaller {
public static class NativeMethods {
    [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd,
        uint Msg,
        UIntPtr wParam,
        string lParam,
        uint fuFlags,
        uint uTimeout,
        out UIntPtr lpdwResult);
}
}
"@ -ErrorAction Stop
    }

    $HWND_BROADCAST = [IntPtr]0xffff
    $WM_SETTINGCHANGE = 0x001A
    $SMTO_ABORTIFHUNG = 0x0002
    $result = [UIntPtr]::Zero
    [void][OpenClawInstaller.NativeMethods]::SendMessageTimeout(
        $HWND_BROADCAST,
        $WM_SETTINGCHANGE,
        [UIntPtr]::Zero,
        "Environment",
        $SMTO_ABORTIFHUNG,
        5000,
        [ref]$result
    )
}

# PATH 追加幂等（忽略尾部 \ 与大小写差异）
function Add-PathEntryIfMissing {
    [CmdletBinding()]
    param(
        [ValidateSet("Machine", "User")]
        [string]$Scope,
        [Parameter(Mandatory = $true)]
        [string]$Entry
    )

    $current = [Environment]::GetEnvironmentVariable("Path", $Scope)
    $parts = @()
    if (-not [string]::IsNullOrWhiteSpace($current)) {
        $parts = $current -split ";" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    }

    $normalized = $parts | ForEach-Object { $_.TrimEnd("\").ToLowerInvariant() }
    $target = $Entry.TrimEnd("\")
    if ($normalized -notcontains $target.ToLowerInvariant()) {
        $parts += $Entry
        [Environment]::SetEnvironmentVariable("Path", ($parts -join ";"), $Scope)
    }
}

# 卸载时按规范化路径从 PATH 移除（与 Add-PathEntryIfMissing 规则一致）
function Remove-PathEntryIfExists {
    [CmdletBinding()]
    param(
        [ValidateSet("Machine", "User")]
        [string]$Scope,
        [Parameter(Mandatory = $true)]
        [string]$Entry
    )

    $current = [Environment]::GetEnvironmentVariable("Path", $Scope)
    if ([string]::IsNullOrWhiteSpace($current)) {
        return
    }

    $entryNormalized = $Entry.TrimEnd("\").ToLowerInvariant()
    $parts = $current -split ";" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $filtered = @()
    foreach ($part in $parts) {
        if ($part.TrimEnd("\").ToLowerInvariant() -ne $entryNormalized) {
            $filtered += $part
        }
    }

    [Environment]::SetEnvironmentVariable("Path", ($filtered -join ";"), $Scope)
}
