
# This script enables automatic logon for a specified user,
# sets the monitor and standby timeouts to 0,
# and then forces a restart of the computer.
# It allows switching users after the auto login.

$Username = "Username" # Specify the user account as 'Domain\User' for domain environments or simply as 'Username' for local (workgroup) accounts.
$Password = "Password"
$RegPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"

Set-ItemProperty -Path $RegPath -Name "AutoAdminLogon" -Value 1
Set-ItemProperty -Path $RegPath -Name "DefaultUsername" -Value $Username
Set-ItemProperty -Path $RegPath -Name "DefaultPassword" -Value $Password

# Commented out to allow user switching at login screen
# New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI" -Name "LogonUserSwitch" -Value 0 -Force

powercfg -change -monitor-timeout-ac 0
powercfg -change -monitor-timeout-dc 0
powercfg -change -standby-timeout-ac 0
powercfg -change -standby-timeout-dc 0

Restart-Computer -Force
