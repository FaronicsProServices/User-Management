# Log off a specific user by their username if they have an active session
$targetUsername = 'username' 
$activeSessions = quser 
$sessionLine = $activeSessions | Where-Object { $_ -match $targetUsername } 
if ($sessionLine) { 
    $sessionInfo = ($sessionLine -split '\s+') | Where-Object { $_ -ne '' } 
    $sessionID = $sessionInfo[2] 
    logoff $sessionID 
    Write-Host "Logged off user $targetUsername (Session ID: $sessionID)" 
} else { 
    Write-Host "User $targetUsername is not currently logged in." 
}
