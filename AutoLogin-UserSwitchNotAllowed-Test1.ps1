# This script enables automatic logon for a specified user, disables user switch at login, 
# and sets the monitor and standby timeouts to 0. It then forces a restart of the computer.
$Username = "CONTOSO\admin2" # Specify the user account as 'Domain\User' for domain environments or simply as 'Username' for local (workgroup) accounts.
$Password = "Partners@2024" 
$RegPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" 
Set-ItemProperty -Path $RegPath -Name "AutoAdminLogon" -Value 1 
Set-ItemProperty -Path $RegPath -Name "DefaultUsername" -Value $Username 
Set-ItemProperty -Path $RegPath -Name "DefaultPassword" -Value $Password 
New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI" -Name "LogonUserSwitch" -Value 0 -Force 
powercfg -change -monitor-timeout-ac 0 
powercfg -change -monitor-timeout-dc 0 
powercfg -change -standby-timeout-ac 0 
powercfg -change -standby-timeout-dc 0 
Restart-Computer -Force
