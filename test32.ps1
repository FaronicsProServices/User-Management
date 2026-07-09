# --- CONFIGURATION ---
# IMPORTANT: These profiles will NOT be deleted
$ProtectedProfiles = @("Administrator", "DeployAgentUser", "Public", "Default", "SYSTEM", "LocalService", "NetworkService")

# Set up logging for RMM troubleshooting
Start-Transcript -Path "C:\Windows\Temp\ProfileCleanup.log" -Append -Force

# Get all user profiles that are not special (like system-managed placeholders)
$Profiles = Get-CimInstance -Class Win32_UserProfile | Where-Object { $_.Special -eq $false }

foreach ($Profile in $Profiles) {
    $UserName = Split-Path $Profile.LocalPath -Leaf
    
    # Check if the profile is in the protected list
    if ($ProtectedProfiles -contains $UserName) {
        Write-Host "Skipping protected profile: $UserName" -ForegroundColor Yellow
        continue
    }
    
    # Check if the user is currently logged on (prevents locked file errors)
    if ($Profile.Loaded) {
        Write-Host "Skipping $UserName: User is currently logged on." -ForegroundColor Yellow
        continue
    }

    # Execute the deletion
    Write-Host "Attempting to delete profile: $UserName" -ForegroundColor Red
    try {
        $Profile | Remove-CimInstance -ErrorAction Stop
        Write-Host "Successfully deleted $UserName" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to remove profile $UserName via WMI. Error: $($_.Exception.Message)"
    }
}

Stop-Transcript
