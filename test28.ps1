<#
.SYNOPSIS
  Copy profiles from a Profiles partition (e.g. P:\Users) to thawspace (e.g. T:\userprofiles),
  update registry to point to thawspace, remove the Profiles partition and expand C:.

.NOTES
  - Destructive: will remove all contents under $ThawspaceRoot before copying.
  - Aborts if any profile in the source is currently loaded (NTUSER.DAT locked).
  - Must be run elevated (Administrator).
  - Test on a single machine before broad deployment. Take a snapshot.

.PARAMETER SourceDriveLetter
  Drive letter where current Profiles partition is mounted (default 'P').

.PARAMETER ThawspaceRoot
  Full path on thawspace where profiles should be copied (e.g. 'T:\userprofiles').
#>

param(
    [string]$SourceDriveLetter = "P",                 # drive where Profiles partition currently mounted
    [string]$ThawspaceRoot = "T:\userprofiles"        # target thawspace path (will be cleared)
)

function Assert-Admin {
    if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
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

# ===== Begin =====
Assert-Admin

Write-Output "SourceDriveLetter: $SourceDriveLetter; ThawspaceRoot: $ThawspaceRoot"
if (-not (Test-Path "$($SourceDriveLetter):\")) {
    Write-Error "Source drive $SourceDriveLetter:`\ not present. Aborting."
    exit 1
}

# Determine source profiles root (usually P:\Users or whatever ProfilesDirectory returns)
try {
    $currentProfilesRoot = Get-CurrentProfilesRootFromRegistry
} catch {
    Write-Error "Failed to read ProfilesDirectory from registry: $_"
    exit 1
}
Write-Output "ProfilesDirectory (registry) currently: $currentProfilesRoot"

# Ensure sourceRoot exists and looks like it is on the specified source drive
$sourceRootPath = $currentProfilesRoot
if (-not (Test-Path $sourceRootPath)) {
    # fallback: if C:\Users moved to P:\Users then maybe directly use P:\Users
    $fallback = "$SourceDriveLetter`:\Users"
    if (Test-Path $fallback) {
        Write-Warning "Registry ProfilesDirectory ($sourceRootPath) not found. Falling back to $fallback"
        $sourceRootPath = $fallback
    } else {
        Write-Error "Source profiles folder not found at registry path or fallback $fallback. Aborting."
        exit 1
    }
}

# Safety: require that source path starts with the SourceDriveLetter
if ($sourceRootPath -notlike ("$SourceDriveLetter`:*")) {
    Write-Warning "Registry ProfilesDirectory indicates path not on $SourceDriveLetter:`\ (it is '$sourceRootPath')."
    Write-Warning "Proceeding but you should confirm this is correct."
}

# Ensure ThawspaceRoot parent drive exists and is not the same as SourceDrive
$thawDrive = Split-Path -Path $ThawspaceRoot -Qualifier
if (-not (Test-Path $thawDrive)) {
    Write-Error "Thawspace drive $thawDrive not present. Aborting."
    exit 1
}
if ($thawDrive -ieq ("$SourceDriveLetter`:")) {
    Write-Error "Thawspace location is on the same drive letter as the source. Aborting to avoid accidental destructive operations."
    exit 1
}

# Gather list of profile folders in source
$profileFolders = Get-ChildItem -Path $sourceRootPath -Directory -Force | Where-Object {
    $_.Name -notin @('All Users') -and $_.Attributes -notmatch 'ReparsePoint'
}
if ($profileFolders.Count -eq 0) {
    Write-Warning "No profile folders found under $sourceRootPath. Aborting."
    exit 1
}

# Check for loaded profiles (NTUSER.DAT locked) — abort if any are in use
$loadedProfiles = @()
foreach ($f in $profileFolders) {
    $ntuser = Join-Path $f.FullName "NTUSER.DAT"
    if (Test-Path $ntuser) {
        try {
            $h = [System.IO.File]::Open($ntuser,'Open','Read','None')
            $h.Close()
        } catch {
            $loadedProfiles += $f.Name
        }
    }
}
if ($loadedProfiles.Count -gt 0) {
    Write-Error "The following profiles are currently in use (NTUSER.DAT locked): $($loadedProfiles -join ', ')"
    Write-Error "Please ensure no users are logged in and re-run the script (deploy to maintenance window). Aborting."
    exit 1
}

# Prepare thawspace root: CLEAR it (destructive)
Write-Output "Preparing thawspace root: $ThawspaceRoot"
if (Test-Path $ThawspaceRoot) {
    Write-Output "Clearing existing contents of $ThawspaceRoot (DESTRUCTIVE)..."
    try {
        # Remove contents only, keep root folder
        Get-ChildItem -LiteralPath $ThawspaceRoot -Force | Remove-Item -Recurse -Force -ErrorAction Stop
    } catch {
        Write-Error "Failed to clear $ThawspaceRoot: $_"
        exit 1
    }
} else {
    Write-Output "Creating $ThawspaceRoot..."
    try { New-Item -Path $ThawspaceRoot -ItemType Directory -Force | Out-Null } catch { Write-Error "Failed creating $ThawspaceRoot: $_"; exit 1 }
}

# Copy profiles from sourceRootPath -> ThawspaceRoot
Write-Output "Starting profile copy from $sourceRootPath to $ThawspaceRoot"
$skipped = @()
$copyFailures = @()
foreach ($folder in $profileFolders) {
    $src = $folder.FullName
    $dst = Join-Path $ThawspaceRoot $folder.Name

    Write-Output "Copying $($folder.Name) ..."
    # Use robocopy to preserve ACLs and attributes
    $robocopyArgs = @($src, $dst, "/MIR", "/COPYALL", "/R:3", "/W:5", "/XJ")
    $rc = Start-Process -FilePath robocopy -ArgumentList $robocopyArgs -Wait -NoNewWindow -PassThru
    # robocopy exit codes: 0/1 success, >1 indicates some issues; treat <=3 as tolerance but >3 as error in many cases.
    if ($rc.ExitCode -ge 8) {
        Write-Warning "Robocopy failed for $($folder.Name) with exit code $($rc.ExitCode)"
        $copyFailures += $folder.Name
    }
}

if ($copyFailures.Count -gt 0) {
    Write-Error "Some profiles failed to copy: $($copyFailures -join ', '). Aborting before registry change."
    exit 1
}

# Validate copied sizes (rough check)
Write-Output "Validating copied folder sizes..."
$sizeMismatch = @()
foreach ($folder in $profileFolders) {
    $srcSize = Get-FolderSizeBytes -path $folder.FullName
    $dstFolder = Join-Path $ThawspaceRoot $folder.Name
    $dstSize = Get-FolderSizeBytes -path $dstFolder
    if ($srcSize -ne $dstSize) {
        # Allow small differences; use tolerance of 1MB
        if ([math]::Abs($srcSize - $dstSize) -gt 1MB) {
            $sizeMismatch += $folder.Name
            Write-Warning "Size mismatch for $($folder.Name): source $(BytesToGB $srcSize) GB vs dest $(BytesToGB $dstSize) GB"
        }
    }
}
if ($sizeMismatch.Count -gt 0) {
    Write-Warning "Size mismatches detected for: $($sizeMismatch -join ', '). Please review. Proceeding to registry update is risky."
    # user may want to abort; for automation we'll abort to be safe
    Write-Error "Aborting due to size mismatches. Please investigate and retry."
    exit 1
}

# Ensure NTFS ACLs preserved; optionally enforce standard permissions
Write-Output "Applying recommended ACLs on $ThawspaceRoot (Administrators:F, SYSTEM:F, Users:M)"
try {
    icacls $ThawspaceRoot /inheritance:r | Out-Null
    icacls $ThawspaceRoot /grant:r "Administrators:(OI)(CI)F" "SYSTEM:(OI)(CI)F" "Users:(OI)(CI)M" /T | Out-Null
} catch {
    Write-Warning "icacls reported an error: $_. The ACLs may need manual review."
}

# Update registry ProfileImagePath entries to point to thawspace
Write-Output "Updating registry profile paths to point to $ThawspaceRoot"
$regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"

# Update individual SIDs
foreach ($sub in Get-ChildItem $regPath) {
    $p = Get-ItemProperty -Path $sub.PSPath
    if ($p.ProfileImagePath) {
        $oldPath = $p.ProfileImagePath
        # If old path is under the sourceRootPath, update it
        if ($oldPath -like "$sourceRootPath*") {
            $username = Split-Path $oldPath -Leaf
            $newProfilePath = Join-Path $ThawspaceRoot $username
            Set-ItemProperty -Path $sub.PSPath -Name ProfileImagePath -Value $newProfilePath
            Write-Output "Registry: $username -> $newProfilePath"
        } else {
            Write-Output "Skipping registry entry $($sub.PSChildName) (ProfileImagePath not under sourceRoot)"
        }
    }
}

# Update ProfilesDirectory, Default, Public
Write-Output "Updating ProfilesDirectory, Default, Public registry values"
$rootKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
Set-ItemProperty -Path $rootKey -Name "ProfilesDirectory" -Value $ThawspaceRoot
Set-ItemProperty -Path $rootKey -Name "Default" -Value (Join-Path $ThawspaceRoot "Default")
Set-ItemProperty -Path $rootKey -Name "Public" -Value (Join-Path $ThawspaceRoot "Public")
Write-Output "Registry updated."

# OPTIONAL: backup registry key (recommended)
try {
    $exportPath = Join-Path $env:TEMP "ProfileList_backup_$(Get-Date -Format yyyyMMddHHmmss).reg"
    reg export "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" $exportPath /y | Out-Null
    Write-Output "Exported ProfileList to $exportPath"
} catch {
    Write-Warning "Failed to export ProfileList registry key: $_"
}

# At this point registry points to thawspace. Before deleting P:, confirm thawspace looks ok:
Write-Output "Performing final verification: check registry entries exist on disk"
$errors = @()
foreach ($sub in Get-ChildItem $regPath) {
    $p = Get-ItemProperty -Path $sub.PSPath
    if ($p.ProfileImagePath) {
        if (-not (Test-Path $p.ProfileImagePath)) {
            $errors += $p.ProfileImagePath
            Write-Warning "Registry points to $($p.ProfileImagePath) which does not exist on disk."
        }
    }
}
if ($errors.Count -gt 0) {
    Write-Error "One or more profile folders referenced in registry do not exist on thawspace. Aborting before removing source partition."
    exit 1
}

# Remove P: partition and expand C: to reclaim space
Write-Output "Removing source partition $SourceDriveLetter:`\ and expanding C: to reclaim space..."
try {
    $pPart = Get-Partition -DriveLetter $SourceDriveLetter -ErrorAction Stop
} catch {
    Write-Error "Could not find partition with drive letter $SourceDriveLetter. Aborting partition removal."
    exit 1
}

$diskNumber = $pPart.DiskNumber
$partitionNumber = $pPart.PartitionNumber

# Remove partition (this deletes data on that partition - we've already copied)
try {
    # Remove drive letter (optional) then remove partition
    Write-Output "Removing partition number $partitionNumber on disk $diskNumber"
    Remove-Partition -DiskNumber $diskNumber -PartitionNumber $partitionNumber -Confirm:$false -ErrorAction Stop
    Start-Sleep -Seconds 2
} catch {
    Write-Error "Failed to remove partition: $_"
    exit 1
}

# Now expand C: to maximum supported size
try {
    $cPart = Get-Partition -DriveLetter C -ErrorAction Stop
    $supported = Get-PartitionSupportedSize -DriveLetter C
    Write-Output "Expanding C: to maximum size $(BytesToGB $supported.SizeMax) GB"
    Resize-Partition -DiskNumber $cPart.DiskNumber -PartitionNumber $cPart.PartitionNumber -Size $supported.SizeMax -ErrorAction Stop
} catch {
    Write-Warning "Failed to expand C:. Manual expansion may be required: $_"
}

Write-Output "Done. All user profiles have been copied to $ThawspaceRoot, registry updated, P: removed and C: expanded (if possible)."
Write-Output "REBOOT the machine to ensure Windows loads profiles from $ThawspaceRoot."

# End script
