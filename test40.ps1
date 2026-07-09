# --- FINAL ROBUST CONFIGURATION ---
# This script manually reads the command line arguments to bypass RMM parsing errors.

# Look for "-ProtectedUsers" in the arguments passed by the RMM
$ArgIndex = $args.IndexOf("-ProtectedUsers")
if ($ArgIndex -ge 0 -and ($ArgIndex + 1) -lt $args.Count) {
    # Extract the user list and clean it (remove quotes, spaces, and commas)
    $RawList = $args[$ArgIndex + 1]
    $ProtectedProfiles = $RawList.Split(',').Trim().Replace('"', '').Replace("'", "")
} else {
    # Default fallback protection if nothing is passed
    $ProtectedProfiles = @("Administrator", "Public", "Default")
}

# Get all user profiles that are not special
$Profiles = Get-CimInstance -Class Win32_UserProfile | Where-Object { $_.Special -eq $false }

foreach ($Profile in $Profiles) {
    $UserName = Split-Path $Profile.LocalPath -Leaf
    
    # Check if the user is in our protected list (Wildcard match ensures domain names don't break it)
    $IsProtected = $false
    foreach ($PUser in $ProtectedProfiles) {
        if ($UserName -like "*$PUser*") {
            $IsProtected = $true
            break
        }
    }

    if ($IsProtected) {
        Write-Host ("Skipping protected profile: " + $UserName)
        continue
    }
    
    # Check if the profile is loaded (in use)
    if ($Profile.Loaded) {
        Write-Host ("Skipping " + $UserName + " - Profile is loaded/in use")
        continue
    }

    # Execute the deletion
    Write-Host ("Deleting: " + $UserName)
    $Profile | Remove-CimInstance -Verbose
}
