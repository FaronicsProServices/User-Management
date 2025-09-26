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

function Copy-SpecialProfiles {
    param($profilesRoot, $destRoot)

    foreach ($specialProfile in @("Default", "Public")) {
        $src = Join-Path $profilesRoot $specialProfile
        $dst = Join-Path $destRoot $specialProfile
        if (Test-Path $src) {
            Write-Output "Copying special profile: $specialProfile"
            robocopy $src $dst /MIR /COPYALL /R:3 /W:5 /XJ | Out-Null
        }
    }
}

function Copy-Profiles {
    param($sourceRoot, $destRoot, [ref]$skipped, [ref]$copied)

    foreach ($folder in Get-ChildItem $sourceRoot -Directory -Force) {
        if ($folder.Name -in @('All Users', 'Default', 'Public')) { continue }

        $src = $folder.FullName
        $dst = Join-Path $destRoot $folder.Name

        # Skip copying if profile already exists on destination
        if (Test-Path $dst) {
            Write-Output "Profile $($folder.Name) already exists on destination, skipping copy."
            $copied.Value += $folder.Name
            continue
        }

        $ntuser = Join-Path $src "NTUSER.DAT"
        $isLoaded = $false
        if (Test-Path $ntuser) {
            try {
                $h = [System.IO.File]::Open($ntuser, 'Open', 'Read', 'None'); $h.Close()
            } catch {
                $isLoaded = $true
            }
        }

        if ($isLoaded) {
            Write-Warning "Skipping $($folder.Name), profile is in use."
            $skipped.Value += $folder.Name
            continue
        }

        Write-Output "Copying $($folder.Name)..."
        robocopy $src $dst /MIR /COPYALL /R:3 /W:5 /XJ | Out-Null
        $copied.Value += $folder.Name
    }
}

function Update-RegistryProfilePaths {
    param($oldRoot, $newRoot, [ref]$regUpdated, $copiedProfiles)

    $regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"

    # Check if all profiles exist on destination; if yes, skip registry update altogether
    $allProfiles = @(Get-ProfileFolders $oldRoot | ForEach-Object { $_.Name }) + @("Default","Public")
    $profilesOnDest = @(Get-ProfileFolders $newRoot | ForEach-Object { $_.Name }) + @("Default","Public")
    $allExist = $true
    foreach ($profile in $allProfiles) {
        if (-not ($profilesOnDest -contains $profile)) {
            $allExist = $false
            break
        }
    }
    if ($allExist) {
        Write-Output "All profiles exist on $newRoot. Skipping registry updates."
        return
    }

    foreach ($sub in Get-ChildItem $regPath) {
        $p = Get-ItemProperty $sub.PSPath
        $user = Split-Path $p.ProfileImagePath -Leaf

        if ($user -in $copiedProfiles -or $user -in @('Default','Public')) {
            if ($p.ProfileImagePath -like "$oldRoot*") {
                $newPath = Join-Path $newRoot $user
                Set-ItemProperty -Path $sub.PSPath -Name ProfileImagePath -Value $newPath
                Write-Output "Updated registry for $user -> $newPath"
                $regUpdated.Value += $user
            }
        } else {
            Write-Output "Skipped registry update for $user (profile not copied)."
        }
    }

    # Update Default, ProfilesDirectory, and Public in ProfileList key
    Set-ItemProperty -Path $regPath -Name "Default" -Value (Join-Path $newRoot "Default")
    Write-Output "Updated ProfileList Default -> $($newRoot)\Default"
    $regUpdated.Value += "Default"

    Set-ItemProperty -Path $regPath -Name "ProfilesDirectory" -Value $newRoot
    Write-Output "Updated ProfileList ProfilesDirectory -> $newRoot"
    $regUpdated.Value += "ProfilesDirectory"

    Set-ItemProperty -Path $regPath -Name "Public" -Value (Join-Path $newRoot "Public")
    Write-Output "Updated ProfileList Public -> $($newRoot)\Public"
    $regUpdated.Value += "Public"
}

# ===== MAIN =====
Assert-Admin

$profilesRoot = Get-CurrentProfilesRoot
Write-Output "Detected profiles root: $profilesRoot"

$profileFolders = Get-ProfileFolders $profilesRoot
$totalBytes = ($profileFolders | ForEach-Object { Get-FolderSize $_.FullName } | Measure-Object -Sum).Sum

# Calculate buffer as 20% of total profile size
$bufferBytes = [math]::Round($totalBytes * 0.20)
$required = $totalBytes + $bufferBytes

$cDrive = Get-PSDrive C
if ($required -gt $cDrive.Free) {
    Write-Warning "Not enough free space on C:. Reducing buffer to fit available space."
    $bufferBytes = [math]::Max(1GB, $cDrive.Free - $totalBytes - 1GB)
    $required = $totalBytes + $bufferBytes
}

Write-Output "Profiles size: $(BytesToGB $totalBytes) GB, buffer: $(BytesToGB $bufferBytes) GB, required partition: $(BytesToGB $required) GB"

# Check if drive exists before creating partition
if (-not (Test-Path ("${NewDriveLetter}:\"))) {
    # Resize and create new partition
    Resize-CPartitionAndCreateNew -NewPartitionSizeBytes $required -NewDriveLetter $NewDriveLetter

    # Primary validation - Check if new drive is accessible after creation
    if (-not (Test-Path ("${NewDriveLetter}:\"))) {
        throw "Drive ${NewDriveLetter}: was not created successfully. Aborting script."
    }
    Write-Output "New drive ${NewDriveLetter}: created and verified successfully."
} else {
    Write-Output "Drive ${NewDriveLetter}: already exists, skipping partition creation."
}

# Prepare destination root directory
$destRoot = "$NewDriveLetter`:\Users"
New-Item -Path $destRoot -ItemType Directory -Force | Out-Null

# Copy Default and Public profiles first
Copy-SpecialProfiles -profilesRoot $profilesRoot -destRoot $destRoot

# Copy other profiles with in-use skip detection and skip existing on destination
$skipped = @()
$copied = @()
Copy-Profiles -sourceRoot $profilesRoot -destRoot $destRoot -skipped ([ref]$skipped) -copied ([ref]$copied)

if ($skipped.Count -gt 0) {
    Write-Warning "Skipped profiles (in use): $($skipped -join ', ')"
    Write-Output "Profile copying completed with skipped profiles."
} else {
    Write-Output "All profiles copied successfully."
}

# Update registry only for copied profiles + Default and Public if not all profiles exist on destination
$regUpdated = @()
Update-RegistryProfilePaths -oldRoot $profilesRoot -newRoot $destRoot -regUpdated ([ref]$regUpdated) -copiedProfiles $copied

# Validate registry updates for expected profiles
$allProfiles = @(Get-ProfileFolders $profilesRoot | ForEach-Object { $_.Name }) + @("Default","ProfilesDirectory","Public")
$notUpdated = $allProfiles | Where-Object { $_ -notin $regUpdated }

if ($notUpdated.Count -eq 0) {
    Write-Output "Registry keys updated and validated successfully for all profiles."
} else {
    Write-Warning "Registry not updated for: $($notUpdated -join ', ')"
}

Write-Output "Done."
Write-Output "Reboot required to load profiles from new partition."
