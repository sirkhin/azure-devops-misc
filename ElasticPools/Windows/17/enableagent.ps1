param
(
   [string]$url,
   [string]$pool,
   [string]$token,
   [string]$runArgs,
   [switch]$interactive
)

function Log-Message 
{
   param ([string] $message)

   $now = [DateTime]::UtcNow.ToString('u')
   $text = $now + " " + $message
   $logFile = "script.log"
   if (!(Test-Path -Path $logFile))
   {
      Set-Content -Path $logFile -Value ""
   }
   Add-Content -Path $logFile -Value $text
   Write-Host $text
}

if ($token -eq 'ENABLE_AGENT_PAT_TOKEN' )
{
   Log-Message "PAT Token passed using env variable"
   $tmp = [System.Environment]::GetEnvironmentVariable($token, [System.EnvironmentVariableTarget]::User)
   [System.Environment]::SetEnvironmentVariable($token, $null, [System.EnvironmentVariableTarget]::User)
   Log-Message "Env variable deleted"
   $token = $tmp
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$agentDir = $PSScriptRoot

Log-Message "Installing extension v17"
Log-Message ("URL: " + $url)
Log-Message ("Pool: " + $pool) 
Log-Message ("runArgs: " + $runArgs)
Log-Message ("interactive: " + $interactive)
Log-Message ("agentDir: " + $agentDir)

$agentExe = Join-Path -Path $agentDir -ChildPath "bin\Agent.Listener.exe"
$agentZip = Get-ChildItem -Path $agentDir\* -File -Include vsts-agent*.zip
$agentConfig = Join-Path -Path $agentDir -ChildPath "config.cmd"

Log-Message ("agentExe: " + $agentExe)
Log-Message ("agentZip: " + $agentZip)
Log-Message ("agentConfig: " + $agentConfig)

$version = (Get-WmiObject Win32_OperatingSystem).Version
Log-Message ("Windows version: " + $version)
$windows = Get-WindowsEdition -Online
Log-Message ("Windows edition: " + $windows.Edition)

$machineEnvVariables = [System.Environment]::GetEnvironmentVariables([System.EnvironmentVariableTarget]::Machine)

$machineEnvVariables.Keys | Where-Object { $_.StartsWith("VSTS_AGENT_INPUT_") } | ForEach-Object {
   [string] $envVarName = $_
   [string] $envVarValue = $machineEnvVariables[$envVarName]

   if (-not [System.Environment]::GetEnvironmentVariable($envVarName)) {
      [System.Environment]::SetEnvironmentVariable($envVarName, $envVarValue)
   }
}

$agentDiagFolder = "C:\WindowsAzure\Logs\Plugins\Microsoft.VisualStudio.Services.TeamServicesAgent\_diag"
[System.Environment]::SetEnvironmentVariable('AGENT_DIAGLOGPATH', $agentDiagFolder, [System.EnvironmentVariableTarget]::Machine)

# Determine if we should run as local user or as LocalSystem.
# Normally, we can only run as the local user on Windows Server due to limitations on the Client OS,
# however if VSTS_AGENT_INPUT_USER_NAME environment variable is set, we will run as that user.

$username = [System.Environment]::GetEnvironmentVariable('VSTS_AGENT_INPUT_USER_NAME')

if ($username)
{
   $runAsUser = $true
}
else
{
   $runAsUser = (($version -like '10.*') `
                -and ($windows.Edition -like '*datacenter*' -or $windows.Edition -like '*server*' ))
}
Log-Message ("runAsUser: " + $runAsUser)

# If the agent was already configured.  Abort.
if (Test-Path -Path (Join-Path -Path $agentDir -ChildPath ".agent"))
{
   Log-Message "Agent was already configured.  Doing nothing."
   exit 0
}

# Workaround Triptych potential vulnerability
Set-NetIPv4Protocol -SourceRoutingBehavior drop

# Begin MMS Initialization steps
Add-MpPreference -ExclusionPath 'c:\', 'd:\' -ErrorAction Ignore

Log-Message "Disable VisualStudio/VSIXAutoUpdater Tasks..."
Get-ScheduledTask -TaskPath '\Microsoft\VisualStudio\' -ErrorAction Ignore | Disable-ScheduledTask -ErrorAction Ignore
Get-ScheduledTask -TaskPath "\Microsoft\VisualStudio\Updates\" -ErrorAction Ignore | Disable-ScheduledTask -ErrorAction Ignore

Log-Message "Disable Windows Update..."
Disable-ScheduledTask -ErrorAction Ignore -TaskPath '\Microsoft\Windows\DiskCleanup\' -TaskName 'SilentCleanup'
Disable-ScheduledTask -ErrorAction Ignore -TaskPath '\Microsoft\Windows\UpdateOrchestrator\' -TaskName 'Reboot'
Disable-ScheduledTask -ErrorAction Ignore -TaskPath '\Microsoft\Windows\UpdateOrchestrator\' -TaskName 'Refresh Settings'
Disable-ScheduledTask -ErrorAction Ignore -TaskPath '\Microsoft\Windows\UpdateOrchestrator\' -TaskName 'Schedule Scan'
Disable-ScheduledTask -ErrorAction Ignore -TaskPath '\Microsoft\Windows\UpdateOrchestrator\' -TaskName 'USO_UxBroker_Display'
Disable-ScheduledTask -ErrorAction Ignore -TaskPath '\Microsoft\Windows\UpdateOrchestrator\' -TaskName 'USO_UxBroker_ReadyToReboot'
Disable-ScheduledTask -ErrorAction Ignore -TaskPath '\Microsoft\Windows\WindowsUpdate\' -TaskName 'Automatic App Update'
Disable-ScheduledTask -ErrorAction Ignore -TaskPath '\Microsoft\Windows\WindowsUpdate\' -TaskName 'Scheduled Start'
Disable-ScheduledTask -ErrorAction Ignore -TaskPath '\Microsoft\Windows\WindowsUpdate\' -TaskName 'sih'
Disable-ScheduledTask -ErrorAction Ignore -TaskPath '\Microsoft\Windows\WindowsUpdate\' -TaskName 'sihboot'
Stop-Service -Force -Name 'wuauserv' -ErrorAction Ignore
Set-Service -Name 'wuauserv' -StartupType Disabled -ErrorAction Ignore

$regPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
if (!(Test-Path $regPath))
{
  New-Item -Path $regPath -Force -ErrorAction Ignore
}
New-ItemProperty -Path $regPath -Name "AUOptions" -Value 1 -PropertyType DWORD -Force -ErrorAction Ignore
New-ItemProperty -Path $regPath -Name "NoAutoUpdate" -Value 1 -PropertyType DWORD -Force -ErrorAction Ignore

$regPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
if (!(Test-Path $regPath))
{
  New-Item -Path $regPath -Force -ErrorAction Ignore
}
New-ItemProperty -Path $regPath -Name 'DoNotConnectToWindowsUpdateInternetLocations' -Value 1 -PropertyType DWORD -Force -ErrorAction Ignore
New-ItemProperty -Path $regPath -Name 'DisableWindowsUpdateAccess' -Value 1 -PropertyType DWORD -Force -ErrorAction Ignore


Log-Message "Disable Windows Telemetry (CompatTelRunner.exe etc.)..."
Disable-ScheduledTask -ErrorAction Ignore -TaskPath '\Microsoft\Windows\Application Experience\' -TaskName 'Microsoft Compatibility Appraiser'
Disable-ScheduledTask -ErrorAction Ignore -TaskPath '\Microsoft\Windows\Application Experience\' -TaskName 'ProgramDataUpdater'
Get-Process -Name 'CompatTelRunner' -ErrorAction Ignore | Stop-Process -force -ErrorAction Ignore
Disable-ScheduledTask -ErrorAction Ignore -TaskPath '\Microsoft\Windows\Customer Experience Improvement Program\' -TaskName 'Consolidator'
Disable-ScheduledTask -ErrorAction Ignore -TaskPath '\Microsoft\Windows\Customer Experience Improvement Program\' -TaskName 'KernelCeipTask'
Disable-ScheduledTask -ErrorAction Ignore -TaskPath '\Microsoft\Windows\Customer Experience Improvement Program\' -TaskName 'UsbCeip'
Disable-ScheduledTask -ErrorAction Ignore -TaskPath '\Microsoft\Windows\DiskDiagnostic\' -TaskName 'Microsoft-Windows-DiskDiagnosticDataCollector'
Disable-ScheduledTask -ErrorAction Ignore -TaskPath '\Microsoft\Windows\Power Efficiency Diagnostics\' -TaskName 'AnalyzeSystem'
Disable-ScheduledTask -ErrorAction Ignore -TaskPath '\Microsoft\Windows\Windows Error Reporting\' -TaskName 'QueueReporting'
Stop-Service -Force -Name 'DiagTrack' -ErrorAction Ignore
Set-Service -Name 'DiagTrack' -StartupType Disabled -ErrorAction Ignore

$regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Metadata"
if (!(Test-Path $regPath))
{
  New-Item -Path $regPath -Force -ErrorAction Ignore
}
New-ItemProperty -Path $regPath -Name "PreventDeviceMetadataFromNetwork" -Value 1 -PropertyType DWORD -Force -ErrorAction Ignore

$regPath = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\DataCollection"
if (!(Test-Path $regPath))
{
  New-Item -Path $regPath -Force -ErrorAction Ignore
}
New-ItemProperty -Path $regPath -Name "AllowTelemetry" -Value 0 -PropertyType DWORD -Force -ErrorAction Ignore

$regPath = "HKLM:\SOFTWARE\Policies\Microsoft\SQMClient\Windows"
if (!(Test-Path $regPath))
{
  New-Item -Path $regPath -Force -ErrorAction Ignore
}
New-ItemProperty -Path $regPath -Name "CEIPEnable" -Value 0 -PropertyType DWORD -Force -ErrorAction Ignore

$regPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat"
if (!(Test-Path $regPath))
{
  New-Item -Path $regPath -Force -ErrorAction Ignore
}
New-ItemProperty -Path $regPath -Name "AITEnable" -Value 0 -PropertyType DWORD -Force -ErrorAction Ignore
New-ItemProperty -Path $regPath -Name "DisableUAR" -Value 1 -PropertyType DWORD -Force -ErrorAction Ignore

$regPath = "HKLM:\Software\Policies\Microsoft\Windows\DataCollection"
if (!(Test-Path $regPath))
{
  New-Item -Path $regPath -Force -ErrorAction Ignore
}
New-ItemProperty -Path $regPath -Name  "AllowTelemetry" -Value 0 -PropertyType DWORD -Force -ErrorAction Ignore

$regPath = "HKLM:\SOFTWARE\Wow6432Node\Policies\Microsoft\Windows\DataCollection"
if (!(Test-Path $regPath))
{
  New-Item -Path $regPath -Force -ErrorAction Ignore
}
New-ItemProperty -Path $regPath -Name "AllowTelemetry" -Value 0 -PropertyType DWORD -Force -ErrorAction Ignore

$regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\WMI\AutoLogger\AutoLogger-Diagtrack-Listener"
if (!(Test-Path $regPath))
{
  New-Item -Path $regPath -Force -ErrorAction Ignore
}
New-ItemProperty -Path $regPath -Name "Start" -Value 0 -PropertyType DWORD -Force -ErrorAction Ignore

$regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\WMI\AutoLogger\SQMLogger"
if (!(Test-Path $regPath))
{
  New-Item -Path $regPath -Force -ErrorAction Ignore
}
New-ItemProperty -Path $regPath -Name "Start" -Value 0 -PropertyType DWORD -Force -ErrorAction Ignore

$regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\DiagTrack"
if (!(Test-Path $regPath))
{
  New-Item -Path $regPath -Force -ErrorAction Ignore
}
New-ItemProperty -Path $regPath -Name "Start" -Value 4 -PropertyType DWORD -Force -ErrorAction Ignore

Log-Message "Disable Misc. Scheduled Tasks..."
Disable-ScheduledTask -ErrorAction Ignore -TaskPath '\Microsoft\Windows\.NET Framework\' -TaskName '.NET Framework NGEN v4.0.30319'
Disable-ScheduledTask -ErrorAction Ignore -TaskPath '\Microsoft\Windows\.NET Framework\' -TaskName '.NET Framework NGEN v4.0.30319 64'
Disable-ScheduledTask -ErrorAction Ignore -TaskPath '\Microsoft\Windows\AppID\' -TaskName 'SmartScreenSpecific'
Disable-ScheduledTask -ErrorAction Ignore -TaskPath '\Microsoft\Windows\ApplicationData\' -TaskName 'DsSvcCleanup'
Disable-ScheduledTask -ErrorAction Ignore -TaskPath '\Microsoft\Windows\Autochk\' -TaskName 'Proxy'
Disable-ScheduledTask -ErrorAction Ignore -TaskPath '\Microsoft\Windows\Chkdsk\' -TaskName 'ProactiveScan'
Disable-ScheduledTask -ErrorAction Ignore -TaskPath '\Microsoft\Windows\Data Integrity Scan\' -TaskName 'Data Integrity Scan'
Disable-ScheduledTask -ErrorAction Ignore -TaskPath '\Microsoft\Windows\Data Integrity Scan\' -TaskName 'Data Integrity Scan for Crash Recovery'
Disable-ScheduledTask -ErrorAction Ignore -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag'
Disable-ScheduledTask -ErrorAction Ignore -TaskPath '\Microsoft\Windows\Diagnosis\' -TaskName 'Scheduled'
Disable-ScheduledTask -ErrorAction Ignore -TaskPath '\Microsoft\Windows\maintenance\' -TaskName 'winsat'
Disable-ScheduledTask -ErrorAction Ignore -TaskPath '\Microsoft\Windows\PI\' -TaskName 'Sqm-Tasks'
Disable-ScheduledTask -ErrorAction Ignore -TaskPath '\Microsoft\Windows\Server Manager\' -TaskName 'ServerManager'
Disable-ScheduledTask -ErrorAction Ignore -TaskPath '\' -TaskName 'GoogleUpdateTaskMachineCore'
Disable-ScheduledTask -ErrorAction Ignore -TaskPath '\' -TaskName 'GoogleUpdateTaskMachineUA'
Disable-ScheduledTask -ErrorAction Ignore -TaskPath "\Microsoft\Windows\Speech\" -TaskName 'SpeechModelDownloadTask'
Get-ScheduledTask -TaskPath '\Microsoft\XblGameSave\' -ErrorAction Ignore | Disable-ScheduledTask -ErrorAction Ignore
Stop-Service -Force -Name 'PcaSvc' -ErrorAction Ignore
Set-Service -Name 'PcaSvc' -StartupType Disabled -ErrorAction Ignore
Set-Service -name SysMain -StartupType Disabled -ErrorAction Ignore
Set-Service -name gupdate -StartupType Disabled -ErrorAction Ignore
Set-Service -name gupdatem -StartupType Disabled -ErrorAction Ignore

Log-Message "Disable Azure Security Scheduled Tasks..."
Disable-ScheduledTask -ErrorAction Ignore -TaskPath '\Microsoft\Azure\Security\' -TaskName 'MonitoringOnceASMSERVICE'
Disable-ScheduledTask -ErrorAction Ignore -TaskPath '\Microsoft\Azure\Security\' -TaskName 'MonitoringOnceDETECTIONSERVICE'
Disable-ScheduledTask -ErrorAction Ignore -TaskPath '\Microsoft\Azure\Security\' -TaskName 'MonitoringOnceRELIANCESERVICE'
Disable-ScheduledTask -ErrorAction Ignore -TaskPath '\Microsoft\Azure\Security\' -TaskName 'MonitoringOnStartASMSERVICE'
Disable-ScheduledTask -ErrorAction Ignore -TaskPath '\Microsoft\Azure\Security\' -TaskName 'MonitoringOnStartDETECTIONSERVICE'
Disable-ScheduledTask -ErrorAction Ignore -TaskPath '\Microsoft\Azure\Security\' -TaskName 'MonitoringOnStartRELIANCESERVICE'

$regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance"
if (!(Test-Path $regPath))
{
  New-Item -Path $regPath -Force -ErrorAction Ignore
}
New-ItemProperty -Path $regPath -Name 'MaintenanceDisabled' -Value 1 -PropertyType DWORD -Force -ErrorAction Ignore

$regPath = "HKLM:\SOFTWARE\Policies\Microsoft\MRT"
if (!(Test-Path $regPath))
{
  New-Item -Path $regPath -Force -ErrorAction Ignore
}
New-ItemProperty -Path $regPath -Name 'DontOfferThroughWUAU' -Value 1 -PropertyType DWORD -Force -ErrorAction Ignore
New-ItemProperty -Path $regPath -Name 'DontReportInfectionInformation' -Value 1 -PropertyType DWORD -Force -ErrorAction Ignore

$regPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"; $name = "AllowCortana"; $value = 0;
if (!(Test-Path $regPath))
{
  New-Item -Path $regPath -Force -ErrorAction Ignore
}
New-ItemProperty -Path $regPath -Name "AllowCortana" -Value 0 -PropertyType DWORD -Force -ErrorAction Ignore

$regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\dmwappushservice"
if (!(Test-Path $regPath))
{
  New-Item -Path $regPath -Force -ErrorAction Ignore
}
New-ItemProperty -Path $regPath -Name "Start" -Value 4 -PropertyType DWORD -Force -ErrorAction Ignore

Write-Host "Disable Template Services / User Services added by Desktop Experience"
$regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\CDPUserSvc"
if (!(Test-Path $regPath)) {
  New-Item -Path $regPath -Force -ErrorAction Ignore
}
New-ItemProperty -Path $regPath -Name 'Start' -Value 4 -PropertyType DWORD -Force -ErrorAction Ignore
New-ItemProperty -Path $regPath -Name 'UserServiceFlags' -Value 0 -PropertyType DWORD -Force -ErrorAction Ignore

$regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\OneSyncSvc"
if (!(Test-Path $regPath))
{
  New-Item -Path $regPath -Force -ErrorAction Ignore
}
New-ItemProperty -Path $regPath -Name 'Start' -Value 4 -PropertyType DWORD -Force -ErrorAction Ignore
New-ItemProperty -Path $regPath -Name 'UserServiceFlags' -Value 0 -PropertyType DWORD -Force -ErrorAction Ignore

$regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\PimIndexMaintenanceSvc"
if (!(Test-Path $regPath))
{
  New-Item -Path $regPath -Force -ErrorAction Ignore
}
New-ItemProperty -Path $regPath -Name 'Start' -Value 4 -PropertyType DWORD -Force -ErrorAction Ignore
New-ItemProperty -Path $regPath -Name 'UserServiceFlags' -Value 0 -PropertyType DWORD -Force -ErrorAction Ignore

$regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\UnistoreSvc"
if (!(Test-Path $regPath))
{
  New-Item -Path $regPath -Force -ErrorAction Ignore
}
New-ItemProperty -Path $regPath -Name 'Start' -Value 4 -PropertyType DWORD -Force -ErrorAction Ignore
New-ItemProperty -Path $regPath -Name 'UserServiceFlags' -Value 0 -PropertyType DWORD -Force -ErrorAction Ignore

$regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\UserDataSvc"
if (!(Test-Path $regPath))
{
  New-Item -Path $regPath -Force -ErrorAction Ignore
}
New-ItemProperty -Path $regPath -Name 'Start' -Value 4 -PropertyType DWORD -Force -ErrorAction Ignore
New-ItemProperty -Path $regPath -Name 'UserServiceFlags' -Value 0 -PropertyType DWORD -Force -ErrorAction Ignore

$regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\WpnUserService"
if (!(Test-Path $regPath))
{
  New-Item -Path $regPath -Force -ErrorAction Ignore
}
New-ItemProperty -Path $regPath -Name 'Start' -Value 4 -PropertyType DWORD -Force -ErrorAction Ignore
New-ItemProperty -Path $regPath -Name 'UserServiceFlags' -Value 0 -PropertyType DWORD -Force -ErrorAction Ignore

$regPath = "HKLM:\SYSTEM\CurrentControlSet\Control"
if (!(Test-Path $regPath))
{
  New-Item -Path $regPath -Force -ErrorAction Ignore
}

New-ItemProperty -Path $regPath -Name "ServicesPipeTimeout" -Value 120000 -PropertyType DWORD -Force -ErrorAction Ignore
Write-Host "Done with MMS Initialization steps"
# End MMS Initialization steps

# set the agent working directory to 'C:\a' if the environment variable is not set already
$workDir = [System.Environment]::GetEnvironmentVariable('VSTS_AGENT_INPUT_WORK')
if (![string]::IsNullOrEmpty($workDir))
{
    Log-Message ("Found WorkDir: " + $workDir)
}
else
{
    $drive = (Get-Location).Drive.Name + ":"
    $workDir = Join-Path -Path $drive -ChildPath "a"
    [System.Environment]::SetEnvironmentVariable('VSTS_AGENT_INPUT_WORK', $workDir, [System.EnvironmentVariableTarget]::Process)
    [System.Environment]::SetEnvironmentVariable('VSTS_AGENT_INPUT_WORK', $workDir, [System.EnvironmentVariableTarget]::Machine)
    Log-Message ("Setting WorkDir: " + $workDir)
}

# unzip the agent if it doesn't exist already
if (!(Test-Path -Path $agentExe))
{
   Log-Message "Unzipping Agent"
   try
   {
      [System.IO.Compression.ZipFile]::ExtractToDirectory($agentZip, $agentDir)
      Remove-Item $agentZip
   }
   catch
   {
      Log-Message $Error[0]
      exit -100
   }
}

$extra = ""
$proxy_url_variable = ""
if ($env:http_proxy)
{
   $proxy_url_variable=$env:http_proxy
}
elseif ($env:https_proxy)
{
   $proxy_url_variable=$env:https_proxy      
}

if ($proxy_url_variable)
{
   Log-Message "Found a proxy configuration"
   $proxy_username = ""
   $proxy_password = ""
   $proxy_url = ""

   if ( $proxy_url_variable -NotMatch "@")
   {
      $proxy_url = $proxy_url_variable
      $extra = "--proxyurl $proxy_url_variable"
      Log-Message "Found proxy url $proxy_url"
   }
   else
   {
      $proxy_url = "$([regex]::match($proxy_url_variable, '.+\/\/').Groups[0].Value)$([regex]::match($proxy_url_variable, '@(.*)').Groups[1].Value)"
      $proxy_username = [regex]::match($proxy_url_variable, ':\/\/([^:]+)\:').Groups[1].Value
      $proxy_password = [regex]::match($proxy_url_variable, ':[^:]+:([^@]+)@').Groups[1].Value

      $proxy_username = [System.Net.WebUtility]::UrlDecode($proxy_username)
      $proxy_password = [System.Net.WebUtility]::UrlDecode($proxy_password)
      $extra = "--proxyurl $proxy_url --proxyusername $proxy_username --proxypassword $proxy_password"
      Log-Message "Found proxy url $proxy_url and authentication info"
  }
}

if ($runAsUser)
{
   # create administrator account if the image owner has not already done that for us
   if (-not $username)
   {
      $username = 'AzDevOps'
   }
   $password = (New-Guid).ToString()
   $securePassword = ConvertTo-SecureString $password -AsPlainText -Force

   if (!(Get-LocalUser -Name $username -ErrorAction Ignore))
   {
      Log-Message "Creating $username user"
      New-LocalUser -Name $username -Password $securePassword
   }
   else
   {
      Log-Message "Setting $username password"
      Set-LocalUser -Name $username -Password $securePassword 
   }

   # Confirm the local user exists or abort if not
   if (!(Get-LocalUser -Name $username))
   {
      Log-Message "Failed to create $username user"
      exit -105
   }

   if ((Get-LocalGroup -Name "Users" -ErrorAction Ignore) -and
       !(Get-LocalGroupMember -Group "Users" -Member $username -ErrorAction Ignore))
   {
      Log-Message "Adding $username to Users"
      Add-LocalGroupMember -Group "Users" -Member $username
   }
   if ((Get-LocalGroup -Name "Administrators" -ErrorAction Ignore) -and
       !(Get-LocalGroupMember -Group "Administrators" -Member $username -ErrorAction Ignore))
   {
      Log-Message "Adding $username to Administrators"
      Add-LocalGroupMember -Group "Administrators" -Member $username
   }
   if ((Get-LocalGroup -Name "docker-users" -ErrorAction Ignore) -and
       !(Get-LocalGroupMember -Group "docker-users" -Member $username -ErrorAction Ignore))
   {
      Log-Message "Adding $username to docker-users"
      Add-LocalGroupMember -Group "docker-users" -Member $username
   }

   if ($interactive)
   {
      Log-Message "Configuring agent to reboot, autologon, and run unelevated as $username with interactive UI \n In case of failure check the agent logs"
      $configParameters = " --unattended --url $url --pool ""$pool"" --auth pat --replace --runAsAutoLogon --overwriteAutoLogon --windowsLogonAccount $username --windowsLogonPassword $password --token $token $runArgs $extra"
      try
      {
         Start-Process -FilePath $agentConfig -ArgumentList $configParameters -NoNewWindow -Wait -WorkingDirectory $agentDir
      }
      catch
      {
         Log-Message $Error[0]
         exit -102
      }
   }
   elseif(-not [string]::IsNullOrEmpty($runArgs))
   {
      # Run as a normal process and configure the agent to run once and stop
      Log-Message "Configuring agent to run once with elevated process running as $username"
      $configParameters = " --unattended --url $url --pool ""$pool"" --auth pat --replace --windowsLogonAccount $username --windowsLogonPassword $password --token $token $extra"
      try
      {
         Start-Process -FilePath $agentConfig -ArgumentList $configParameters -NoNewWindow -Wait -WorkingDirectory $agentDir
      }
      catch
      {
         Log-Message $Error[0]
         exit -106
      }

      Log-Message "Scheduling agent to run"
      $runCmd = Join-Path -Path $agentDir -ChildPath "run.cmd"
      try
      {
         $cmd1 = New-ScheduledTaskAction -Execute $runCmd -WorkingDirectory $agentDir $runArgs
         $start1 = (Get-Date).AddSeconds(10)
         $time1 = New-ScheduledTaskTrigger -At $start1 -Once 
         Register-ScheduledTask -TaskName "PipelinesAgent" -User $username -Password $password -RunLevel Highest -Trigger $time1 -Action $cmd1 -Force
      }
      catch
      {
          Log-Message $Error[0]
          exit -108
      }
   }
   else
   {
      # Only run as a Windows service for multi-use VMs because RunOnce is not supported when running as a service
      Log-Message "Configuring agent to run elevated as $username and as a Windows service"
      $configParameters = " --unattended --url $url --pool ""$pool"" --auth pat --replace --runAsService --windowsLogonAccount $username --windowsLogonPassword $password --token $token $extra" 
      try
      {
         Start-Process -FilePath $agentConfig -ArgumentList $configParameters -NoNewWindow -Wait -WorkingDirectory $agentDir
      }
      catch
      {
         Log-Message $Error[0]
         exit -106
      }
   }
}
else
{
   Log-Message "Configuring agent to run as a service as NetworkService"

   $configParameters = " --unattended --url $url --pool ""$pool"" --auth pat --replace --runAsService --token $token $runArgs $extra"
   try
   {
      Start-Process -FilePath $agentConfig -ArgumentList $configParameters -NoNewWindow -Wait -WorkingDirectory $agentDir
   }
   catch
   {
      Log-Message $Error[0]
      exit -107
   }
}

Log-Message "Finished"
