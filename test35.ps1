param(
    [string]$NewDriveLetter = "P"            # Drive letter for new partition
)

# ===== Important Notes =====
# 1. Ensure there is enough free space on C: before running this script.
#    Estimated required space = Total profiles size + 20% buffer (~$required GB).
# 2. The target drive (e.g., P:) must exist before running the script.
# 3. Default and Public profiles will be copied first, followed by other user profiles.

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

function Copy-Profiles {
    param($sourceRoot, $destRoot, [ref]$skipped)

    # Copy Default and Public first
    foreach ($special in @("Default", "Public")) {
        $src = Join-Path $sourceRoot $special
        $dst = Join-Path $destRoot $special
        if (Test-Path $src) {
            Write-Output "Copying $special profile..."
            robocopy $src $dst /MIR /COPYALL /R:3 /W:5 /XJ | Out-Null
        }
    }

    # Copy other profiles
    foreach ($folder in Get-ChildItem $sourceRoot -Directory -Force) {
        if ($folder.Name -in @('All Users','Default','Public')) { continue }

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

    # Update default, public, and ProfilesDirectory
    $defReg = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
    Set-ItemProperty -Path $defReg -Name "Default" -Value (Join-Path $newRoot "Default")
    Set-ItemProperty -Path $defReg -Name "Public" -Value (Join-Path $newRoot "Public")
    Set-ItemProperty -Path $defReg -Name "ProfilesDirectory" -Value $newRoot

    Write-Output "Registry updated for Default, Public, and ProfilesDirectory."
}

# ===== MAIN =====
Assert-Admin

# Check if target drive exists
if (-not (Test-Path "$NewDriveLetter`:")) {
    Write-Error "Target drive $NewDriveLetter: does not exist. Please create the partition before running this script."
    exit 1
}

$profilesRoot = Get-CurrentProfilesRoot
Write-Output "Detected profiles root: $profilesRoot"

$profileFolders = Get-ProfileFolders $profilesRoot
$totalBytes = ($profileFolders | ForEach-Object { Get-FolderSize $_.FullName } | Measure-Object -Sum).Sum
$bufferBytes = [math]::Round($totalBytes * 0.20)
$required = $totalBytes + $bufferBytes

# Check free space on target drive
$targetDriveFree = (Get-PSDrive $NewDriveLetter).Free
if ($required -gt $targetDriveFree) {
    Write-Error "Not enough free space on $NewDriveLetter:. Required: $(BytesToGB $required) GB, Available: $(BytesToGB $targetDriveFree) GB."
    exit 1
}

Write-Output "Profiles size: $(BytesToGB $totalBytes) GB, buffer: $(BytesToGB $bufferBytes) GB, total required: $(BytesToGB $required) GB."

$destRoot = "$NewDriveLetter`:\Users"
New-Item -Path $destRoot -ItemType Directory -Force | Out-Null

$skipped = @()
Copy-Profiles -sourceRoot $profilesRoot -destRoot $destRoot -skipped ([ref]$skipped)

Update-RegistryProfilePaths -oldRoot $profilesRoot -newRoot $destRoot

Write-Output "Done. Skipped profiles: $($skipped -join ', ')"
Write-Output "Reboot required to load profiles from new partition."
