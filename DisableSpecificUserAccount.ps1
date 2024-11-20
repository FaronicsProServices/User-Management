# Disable a specific local user account on the system
# Replace "Username" with the name of the user account you want to disable
Disable-LocalUser -Name "Username"

# Example:
# To disable the account named "JakeAdams", use:
# Disable-LocalUser -Name "JakeAdams"

# Note:
# - This cmdlet is part of the Microsoft.PowerShell.LocalAccounts module.
# - Requires administrative privileges to execute.
# - Disabling a user account prevents the user from logging in until re-enabled.
