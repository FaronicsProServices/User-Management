param(
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$ProtectedUsers
)

# 1. Force the input into a single array, even if the RMM sends it as a mess
$ProtectedList = @()
if ($null -ne $ProtectedUsers) {
    # If it came in as a single string with commas, split it
    $RawInput = $ProtectedUsers -join ','
    $ProtectedList = $RawInput.Split(',').Trim().Replace('"', '').Replace("'", "")
}

$Profiles = Get-CimInstance -Class Win32_UserProfile | Where-Object { $_.Special -eq $false }

foreach ($Profile in $Profiles) {
    $UserName = Split-Path $Profile.LocalPath -Leaf
    
    # 2. Use -match or -eq for robust comparison
    $IsProtected = $false
    foreach ($Name in $ProtectedList) {
        if ($UserName -eq $Name) { $IsProtected = $true }
    }

    if ($IsProtected) {
        Write-Host ("Skipping protected profile: " + $UserName)
        continue
    }
    
    if ($Profile.Loaded) {
        Write-Host ("Skipping " + $UserName + " - Loaded")
        continue
    }

    Write-Host ("Deleting: " + $UserName)
    $Profile | Remove-CimInstance
}
