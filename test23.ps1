param(
    [string]$NewProfilesRoot = "T:\userprofiles"
)

function Assert-Admin {
    if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Error "Run this script as Administrator."
        exit 1
    }
}

Assert-Admin

$regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"

Write-Output "Updating registry to use profiles from $NewProfilesRoot"

# Update ProfilesDirectory
Set-ItemProperty -Path $regPath -Name "ProfilesDirectory" -Value $NewProfilesRoot
Write-Output "Set ProfilesDirectory -> $NewProfilesRoot"

# Update Default and Public
$defaultPath = Join-Path $NewProfilesRoot "Default"
$publicPath  = Join-Path $NewProfilesRoot "Public"
Set-ItemProperty -Path $regPath -Name "Default" -Value $defaultPath
Set-ItemProperty -Path $regPath -Name "Public"  -Value $publicPath
Write-Output "Updated Default -> $defaultPath"
Write-Output "Updated Public  -> $publicPath"

# Update each existing user profile path
foreach ($sub in Get-ChildItem $regPath) {
    $p = Get-ItemProperty $sub.PSPath
    if ($p.ProfileImagePath -match "^[A-Z]:\\Users\\") {
        $userName = Split-Path $p.ProfileImagePath -Leaf
        $newPath = Join-Path $NewProfilesRoot $userName
        Set-ItemProperty -Path $sub.PSPath -Name ProfileImagePath -Value $newPath
        Write-Output "Updated $userName -> $newPath"
    }
}

Write-Output "Registry redirection complete. Please reboot the system to load profiles from $NewProfilesRoot."
