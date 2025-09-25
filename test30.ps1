param(
    [string]$SourceDriveLetter = "P",                 # drive where current Profiles partition is mounted
    [string]$ThawspaceRoot     = "T:\userprofiles"    # destination thawspace path (WILL BE CLEARED)
)

function Assert-Admin {
    if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Error "Run this script as Administrator."
        exit 1
    }
}

function Get-CurrentProfilesRootFromRegistry {
    $reg = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
    $profilesDir = (Get-ItemProperty $reg -ErrorAction Stop).ProfilesDirectory
    if (-not $profilesDir) { throw "Cannot detect ProfilesDirectory in registry." }
    return [Environment]::ExpandEnvironmentVariables($profilesDir)
}

function Get-FolderSizeBytes {
    param($path)
    try {
        $size = (Get-ChildItem -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue |
                 Measure-Object -Property Length -Sum).Sum
        if ($null -eq $size) { $size = 0 }
        return [int64]$size
    } catch { return 0 }
}

function BytesToGB([long]$b) { [math]::Round($b / 1GB, 2) }

function Ensure-EmptyThawspace {
    param($path)

    Write-Output "Preparing thawspace: $path"

    # Create root if missing
    if (-not (Test-Path -LiteralPath $path)) {
        try {
            New-Item -Path $path -ItemType Directory -Force | Out-Null
        } catch {
            throw "Failed creating thawspace root ${path}: $_"
        }
    }

    # First attempt: take ownership and set ACLs (only for local/mapped drives)
    if ($path -match '^[A-Za-z]:') {
        Write-Output "Taking ownership and granting Administrators full control on ${path} (this may require admin privileges)."
        try {
            & takeown.exe /F $path /R /A /D Y | Out-Null
        } catch {
            Write-Warning "takeown.exe reported an error (continuing): $_"
        }
        try {
            & icacls.exe $path /grant Administrators:F /T /C | Out-Null
        } catch {
            Write-Warning "icacls.exe reported an error (continuing): $_"
        }
    } else {
        Write-Output "Path does not look like a local drive root; skipping takeown/icacls step."
    }

    # Robust delete via robocopy mirror of an empty folder:
    $tempEmpty = Join-Path $env:TEMP ("empty_thawspace_{0}" -f ([guid]::NewGuid().ToString()))
    New-Item -Path $tempEmpty -ItemType Directory -Force | Out-Null

    Write-Output "Mirroring empty folder to $path using robocopy to forcibly remove contents..."
    $robocopyArgs = @($tempEmpty, $path, "/MIR", "/NFL", "/NDL", "/NJH", "/NJS", "/R:2", "/W:1")
    $proc = Start-Process -FilePath "robocopy" -ArgumentList $robocopyArgs -NoNewWindow -Wait -PassThru
    $rc = $proc.ExitCode
    # Robocopy exit codes: treat 0-7 as success-ish; >=8 as failure.
    if ($rc -ge 8) {
        Remove-Item -LiteralPath $tempEmpty -Recurse -Force -ErrorAction SilentlyContinue
        throw "Robocopy mirror failed with exit code $rc. Thawspace may not be cleared."
    }

    # Remove the empty temp dir
    Remove-Item -LiteralPath $tempEmpty -Recurse -Force -ErrorAction SilentlyContinue

    # final check - ensure directory is empty
    $contents = Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue
    if ($contents.Count -gt 0) {
        # try a last-ditch Remove-Item
        try {
            Get-ChildItem -LiteralPath $path -Force | Remove-Item -Recurse -Force -ErrorAction Stop
        } catch {
            throw "Thawspace not empty after attempts to clear it. Manual intervention required: $_"
        }
    }
    Write-Output "Thawspace $path cleared."
}

function Copy-Profiles {
    param($sourceRoot, $destRoot, [ref]$skipped, [ref]$failures)

    $folders = Get-ChildItem -LiteralPath $sourceRoot -Directory -Force -ErrorAction Stop | Where-Object {
        $_.Name -notin @('All Users') -and $_.Attributes -notmatch 'ReparsePoint'
    }

    if ($folders.Count -eq 0) {
        throw "No profile folders found under $sourceRoot"
    }

    foreach ($folder in $folders) {
        $src = $folder.FullName
        $dst = Join-Path $destRoot $folder.Name

        # Check for loaded profile (NTUSER.DAT locked)
        $ntuser = Join-Path $src "NTUSER.DAT"
        $isLoaded = $false
        if (Test-Path -LiteralPath $ntuser) {
            try {
                $h = [System.IO.File]::Open($ntuser,'Open','Read','None'); $h.Close()
            } catch {
                $isLoaded = $true
            }
        }

        if ($isLoaded) {
            Write-Warning "Skipping $($folder.Name) - profile in use."
            $skipped.Value += $folder.Name
            continue
        }

        Write-Output "Copying $($folder.Name) -> $dst"
        $robocopyArgs = @($src, $dst, "/MIR", "/COPYALL", "/R:3", "/W:5", "/XJ", "/NFL", "/NDL")
        $proc = Start-Process -FilePath "robocopy" -ArgumentList $robocopyArgs -NoNewWindow -Wait -PassThru
        if ($proc.ExitCode -ge 8) {
            Write-Warning "Robocopy failed for $($folder.Name) with exit code $($proc.ExitCode)"
            $failures.Value += $folder.Name
        }
    }
}

function Update-RegistryProfilePaths {
    param($oldRoot, $newRoot)

    $regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
    foreach ($sub in Get-ChildItem -Path $regPath) {
        $p = Get-ItemProperty -Path $sub.PSPath -ErrorAction SilentlyContinue
        if ($p -and $p.ProfileImagePath -and ($p.ProfileImagePath -like "$oldRoot*")) {
            $user = Split-Path $p.ProfileImagePath -Leaf
            $newPath = Join-Path $newRoot $user
            Set-ItemProperty -Path $sub.PSPath -Name ProfileImagePath -Value $newPath
            Write-Output "Updated registry for $user -> $newPath"
        } else {
            Write-Output "Skipping registry entry $($sub.PSChildName) (ProfileImagePath not under $oldRoot)"
        }
    }

    # Update Default, Public and ProfilesDirectory under HKLM\...\CurrentVersion
    $cvKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
    Set-ItemProperty -Path $cvKey -Name "Default" -Value (Join-Path $newRoot "Default")
    Set-ItemProperty -Path $cvKey -Name "Public"  -Value (Join-Path $newRoot "Public")
    Set-ItemProperty -Path $cvKey -Name "ProfilesDirectory" -Value $newRoot
    Write-Output "Updated Default/Public/ProfilesDirectory in $cvKey"
}

# ---- Main ----
Assert-Admin

Write-Output "SourceDriveLetter: ${SourceDriveLetter}; ThawspaceRoot: ${ThawspaceRoot}"

# Validate source drive
if (-not (Get-PSDrive -Name $SourceDriveLetter -ErrorAction SilentlyContinue)) {
    Write-Error "Source drive ${SourceDriveLetter}:\ not present. Aborting."
    exit 1
}

# Get profiles root from registry
try {
    $profilesRoot = Get-CurrentProfilesRootFromRegistry
} catch {
    Write-Error "Cannot read ProfilesDirectory from registry: $_"
    exit 1
}
Write-Output "Detected ProfilesDirectory (registry): $profilesRoot"

# If registry path not under source drive, fallback to ${SourceDriveLetter}:\Users
if ($profilesRoot -notlike "${SourceDriveLetter}:*") {
    $fallback = "${SourceDriveLetter}:\Users"
    if (Test-Path -LiteralPath $fallback) {
        Write-Warning "Registry ProfilesDirectory ($profilesRoot) not under ${SourceDriveLetter}:. Falling back to $fallback"
        $profilesRoot = $fallback
    } else {
        Write-Warning "Registry ProfilesDirectory not under ${SourceDriveLetter}: and fallback $fallback missing. Continuing with registry path."
    }
}

# Ensure no profile is in use
$profileFolders = Get-ChildItem -LiteralPath $profilesRoot -Directory -Force -ErrorAction Stop | Where-Object {
    $_.Name -notin @('All Users') -and $_.Attributes -notmatch 'ReparsePoint'
}
$loaded = @()
foreach ($f in $profileFolders) {
    $ntuser = Join-Path $f.FullName "NTUSER.DAT"
    if (Test-Path -LiteralPath $ntuser) {
        try {
            $h = [System.IO.File]::Open($ntuser,'Open','Read','None'); $h.Close()
        } catch {
            $loaded += $f.Name
        }
    }
}
if ($loaded.Count -gt 0) {
    Write-Error "Profiles currently in use (NTUSER.DAT locked): $($loaded -join ', '). Please ensure no users are logged in and re-run."
    exit 1
}

# Ensure thawspace root can be reached
$thawDrive = Split-Path -Path $ThawspaceRoot -Qualifier
if (-not (Test-Path -LiteralPath $thawDrive)) {
    Write-Error "Thawspace drive $thawDrive not available. Aborting."
    exit 1
}

# Clear thawspace
try {
    Ensure-EmptyThawspace -path $ThawspaceRoot
} catch {
    Write-Error "Failed to clear thawspace ${ThawspaceRoot}: $_"
    exit 1
}

# Copy profiles
$skipped = New-Object System.Collections.ArrayList
$failures = New-Object System.Collections.ArrayList
Copy-Profiles -sourceRoot $profilesRoot -destRoot $ThawspaceRoot -skipped ([ref]$skipped) -failures ([ref]$failures)

if ($failures.Count -gt 0) {
    Write-Error "Some profile copies failed: $($failures -join ', '). Aborting before registry change."
    exit 1
}

# Validate sizes (tolerance 1MB)
$sizeMismatches = @()
foreach ($f in $profileFolders) {
    $srcSize = Get-FolderSizeBytes -path $f.FullName
    $dstFolder = Join-Path $ThawspaceRoot $f.Name
    $dstSize = Get-FolderSizeBytes -path $dstFolder
    if ([math]::Abs($srcSize - $dstSize) -gt 1MB) {
        Write-Warning "Size mismatch for $($f.Name): source $(BytesToGB $srcSize) GB vs dest $(BytesToGB $dstSize) GB"
        $sizeMismatches += $f.Name
    }
}
if ($sizeMismatches.Count -gt 0) {
    Write-Error "Size mismatches detected for: $($sizeMismatches -join ', '). Aborting to avoid registry corruption."
    exit 1
}

# Enforce reasonable ACLs on thawspace root (Administrators & SYSTEM full, Users modify)
try {
    & icacls.exe $ThawspaceRoot /inheritance:r | Out-Null
    & icacls.exe $ThawspaceRoot /grant:r "Administrators:(OI)(CI)F" "SYSTEM:(OI)(CI)F" "Users:(OI)(CI)M" /T | Out-Null
} catch {
    Write-Warning "Failed to apply ACLs to ${ThawspaceRoot}: $_ (you may need to review permissions manually)"
}

# Backup registry ProfileList
try {
    $exportFile = Join-Path $env:TEMP ("ProfileList_backup_{0}.reg" -f (Get-Date -Format yyyyMMddHHmmss))
    reg export "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" $exportFile /y | Out-Null
    Write-Output "Exported ProfileList registry key to $exportFile"
} catch {
    Write-Warning "Failed to export ProfileList registry key: $_"
}

# Update registry to point at thawspace
try {
    Update-RegistryProfilePaths -oldRoot $profilesRoot -newRoot $ThawspaceRoot
} catch {
    Write-Error "Failed updating registry: $_"
    exit 1
}

# Final verification: all registry ProfileImagePath entries must exist on disk
$missing = @()
$regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
foreach ($sub in Get-ChildItem -Path $regPath) {
    $p = Get-ItemProperty -Path $sub.PSPath -ErrorAction SilentlyContinue
    if ($p -and $p.ProfileImagePath) {
        if (-not (Test-Path -LiteralPath $p.ProfileImagePath)) {
            $missing += $p.ProfileImagePath
            Write-Warning "Registry points to missing path: $($p.ProfileImagePath)"
        }
    }
}
if ($missing.Count -gt 0) {
    Write-Error "Registry references profile folders that do not exist on thawspace. Aborting before removing source partition."
    exit 1
}

# Remove source partition and expand C:
try {
    Write-Output "Attempting to remove source partition ${SourceDriveLetter}:\ and expand C: to reclaim space..."
    $srcPart = Get-Partition -DriveLetter $SourceDriveLetter -ErrorAction Stop
    Remove-Partition -DiskNumber $srcPart.DiskNumber -PartitionNumber $srcPart.PartitionNumber -Confirm:$false -ErrorAction Stop
    Start-Sleep -Seconds 2

    $cPart = Get-Partition -DriveLetter C -ErrorAction Stop
    $supported = Get-PartitionSupportedSize -DriveLetter C
    Resize-Partition -DiskNumber $cPart.DiskNumber -PartitionNumber $cPart.PartitionNumber -Size $supported.SizeMax -ErrorAction Stop
    Write-Output "Removed ${SourceDriveLetter}: partition and expanded C: (if supported)."
} catch {
    Write-Warning "Failed to remove ${SourceDriveLetter}: partition or expand C:. Manual intervention may be required: $_"
}

Write-Output "Operation completed successfully. Reboot the machine to ensure Windows loads profiles from ${ThawspaceRoot}."
