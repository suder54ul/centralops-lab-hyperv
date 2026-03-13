[CmdletBinding(PositionalBinding = $false, SupportsShouldProcess)]
param(
    [ValidateSet('All', 'VyOSGuide', 'HyperVDeploy', 'PrimaryDC', 'GPO', 'HealthCheck', 'Summary')]
    [string[]]$Stages = @('All'),

    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\lab.config.psd1'),

    [string]$LogPath = (Join-Path $PSScriptRoot "..\logs\deploy-$((Get-Date).ToString('yyyyMMdd-HHmmss')).log")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Section {
    param(
        [Parameter(Mandatory)]
        [string]$Title
    )

    Write-Host "`n=== $Title ===" -ForegroundColor Yellow
}

function Write-Step {
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ConsoleColor]$Color = 'Cyan'
    )

    Write-Host $Message -ForegroundColor $Color
}

function Import-LabConfig {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -Path $Path)) {
        throw "Configuration file not found: $Path"
    }

    $cfg = Import-PowerShellDataFile -Path $Path

    $requiredKeys = @(
        'DomainName', 'DomainNetBIOS', 'SafePassword', 'AdminUser', 'StandardUser', 'HmiDevice',
        'AdminNet_GW', 'PrimaryDC_IP', 'MgmtServer_IP', 'AdminPC_IP',
        'ReplicaNet_GW', 'ReplicaDC_IP',
        'GoldImagePath', 'WsusContentPath', 'MirrorPath',
        'VMRootPath', 'AdminSwitchName', 'ReplicaSwitchName'
    )

    foreach ($key in $requiredKeys) {
        if (-not $cfg.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$cfg[$key])) {
            throw "Missing required key '$key' in config file: $Path"
        }
    }

    return $cfg
}

function Get-SafePassword {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    return ConvertTo-SecureString $Config.SafePassword -AsPlainText -Force
}

function Assert-Elevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if (-not $isAdmin) {
        throw 'This script must be run in an elevated PowerShell session (Run as Administrator).'
    }
}

function Convert-DomainToDn {
    param(
        [Parameter(Mandatory)]
        [string]$DomainName
    )

    $parts = $DomainName.Split('.')
    if ($parts.Count -lt 2) {
        throw "Domain name '$DomainName' is invalid. Expected FQDN format like corp.local."
    }

    return ($parts | ForEach-Object { "DC=$_" }) -join ','
}

function Show-VyOSGuide {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    Write-Section 'VYOS ROUTER CONFIGURATION GUIDE'
    Write-Step 'Run these commands on your VyOS router in configuration mode:'

@"
configure

set interfaces ethernet eth0 address $($Config.AdminNet_GW)/24
set interfaces ethernet eth1 address $($Config.ReplicaNet_GW)/24
set interfaces ethernet eth0 description 'Admin-Network'
set interfaces ethernet eth1 description 'Replica-Network'

set system ip forward 1

set firewall name ALLOW_ALL default-action accept
set firewall interface eth0 in name ALLOW_ALL
set firewall interface eth1 in name ALLOW_ALL

commit
save
show interfaces
"@ | Write-Host
}

function Invoke-HyperVDeployment {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    Write-Section 'HYPER-V VM DEPLOYMENT'

    Import-Module Hyper-V -ErrorAction Stop

    if (-not (Test-Path -Path $Config.GoldImagePath)) {
        throw "Gold image not found: $($Config.GoldImagePath)"
    }

    $requiredSwitches = @($Config.AdminSwitchName, $Config.ReplicaSwitchName)
    foreach ($switchName in $requiredSwitches) {
        if (-not (Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue)) {
            throw "Virtual switch not found: $switchName"
        }
    }

    $serverList = @(
        @{ Name = 'SRV-DC-01'; Role = 'Primary Domain Controller'; Network = 'Admin'; RAM = 4GB },
        @{ Name = 'SRV-DC-02'; Role = 'Replica Domain Controller'; Network = 'Replica'; RAM = 4GB },
        @{ Name = 'SRV-MGMT-01'; Role = 'Management Server (WSUS/Defender)'; Network = 'Admin'; RAM = 4GB }
    )

    foreach ($server in $serverList) {
        $serverName = $server.Name
        $vmFolder = Join-Path $Config.VMRootPath $serverName
        $vhdPath = Join-Path $vmFolder "$serverName.vhdx"

        Write-Step "Deploying $serverName - $($server.Role)"

        if (Get-VM -Name $serverName -ErrorAction SilentlyContinue) {
            Write-Step "  VM already exists, skipping: $serverName" 'DarkYellow'
            continue
        }

        if (-not (Test-Path -Path $vmFolder)) {
            New-Item -ItemType Directory -Path $vmFolder -Force | Out-Null
        }

        if ($PSCmdlet.ShouldProcess($serverName, 'Create differencing disk and VM')) {
            New-VHD -ParentPath $Config.GoldImagePath -Path $vhdPath -Differencing | Out-Null

            New-VM -Name $serverName -MemoryStartupBytes $server.RAM -VHDPath $vhdPath -Generation 2 | Out-Null

            $switchName = if ($server.Network -eq 'Admin') { $Config.AdminSwitchName } else { $Config.ReplicaSwitchName }
            Connect-VMNetworkAdapter -VMName $serverName -SwitchName $switchName
            Set-VMProcessor -VMName $serverName -ExposeVirtualizationExtensions $true

            Write-Step "  VM creation complete for $serverName" 'Green'
        }
    }
}

function Invoke-PrimaryDCConfiguration {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    Write-Section 'PRIMARY DOMAIN CONTROLLER SETUP (SRV-DC-01)'

    Import-Module ADDSDeployment -ErrorAction Stop
    Import-Module ActiveDirectory -ErrorAction Stop
    Import-Module DnsServer -ErrorAction Stop

    $safePassword = Get-SafePassword -Config $Config

    Write-Step 'Step 1: Promoting to Domain Controller...'
    if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Install AD DS forest')) {
        $forestParams = @{
            DomainName                    = $Config.DomainName
            DomainNetbiosName             = $Config.DomainNetBIOS
            InstallDNS                    = $true
            SafeModeAdministratorPassword = $safePassword
            Force                         = $true
            NoRebootOnCompletion          = $true
        }
        Install-ADDSForest @forestParams

        Start-Sleep -Seconds 30
        Write-Step '  AD Forest installation initiated' 'Green'
    }

    Write-Step 'Step 2: Creating OU structure...'
    $domainDn = Convert-DomainToDn -DomainName $Config.DomainName
    $ouRoot = "OU=$($Config.DomainNetBIOS),$domainDn"

    if (-not (Get-ADOrganizationalUnit -LDAPFilter "(ou=$($Config.DomainNetBIOS))" -SearchBase $domainDn -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name $Config.DomainNetBIOS -Path $domainDn -ProtectedFromAccidentalDeletion $true
    }

    foreach ($ou in @('Servers', 'Workstations', 'Users', 'Groups', 'HMIDevices')) {
        if (-not (Get-ADOrganizationalUnit -LDAPFilter "(ou=$ou)" -SearchBase $ouRoot -ErrorAction SilentlyContinue)) {
            New-ADOrganizationalUnit -Name $ou -Path $ouRoot
        }
    }

    Write-Step 'Step 3: Creating user accounts...'
    if (-not (Get-ADUser -Identity $Config.AdminUser -ErrorAction SilentlyContinue)) {
        $adminUserParams = @{
            Name              = $Config.AdminUser
            SamAccountName    = $Config.AdminUser
            UserPrincipalName = "$($Config.AdminUser)@$($Config.DomainName)"
            GivenName         = 'Admin'
            Surname           = 'User'
            DisplayName       = 'Admin User'
            Description       = 'Domain Administrator'
            Enabled           = $true
            AccountPassword   = $safePassword
            Path              = "OU=Users,$ouRoot"
        }
        New-ADUser @adminUserParams
    }

    Add-ADGroupMember -Identity 'Domain Admins' -Members $Config.AdminUser -ErrorAction SilentlyContinue

    if (-not (Get-ADUser -Identity $Config.StandardUser -ErrorAction SilentlyContinue)) {
        $standardUserParams = @{
            Name              = $Config.StandardUser
            SamAccountName    = $Config.StandardUser
            UserPrincipalName = "$($Config.StandardUser)@$($Config.DomainName)"
            GivenName         = 'Standard'
            Surname           = 'User'
            DisplayName       = 'Standard User'
            Description       = 'Standard Domain User'
            Enabled           = $true
            AccountPassword   = $safePassword
            Path              = "OU=Users,$ouRoot"
        }
        New-ADUser @standardUserParams
    }

    Write-Step 'Step 4: Creating computer account...'
    if (-not (Get-ADComputer -Identity $Config.HmiDevice -ErrorAction SilentlyContinue)) {
        $computerParams = @{
            Name           = $Config.HmiDevice
            SamAccountName = $Config.HmiDevice
            Description    = 'HMI Device - Industrial Control'
            Path           = "OU=HMIDevices,$ouRoot"
            Enabled        = $true
        }
        New-ADComputer @computerParams
    }

    Write-Step 'Step 5: Configuring DNS forwarders...'
    foreach ($forwarder in @('8.8.8.8', '1.1.1.1')) {
        if (-not (Get-DnsServerForwarder -ErrorAction SilentlyContinue | Where-Object IPAddress -eq $forwarder)) {
            Add-DnsServerForwarder -IPAddress $forwarder | Out-Null
        }
    }

    Write-Step 'Step 6: Creating clone config for replica DC...'
    $cloneParams = @{
        CloneComputerName = 'SRV-DC-02'
        Static            = $true
        IPv4Address       = $Config.ReplicaDC_IP
        IPv4SubnetMask    = '255.255.255.0'
        IPv4DefaultGateway = $Config.ReplicaNet_GW
        IPv4DNSResolver   = $Config.PrimaryDC_IP
        SiteName          = 'Default-First-Site-Name'
        Force             = $true
    }
    New-ADDCCloneConfigFile @cloneParams

    Write-Step 'Clone configuration saved to C:\Windows\NTDS\DCCloneConfig.xml' 'Green'
}

function Invoke-GPOConfiguration {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    Write-Section 'GROUP POLICY CONFIGURATION'

    Import-Module GroupPolicy -ErrorAction Stop
    Import-Module ActiveDirectory -ErrorAction Stop

    $domainDn = Convert-DomainToDn -DomainName $Config.DomainName
    $hmiDn = "OU=HMIDevices,OU=$($Config.DomainNetBIOS),$domainDn"

    Write-Step 'Creating CORP-Update-Policy GPO...'
    if (-not (Get-GPO -Name 'CORP-Update-Policy' -ErrorAction SilentlyContinue)) {
        New-GPO -Name 'CORP-Update-Policy' -Comment 'Configures WSUS server for all updates' | Out-Null
    }

    Set-GPRegistryValue -Name 'CORP-Update-Policy' -Key 'HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate' -ValueName 'WUServer' -Type String -Value "http://$($Config.MgmtServer_IP):8530"
    Set-GPRegistryValue -Name 'CORP-Update-Policy' -Key 'HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate' -ValueName 'WUStatusServer' -Type String -Value "http://$($Config.MgmtServer_IP):8530"
    Set-GPRegistryValue -Name 'CORP-Update-Policy' -Key 'HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate\AU' -ValueName 'AUOptions' -Type DWord -Value 3
    Set-GPRegistryValue -Name 'CORP-Update-Policy' -Key 'HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate\AU' -ValueName 'ScheduledInstallDay' -Type DWord -Value 0
    Set-GPRegistryValue -Name 'CORP-Update-Policy' -Key 'HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate\AU' -ValueName 'ScheduledInstallTime' -Type DWord -Value 3

    if (-not (Get-GPInheritance -Target $domainDn | Select-Object -ExpandProperty GpoLinks | Where-Object DisplayName -eq 'CORP-Update-Policy')) {
        New-GPLink -Name 'CORP-Update-Policy' -Target $domainDn | Out-Null
    }

    Write-Step 'Creating CORP-HMI-NoScreensaver GPO...'
    if (-not (Get-GPO -Name 'CORP-HMI-NoScreensaver' -ErrorAction SilentlyContinue)) {
        New-GPO -Name 'CORP-HMI-NoScreensaver' -Comment 'Disables screensaver on HMI devices' | Out-Null
    }

    Set-GPRegistryValue -Name 'CORP-HMI-NoScreensaver' -Key 'HKCU\Software\Policies\Microsoft\Windows\Control Panel\Desktop' -ValueName 'ScreenSaveActive' -Type String -Value '0'
    Set-GPRegistryValue -Name 'CORP-HMI-NoScreensaver' -Key 'HKLM\Software\Policies\Microsoft\Power\PowerSettings\0e796bdb-100d-47d6-a2d5-f7d2daa51f51' -ValueName 'ACSettingIndex' -Type DWord -Value 0

    if (-not (Get-GPInheritance -Target $hmiDn | Select-Object -ExpandProperty GpoLinks | Where-Object DisplayName -eq 'CORP-HMI-NoScreensaver')) {
        New-GPLink -Name 'CORP-HMI-NoScreensaver' -Target $hmiDn | Out-Null
    }

    Write-Step 'Configuring domain password policy...'
    $pwdPolicyParams = @{
        Identity                    = $Config.DomainName
        MinPasswordLength           = 12
        MaxPasswordAge              = '90.00:00:00'
        MinPasswordAge              = '1.00:00:00'
        LockoutThreshold            = 5
        LockoutDuration             = '00:30:00'
        LockoutObservationWindow    = '00:30:00'
        ComplexityEnabled           = $true
        ReversibleEncryptionEnabled = $false
    }
    Set-ADDefaultDomainPasswordPolicy @pwdPolicyParams

    Write-Step 'Password policy configured: 12 char min, 90 day max, lockout after 5 attempts' 'Green'
}

function Invoke-HealthCheck {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    Write-Section 'DEPLOYMENT HEALTH CHECK'

    Import-Module ActiveDirectory -ErrorAction SilentlyContinue
    Import-Module GroupPolicy -ErrorAction SilentlyContinue

    $tests = @()

    Write-Step 'Testing VyOS routing...'
    $route = Test-Connection -ComputerName $Config.ReplicaDC_IP -Count 2 -Quiet -ErrorAction SilentlyContinue
    $tests += [PSCustomObject]@{
        Test = 'VyOS Routing (Admin -> Replica)'
        Result = if ($route) { 'PASS' } else { 'FAIL' }
        Details = if ($route) { 'Successfully pinged replica DC across networks' } else { 'Cannot reach replica DC - check VyOS config' }
    }

    Write-Step 'Testing Primary DC services...'
    $adService = Get-Service -Name NTDS -ComputerName $Config.PrimaryDC_IP -ErrorAction SilentlyContinue
    $tests += [PSCustomObject]@{
        Test = 'AD DS Service (Primary DC)'
        Result = if ($adService -and $adService.Status -eq 'Running') { 'PASS' } else { 'FAIL' }
        Details = if ($adService -and $adService.Status -eq 'Running') { 'Active Directory running' } else { 'AD DS service not running' }
    }

    $dnsService = Get-Service -Name DNS -ComputerName $Config.PrimaryDC_IP -ErrorAction SilentlyContinue
    $tests += [PSCustomObject]@{
        Test = 'DNS Service (Primary DC)'
        Result = if ($dnsService -and $dnsService.Status -eq 'Running') { 'PASS' } else { 'FAIL' }
        Details = if ($dnsService -and $dnsService.Status -eq 'Running') { 'DNS service running' } else { 'DNS service not running' }
    }

    Write-Step 'Testing WSUS endpoint...'
    $wsus = Test-NetConnection -ComputerName $Config.MgmtServer_IP -Port 8530 -InformationLevel Quiet -WarningAction SilentlyContinue
    $tests += [PSCustomObject]@{
        Test = 'WSUS Port 8530'
        Result = if ($wsus) { 'PASS' } else { 'FAIL' }
        Details = if ($wsus) { 'WSUS endpoint reachable' } else { 'Cannot connect to WSUS - check management server' }
    }

    Write-Step 'Verifying user accounts...'
    $adminUser = Get-ADUser -Identity $Config.AdminUser -ErrorAction SilentlyContinue
    $tests += [PSCustomObject]@{
        Test = 'Admin User Creation'
        Result = if ($adminUser) { 'PASS' } else { 'FAIL' }
        Details = if ($adminUser) { 'Admin user exists in AD' } else { 'Admin user not found' }
    }

    Write-Step 'Verifying GPOs...'
    $updateGPO = Get-GPO -Name 'CORP-Update-Policy' -ErrorAction SilentlyContinue
    $tests += [PSCustomObject]@{
        Test = 'Update Policy GPO'
        Result = if ($updateGPO) { 'PASS' } else { 'FAIL' }
        Details = if ($updateGPO) { 'Update GPO exists' } else { 'Update GPO not found' }
    }

    Write-Section 'HEALTH CHECK RESULTS'
    $tests | Format-Table -AutoSize

    $passCount = ($tests | Where-Object Result -eq 'PASS').Count
    $totalCount = $tests.Count

    Write-Host "`nSUMMARY: $passCount of $totalCount tests passed" -ForegroundColor $(if ($passCount -eq $totalCount) { 'Green' } else { 'Yellow' })

    if ($passCount -eq $totalCount) {
        Write-Host 'DEPLOYMENT SUCCESSFUL - All systems operational' -ForegroundColor Green
    }
    else {
        Write-Host 'DEPLOYMENT PARTIAL - Review failed tests and troubleshoot' -ForegroundColor Yellow
    }

    return $tests
}

function Show-DeploymentSummary {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    Write-Host "`n"
    Write-Host ('=' * 60) -ForegroundColor Cyan
    Write-Host 'DEPLOYMENT COMPLETE' -ForegroundColor White -BackgroundColor DarkGreen
    Write-Host ('=' * 60) -ForegroundColor Cyan
    Write-Host "Domain: $($Config.DomainName)"
    Write-Host "Primary DC: SRV-DC-01 ($($Config.PrimaryDC_IP))"
    Write-Host "Replica DC: SRV-DC-02 ($($Config.ReplicaDC_IP))"
    Write-Host "Management Server: SRV-MGMT-01 ($($Config.MgmtServer_IP))"
    Write-Host "Admin User: $($Config.AdminUser)"
    Write-Host "Standard User: $($Config.StandardUser)"
    Write-Host "HMI Device: $($Config.HmiDevice)"
    Write-Host ''
    Write-Host 'Next Steps:'
    Write-Host '1. Configure SRV-DC-02 as replica using clone media'
    Write-Host '2. Install WSUS role on SRV-MGMT-01'
    Write-Host '3. Join client machines to domain'
    Write-Host '4. Test GPO application on clients'
    Write-Host ('=' * 60) -ForegroundColor Cyan
}

function Resolve-StageList {
    param(
        [string[]]$Requested
    )

    if ($Requested -contains 'All') {
        return @('VyOSGuide', 'HyperVDeploy', 'PrimaryDC', 'GPO', 'HealthCheck', 'Summary')
    }

    return $Requested
}

function Test-RequiresElevation {
    param(
        [Parameter(Mandatory)]
        [string[]]$ResolvedStages
    )

    $elevatedStages = @('HyperVDeploy', 'PrimaryDC', 'GPO', 'HealthCheck')
    return [bool]($ResolvedStages | Where-Object { $_ -in $elevatedStages })
}

function Initialize-Logging {
    param(
        [Parameter(Mandatory)]
        [string]$TargetLogPath
    )

    $logDirectory = Split-Path -Path $TargetLogPath -Parent
    if (-not (Test-Path -Path $logDirectory)) {
        New-Item -Path $logDirectory -ItemType Directory -Force | Out-Null
    }

    Start-Transcript -Path $TargetLogPath -Force | Out-Null
    Write-Step "Logging transcript to: $TargetLogPath" 'DarkGray'
}

try {
    $resolvedStages = Resolve-StageList -Requested $Stages
    if (Test-RequiresElevation -ResolvedStages $resolvedStages) {
        Assert-Elevated
    }

    Initialize-Logging -TargetLogPath $LogPath

    $config = Import-LabConfig -Path $ConfigPath

    foreach ($stage in $resolvedStages) {
        switch ($stage) {
            'VyOSGuide'   { Show-VyOSGuide -Config $config }
            'HyperVDeploy' { Invoke-HyperVDeployment -Config $config }
            'PrimaryDC'   { Invoke-PrimaryDCConfiguration -Config $config }
            'GPO'         { Invoke-GPOConfiguration -Config $config }
            'HealthCheck' { Invoke-HealthCheck -Config $config | Out-Null }
            'Summary'     { Show-DeploymentSummary -Config $config }
            default       { throw "Unsupported stage: $stage" }
        }
    }
}
catch {
    Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
    throw
}
finally {
    try {
        Stop-Transcript | Out-Null
    }
    catch {
    }
}
