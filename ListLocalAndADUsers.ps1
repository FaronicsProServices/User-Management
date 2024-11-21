#Lists Local and Active Directory users
# For Active Directory users, Active Directory Module must be installed on that Windows Device
# Function to list local users
function Get-LocalUsers {
    try {
        $localUsers = Get-LocalUser
        if ($localUsers.Count -eq 0) {
            Write-Host "No local users found."
        } else {
            Write-Host "`nList of Local Users:"
            $localUsers | Select-Object Name, Enabled | Format-Table -AutoSize
        }
    } catch {
        Write-Host "Error fetching local users: $_"
    }
}

# Function to list Active Directory users
function Get-ADUsers {
    try {
        # Check if Active Directory module is installed
        if (Get-Command Get-ADUser -ErrorAction SilentlyContinue) {
            # Get all Active Directory users
            $adUsers = Get-ADUser -Filter * -Property SamAccountName, Enabled
            if ($adUsers.Count -eq 0) {
                Write-Host "No Active Directory users found."
            } else {
                Write-Host "`nList of Active Directory Users:"
                $adUsers | Select-Object SamAccountName, Enabled | Format-Table -AutoSize
            }
        } else {
            Write-Host "`nActive Directory module not installed. Skipping AD users listing."
        }
    } catch {
        Write-Host "Error fetching Active Directory users: $_"
    }
}

# Main Execution: List both local and AD users
Get-LocalUsers
Get-ADUsers
