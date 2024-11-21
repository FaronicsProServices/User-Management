# Log off all active user sessions
$activeSessionIDs = (Get-Process -Name "explorer" | Select-Object -ExpandProperty SessionID) | Where-Object { $_ -gt 0 } 
if ($activeSessionIDs.Count -gt 0) { 
    foreach ($sessionID in $activeSessionIDs) { 
        logoff $sessionID 
        Write-Host "Logged off session $sessionID" 
    } 
} else { 
    Write-Host "No active user sessions found." 
}
