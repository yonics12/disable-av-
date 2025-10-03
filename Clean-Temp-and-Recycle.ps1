<#
    Clean Temp Files + Recycle Bin (Windows 10/11)

    What this script does:
    - Cleans the current user's TEMP folder (%TEMP%)
    - Cleans the system TEMP folder (C:\Windows\Temp)
    - Empties the Recycle Bin (C:\$Recycle.Bin, via Clear-RecycleBin when possible)
    - Shows free disk space before and after, plus how much space was freed
    - Skips files it cannot delete (no crashes, just polite skipping)
    - Lighthearted console messages to make cleanup less... dusty
    - Checks for Administrator privileges and warns if not elevated

    Note:
    - Some items may be in use and cannot be deleted; that's normal.
    - Running as Administrator is recommended for a thorough cleanup.
#>

#region Utility functions

function Test-IsAdmin {
    <#
        Returns $true if the current PowerShell session is running elevated (Administrator).
    #>
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p  = [Security.Principal.WindowsPrincipal]::new($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Format-Bytes {
    <#
        Converts a byte count into a human-friendly string (e.g., "2.34 GB").
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][double]$Bytes
    )
    $units = 'B','KB','MB','GB','TB','PB'
    $i = 0
    while ($Bytes -ge 1024 -and $i -lt ($units.Count - 1)) {
        $Bytes /= 1024
        $i++
    }
    '{0:N2} {1}' -f $Bytes, $units[$i]
}

function Get-FreeSpace {
    <#
        Gets free space (in bytes) for a given drive letter (default: C).
        Returns a PSCustomObject with Drive, FreeBytes, and Pretty string for display.
    #>
    [CmdletBinding()]
    param(
        [ValidatePattern('^[A-Za-z][:]?$')]
        [string]$Drive = 'C'
    )
    try {
        $dl = ($Drive.TrimEnd(':').ToUpper() + ':')
        $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$dl'" -ErrorAction Stop
        [pscustomobject]@{
            Drive     = $dl
            FreeBytes = [int64]$disk.FreeSpace
            Pretty    = (Format-Bytes -Bytes $disk.FreeSpace)
        }
    } catch {
        # Fallback using PSDrive if CIM fails (rare)
        $dl = ($Drive.TrimEnd(':').ToUpper())
        $psd = Get-PSDrive -Name $dl -ErrorAction SilentlyContinue
        if ($psd) {
            [pscustomobject]@{
                Drive     = ($dl + ':')
                FreeBytes = [int64]$psd.Free
                Pretty    = (Format-Bytes -Bytes $psd.Free)
            }
        } else {
            throw "Unable to determine free space for drive $Drive"
        }
    }
}

function Clear-Folder {
    <#
        Deletes the contents of a folder (not the folder itself).
        - Skips locked/in-use items without crashing.
        - Attempts to normalize attributes (read-only/system/hidden) before deletion.
        - Returns a stats object with items deleted, bytes removed, and error count.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,
        [switch]$VerboseOutput
    )

    $result = [pscustomobject]@{
        Path         = $Path
        FilesDeleted = 0
        DirsDeleted  = 0
        BytesRemoved = [int64]0
        Errors       = 0
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        if ($VerboseOutput) { Write-Host "Skipping '$Path' (does not exist)." -ForegroundColor DarkGray }
        return $result
    }

    # 1) Delete files first
    try {
        $files = Get-ChildItem -LiteralPath $Path -File -Force -Recurse -ErrorAction SilentlyContinue
        foreach ($file in $files) {
            try {
                # Normalize attributes to avoid access issues from ReadOnly/System/Hidden
                try {
                    Set-ItemProperty -LiteralPath $file.FullName -Name Attributes -Value ([IO.FileAttributes]::Normal) -ErrorAction SilentlyContinue
                } catch { }

                $size = [int64]$file.Length
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                $result.FilesDeleted++
                $result.BytesRemoved += $size

                if ($VerboseOutput) {
                    Write-Host "Deleted file: $($file.FullName)" -ForegroundColor DarkGray
                }
            } catch {
                $result.Errors++
                if ($VerboseOutput) {
                    Write-Host "Could not delete file: $($file.FullName) [$($_.Exception.Message)]" -ForegroundColor Yellow
                }
                continue
            }
        }
    } catch {
        $result.Errors++
        if ($VerboseOutput) { Write-Host "Error enumerating files in $Path: $($_.Exception.Message)" -ForegroundColor Yellow }
    }

    # 2) Then delete directories (deepest-first to avoid "directory not empty")
    try {
        $dirs = Get-ChildItem -LiteralPath $Path -Directory -Force -Recurse -ErrorAction SilentlyContinue | Sort-Object FullName -Descending
        foreach ($dir in $dirs) {
            try {
                # Normalize attributes for directories too
                try {
                    Set-ItemProperty -LiteralPath $dir.FullName -Name Attributes -Value ([IO.FileAttributes]::Normal) -ErrorAction SilentlyContinue
                } catch { }

                Remove-Item -LiteralPath $dir.FullName -Force -Recurse -ErrorAction Stop
                $result.DirsDeleted++

                if ($VerboseOutput) {
                    Write-Host "Removed folder: $($dir.FullName)" -ForegroundColor DarkGray
                }
            } catch {
                $result.Errors++
                if ($VerboseOutput) {
                    Write-Host "Could not remove folder: $($dir.FullName) [$($_.Exception.Message)]" -ForegroundColor Yellow
                }
                continue
            }
        }
    } catch {
        $result.Errors++
        if ($VerboseOutput) { Write-Host "Error enumerating folders in $Path: $($_.Exception.Message)" -ForegroundColor Yellow }
    }

    return $result
}

function Clear-RecycleBinSafe {
    <#
        Empties the Recycle Bin for the given drive.
        - Tries Clear-RecycleBin (no prompt), then falls back to deleting C:\$Recycle.Bin contents.
        - Returns a simple result object with Success and Errors count (deletion details are not enumerated).
    #>
    [CmdletBinding()]
    param(
        [ValidatePattern('^[A-Za-z][:]?$')][string]$Drive = 'C',
        [switch]$VerboseOutput
    )

    $result = [pscustomobject]@{
        Drive   = ($Drive.TrimEnd(':').ToUpper() + ':')
        Method  = $null
        Success = $false
        Errors  = 0
    }

    $letter = $Drive.TrimEnd(':').ToUpper()

    # 1) Prefer the Clear-RecycleBin cmdlet (quiet + reliable)
    try {
        $crb = Get-Command -Name Clear-RecycleBin -ErrorAction Stop
        if ($crb) {
            if ($VerboseOutput) { Write-Host "Emptying Recycle Bin on $letter: via Clear-RecycleBin..." -ForegroundColor Cyan }
            Clear-RecycleBin -DriveLetter $letter -Force -ErrorAction Stop | Out-Null
            $result.Method  = 'Clear-RecycleBin'
            $result.Success = $true
            return $result
        }
    } catch {
        # Fall through to manual approach
        if ($VerboseOutput) { Write-Host "Clear-RecycleBin not available or failed, trying manual cleanup..." -ForegroundColor Yellow }
    }

    # 2) Manual fallback: delete contents of C:\$Recycle.Bin
    $rbPath = "$letter`:\$Recycle.Bin"
    if (Test-Path -LiteralPath $rbPath) {
        try {
            # Remove contents but not the $Recycle.Bin folder itself
            if ($VerboseOutput) { Write-Host "Emptying Recycle Bin on $letter: via manual removal..." -ForegroundColor Cyan }
            Remove-Item -LiteralPath (Join-Path $rbPath '*') -Recurse -Force -ErrorAction Stop
            $result.Method  = 'ManualRemove'
            $result.Success = $true
        } catch {
            $result.Errors++
            if ($VerboseOutput) {
                Write-Host "Could not empty Recycle Bin on $letter: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    } else {
        if ($VerboseOutput) { Write-Host "Recycle Bin folder not found at $rbPath (nothing to do)." -ForegroundColor DarkGray }
        $result.Success = $true
        $result.Method  = 'NotFound'
    }

    return $result
}

#endregion

#region Header + Admin check

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Temp + Recycle Bin Cleanup (Windows 10/11) " -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

$admin = Test-IsAdmin
if ($admin) {
    Write-Host "Running as Administrator: maximum decluttering power engaged. 🚀" -ForegroundColor Green
} else {
    Write-Host "Heads up: Not running as Administrator." -ForegroundColor Yellow
    Write-Host "I'll still do my best, but some stubborn files (like in C:\Windows\Temp) may resist." -ForegroundColor Yellow
    Write-Host "Tip: Right-click PowerShell and select 'Run as administrator' for the most thorough clean." -ForegroundColor DarkGray
}
Write-Host ""

#endregion

#region Pre/post space measurement

# We focus on C: since the target folders live on C:
$drive = 'C'
$before = Get-FreeSpace -Drive $drive
Write-Host "Free space before cleanup on $($before.Drive): $($before.Pretty)" -ForegroundColor Gray
Write-Host "Time to take out the digital trash... 🧹" -ForegroundColor Cyan
Write-Host ""

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

#endregion

#region Cleanup operations

# 1) Current user's TEMP
$userTemp = $env:TEMP
Write-Host "Cleaning your TEMP folder: $userTemp" -ForegroundColor Cyan
$userTempResult = Clear-Folder -Path $userTemp -VerboseOutput
Write-Host "  Removed $($userTempResult.FilesDeleted) files and $($userTempResult.DirsDeleted) folders ($((Format-Bytes $userTempResult.BytesRemoved))) from your TEMP." -ForegroundColor DarkGray
if ($userTempResult.Errors -gt 0) {
    Write-Host "  Skipped $($userTempResult.Errors) items that didn't want to leave (totally normal)." -ForegroundColor Yellow
}
Write-Host ""

# 2) System TEMP (requires admin for best results)
$systemTemp = 'C:\Windows\Temp'
Write-Host "Cleaning system TEMP folder: $systemTemp" -ForegroundColor Cyan
$sysTempResult = Clear-Folder -Path $systemTemp -VerboseOutput
Write-Host "  Removed $($sysTempResult.FilesDeleted) files and $($sysTempResult.DirsDeleted) folders ($((Format-Bytes $sysTempResult.BytesRemoved))) from system TEMP." -ForegroundColor DarkGray
if ($sysTempResult.Errors -gt 0) {
    Write-Host "  Skipped $($sysTempResult.Errors) items (likely in use by Windows). We let sleeping files lie." -ForegroundColor Yellow
}
Write-Host ""

# 3) Recycle Bin (C:)
Write-Host "Emptying the Recycle Bin on C: (goodbye, digital skeletons) 🗑️" -ForegroundColor Cyan
$recycleResult = Clear-RecycleBinSafe -Drive 'C' -VerboseOutput
if ($recycleResult.Success) {
    Write-Host "  Recycle Bin emptied via $($recycleResult.Method)." -ForegroundColor DarkGray
} else {
    Write-Host "  Could not fully empty the Recycle Bin (some items may be protected or in use)." -ForegroundColor Yellow
}
Write-Host ""

#endregion

#region Final report

$stopwatch.Stop()
$after = Get-FreeSpace -Drive $drive

$freedBytes = [int64]($after.FreeBytes - $before.FreeBytes)
$freedText  = Format-Bytes -Bytes ([math]::Abs($freedBytes))

Write-Host "---------------------------------------------" -ForegroundColor Cyan
Write-Host " Cleanup finished in $([math]::Round($stopwatch.Elapsed.TotalSeconds,2)) seconds." -ForegroundColor Cyan
Write-Host " Free space before: $($before.Pretty)" -ForegroundColor Gray
Write-Host " Free space after : $($after.Pretty)" -ForegroundColor Gray

if ($freedBytes -gt 0) {
    Write-Host " Freed up       : $freedText 🎉 Your PC feels lighter already!" -ForegroundColor Green
} elseif ($freedBytes -eq 0) {
    Write-Host " Freed up       : 0 B — it was just digital dusting. ✨" -ForegroundColor Yellow
} else {
    # This can happen if other processes wrote data during cleanup. Be honest and lighthearted.
    Write-Host " Freed up       : 0 B (net change went the other way due to other activity). Consider me your tidy sidekick anyway. 😇" -ForegroundColor Yellow
}
Write-Host "---------------------------------------------" -ForegroundColor Cyan
Write-Host ""

#endregion
