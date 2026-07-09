# --- CONFIGURATION ---
$ProtectedProfiles = @("Administrator", "Public", "Default")

# Get all user profiles that are not special
$Profiles = Get-CimInstance -Class Win32_UserProfile | Where-Object { $_.Special -eq $false }

foreach ($Profile in $Profiles) {
    # Extract the username
    $UserName = Split-Path $Profile.LocalPath -Leaf
    
    # Check if the profile is in the protected list
    if ($ProtectedProfiles -contains $UserName) {
        Write-Host ("Skipping protected profile: " + $UserName)
        continue
    }
    
    # Check if the profile is loaded (logged in)
    if ($Profile.Loaded) {
        Write-Host ("Skipping " + $UserName + " - Profile is loaded/in use")
        continue
    }

    # Execute the deletion - Remove -WhatIf
    Write-Host ("Deleting: " + $UserName)
    $Profile | Remove-CimInstance -Verbose
}
