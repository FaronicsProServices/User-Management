# --- CONFIGURATION ---
# Add the exact usernames (folder names) you want to protect here
$ProtectedProfiles = @("Administrator", "DeployAgentUser", "Public", "Default")

# Get all user profiles that are not special (like System/Service accounts)
$Profiles = Get-CimInstance -Class Win32_UserProfile | Where-Object { $_.Special -eq $false }

foreach ($Profile in $Profiles) {
    # Extract the username from the LocalPath (e.g., C:\Users\Username)
    $UserName = Split-Path $Profile.LocalPath -Leaf
    
    # Check if the profile is in the protected list
    if ($ProtectedProfiles -contains $UserName) {
        Write-Host "Skipping protected profile: $UserName" -ForegroundColor Yellow
    }
    else {
        Write-Host "Deleting profile: $UserName" -ForegroundColor Red
        
        # Execute the deletion
        # Remove -WhatIf below when you are ready to perform the actual deletion
        $Profile | Remove-CimInstance -WhatIf 
    }
}
