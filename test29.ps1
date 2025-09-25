param(
    [string]$SourceDriveLetter = "P",       # Drive letter of current Profiles partition
    [string]$ThawspaceRoot = "T:\userprofiles"  # Destination Thawspace path
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

function Copy-Profiles {
    param($sourceRoot, $destRoot, [ref]$skipped)

    foreach ($folder in Get-ChildItem $sourceRoot -Directory -Force) {
        if ($folder.Name -eq 'All Users') { continue }

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

    # Default & Public profiles
    $defReg = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
    $newDefault = Join-Path $newRoot "Default"
    Set-ItemProperty -Path $defReg -Name "Default" -Value $newDefault
    Write-Output "Updated Default profile path -> $newDefault"

    $newPublic = Join-Path $newRoot "Public"
    Set-ItemProperty -Path $defReg -Name "Public" -Value $newPublic
    Write-Output "Updated Public profile path -> $newPublic"

    # ProfilesDirectory (important for future profiles)
    Set-ItemProperty -Path $defReg -Name "ProfilesDirectory" -Value $newRoot
    Write-Output "Updated ProfilesDirectory -> $newRoot"
}

# ===== MAIN =====
Assert-Admin

# Verify source drive exists
if (-not (Get-PSDrive -Name $SourceDriveLetter -ErrorAction SilentlyContinue)) {
    Write-Error "Source drive ${SourceDriveLetter}:\ not present. Aborting."
    exit 1
}

$profilesRoot = Get-CurrentProfilesRoot
Write-Output "Detected profiles root: $profilesRoot"

# Warn if registry does not match source drive
if ($profilesRoot -notlike "${SourceDriveLetter}*") {
    Write-Warning "Registry ProfilesDirectory indicates path not on ${SourceDriveLetter}:\ (it is $profilesRoot). Proceeding anyway."
}

# Clear destination thawspace
try {
    if (Test-Path $ThawspaceRoot) {
        Write-Output "Clearing thawspace $ThawspaceRoot ..."
        Remove-Item "$ThawspaceRoot\*" -Recurse -Force -ErrorAction Stop
    } else {
        Write-Output "Creating thawspace directory $ThawspaceRoot ..."
        New-Item -Path $ThawspaceRoot -ItemType Directory -Force | Out-Null
    }
} catch {
    Write-Error "Failed to clear ${ThawspaceRoot}: $_"
    exit 1
}

# Copy profiles
$skipped = @()
Copy-Profiles -sourceRoot $profilesRoot -destRoot $ThawspaceRoot -skipped ([ref]$skipped)

# Update registry
Update-RegistryProfilePaths -oldRoot $profilesRoot -newRoot $ThawspaceRoot

# Remove source partition
try {
    Write-Output "Removing source partition ${SourceDriveLetter}:\ and expanding C:..."
    $srcPart = Get-Partition -DriveLetter $SourceDriveLetter -ErrorAction Stop
    $disk = Get-Disk -Number $srcPart.DiskNumber
    Remove-Partition -DiskNumber $srcPart.DiskNumber -PartitionNumber $srcPart.PartitionNumber -Confirm:$false
    $cPart = Get-Partition -DriveLetter C
    $maxSize = (Get-PartitionSupportedSize -DiskNumber $cPart.DiskNumber -PartitionNumber $cPart.PartitionNumber).SizeMax
    Resize-Partition -DiskNumber $cPart.DiskNumber -PartitionNumber $cPart.PartitionNumber -Size $maxSize
} catch {
    Write-Warning "Failed to remove partition ${SourceDriveLetter}:\ or expand C:. $_"
}

Write-Output "Done. Skipped profiles: $($skipped -join ', ')"
Write-Output "Reboot required to load profiles from thawspace ($ThawspaceRoot)."
