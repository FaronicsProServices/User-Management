param(
    [string]$NewDriveLetter = "P"            # Drive letter for new partition
)

# ===== Functions =====
function Assert-Admin {
    if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Error "Run this script as Administrator."
        exit 1
    }
}

function Get-CurrentProfilesRoot {
    $reg = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
    $profilesDir = (Get-ItemProperty $reg).ProfilesDirectory
    if (-not $profilesDir) { throw "Cannot detect ProfilesDirectory in registry." }
    return [Environment]::ExpandEnvironmentVariables($profilesDir)
}

function Get-ProfileFolders {
    param($root)
    Get-ChildItem -Path $root -Directory -Force | Where-Object { $_.Name -notin @('All Users') -and $_.Attributes -notmatch 'ReparsePoint' }
}

function Get-FolderSize {
    param($path)
    try {
        $size = (Get-ChildItem -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue |
                 Measure-Object -Property Length -Sum).Sum
        if ($null -eq $size) { $size = 0 }
        return [int64]$size
    } catch { return 0 }
}

function BytesToGB([long]$b) { [math]::Round($b / 1GB, 2) }

function Resize-CPartitionAndCreateNew {
    param(
        [long]$NewPartitionSizeBytes,
        [string]$NewDriveLetter
    )

    $cPart = Get-Partition -DriveLetter C
    $diskNumber = $cPart.DiskNumber

    # Maximum shrinkable size on C:
    $shrinkInfo = Get-PartitionSupportedSize -DriveLetter C
    if ($NewPartitionSizeBytes -gt $shrinkInfo.SizeMax) {
        Write-Warning "Requested partition size exceeds shrinkable space. Using maximum allowed size."
        $NewPartitionSizeBytes = $shrinkInfo.SizeMax
    }

    $targetCSize = $cPart.Size - $NewPartitionSizeBytes
    if ($targetCSize -lt 20GB) {
        throw "Not enough space to shrink C: safely. Aborting."
    }

    Write-Output "Shrinking C: and creating new partition of $(BytesToGB $NewPartitionSizeBytes) GB..."
    Resize-Partition -DiskNumber $diskNumber -PartitionNumber $cPart.PartitionNumber -Size $targetCSize

    $newPart = New-Partition -DiskNumber $diskNumber -Size $NewPartitionSizeBytes -AssignDriveLetter:$false
    $newPart | Set-Partition -NewDriveLetter $NewDriveLetter
    Format-Volume -DriveLetter $NewDriveLetter -FileSystem NTFS -NewFileSystemLabel "Profiles" -Confirm:$false -Force
}

function Copy-Profiles {
    param($sourceRoot, $destRoot, [ref]$skipped)

    # Copy Default and Public profiles first
    foreach ($default in @("Default", "Public")) {
        $src = Join-Path $sourceRoot $default
        $dst = Join-Path $destRoot $default
        if (Test-Path $src) {
            Write-Output "Copying $default profile..."
            robocopy $src $dst /MIR /COPYALL /R:3 /W:5 /XJ | Out-Null
        }
    }

    # Copy other user profiles
    foreach ($folder in Get-ProfileFolders $sourceRoot) {
        $src = $folder.FullName
        $dst = Join-Path $destRoot $folder.Name

        $ntuser = Join-Path $src "NTUSER.DAT"
        $isLoaded = $false
        if (Test-Path $ntuser) {
            try { 
                $h = [System.IO.File]::Open($ntuser,'Open','Read','None'); $h.Close() 
            } catch { $isLoaded = $true }
        }

        if ($isLoaded) {
            Write-Warning "Skipping $($folder.Name), profile is in use."
            $skipped.Value += $folder.Name
            continue
        }

        Write-Output "Copying $($folder.Name)..."
        robocopy $src $dst /MIR /COPYALL /R:3 /W:5 /XJ | Out-Null
    }
}

function Update-RegistryProfilePaths {
    param($oldRoot, $newRoot)

    $regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
    foreach ($sub in Get-ChildItem $regPath) {
        $p = Get-ItemProperty $sub.PSPath
        if ($p.ProfileImagePath -like "$oldRoot*") {
            $user = Split-Path $p.ProfileImagePath -Leaf
            $newPath = Join-Path $newRoot $user
            Set-ItemProperty -Path $sub.PSPath -Name ProfileImagePath -Value $newPath
            Write-Output "Updated registry for $user -> $newPath"
        }
    }

    # ProfilesDirectory and Default/Public
    $defReg = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
    Set-ItemProperty -Path $defReg -Name "Default" -Value (Join-Path $newRoot "Default")
    Set-ItemProperty -Path $defReg -Name "Public" -Value (Join-Path $newRoot "Public")
    Set-ItemProperty -Path $defReg -Name "ProfilesDirectory" -Value $newRoot
}

# ===== MAIN =====
Assert-Admin

$profilesRoot = Get-CurrentProfilesRoot
Write-Output "Detected profiles root: $profilesRoot"

$profileFolders = Get-ProfileFolders $profilesRoot
$totalBytes = ($profileFolders | ForEach-Object { Get-FolderSize $_.FullName } | Measure-Object -Sum).Sum
$bufferBytes = [math]::Round($totalBytes * 0.20)
$required = $totalBytes + $bufferBytes

# Validate sufficient free space on C: before creating P:
$cDrive = Get-PSDrive C
if ($required + 20GB -gt $cDrive.Free) {
    throw "Not enough free space on C: to create P: drive. At least 20 GB must remain on C:. Required space for P: $(BytesToGB $required) GB."
}

Write-Output "Profiles size: $(BytesToGB $totalBytes) GB, buffer: $(BytesToGB $bufferBytes) GB, total partition required: $(BytesToGB $required) GB"

# Create new P: partition
Resize-CPartitionAndCreateNew -NewPartitionSizeBytes $required -NewDriveLetter $NewDriveLetter

# Validate P: exists
if (-not (Test-Path "$NewDriveLetter:`\")) {
    throw "Drive $NewDriveLetter: was not created successfully. Aborting script."
}

# Prepare destination folder
$destRoot = "$NewDriveLetter`:\Users"
New-Item -Path $destRoot -ItemType Directory -Force | Out-Null

$skipped = @()
Copy-Profiles -sourceRoot $profilesRoot -destRoot $destRoot -skipped ([ref]$skipped)

# Apply registry changes only after successful copy
Update-RegistryProfilePaths -oldRoot $profilesRoot -newRoot $destRoot

Write-Output "Done. Skipped profiles: $($skipped -join ', ')"
Write-Output "Reboot required to load profiles from new partition."

# ===== IMPORTANT COMMENT =====
<#
Before running this script:
- Ensure at least 20 GB of free space remains on C: after creating the P: partition.
- The required size for the new partition is the total size of all profiles + 20% buffer.
- Default and Public profiles are copied first, followed by other user profiles.
- Registry changes are applied only after all profiles are successfully copied.
#>
