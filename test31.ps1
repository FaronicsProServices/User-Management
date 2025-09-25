param(
    [string]$ThawspaceRoot = "T:\userprofiles"  # Destination ThawSpace
)

function Assert-Admin {
    if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Error "Run this script as Administrator."
        exit 1
    }
}

function Copy-Profiles {
    param($sourceRoot, $destRoot)

    Write-Output "Copying profiles from $sourceRoot to $destRoot ..."
    foreach ($folder in Get-ChildItem $sourceRoot -Directory -Force) {
        if ($folder.Name -eq 'All Users') { continue }

        $src = $folder.FullName
        $dst = Join-Path $destRoot $folder.Name

        Write-Output " -> Copying $($folder.Name)"
        robocopy $src $dst /MIR /COPYALL /XJ /R:3 /W:5 | Out-Null
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

    # Default & Public
    $newDefault = Join-Path $newRoot "Default"
    Set-ItemProperty -Path $regPath -Name "Default" -Value $newDefault
    Write-Output "Updated Default profile path -> $newDefault"

    $newPublic = Join-Path $newRoot "Public"
    Set-ItemProperty -Path $regPath -Name "Public" -Value $newPublic
    Write-Output "Updated Public profile path -> $newPublic"

    # ProfilesDirectory (future profiles)
    Set-ItemProperty -Path $regPath -Name "ProfilesDirectory" -Value $newRoot
    Write-Output "Updated ProfilesDirectory -> $newRoot"
}

# ===== MAIN =====
Assert-Admin

$sourceRoot = "P:\Users"
$destRoot   = $ThawspaceRoot

# Step 1: Clear ThawSpace
if (Test-Path $destRoot) {
    Write-Output "Clearing ThawSpace root: $destRoot"
    Remove-Item "$destRoot\*" -Recurse -Force -ErrorAction SilentlyContinue
} else {
    Write-Output "Creating ThawSpace root: $destRoot"
    New-Item -Path $destRoot -ItemType Directory -Force | Out-Null
}

# Step 2: Copy profiles
Copy-Profiles -sourceRoot $sourceRoot -destRoot $destRoot

# Step 3: Registry updates
Update-RegistryProfilePaths -oldRoot $sourceRoot -newRoot $destRoot

Write-Output "Done. Please reboot to load all profiles from ThawSpace ($destRoot)."
