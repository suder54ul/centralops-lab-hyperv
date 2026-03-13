This is the final, end-to-end technical guide for your Windows Server 2025 Core infrastructure. This version utilizes a Global Variable Table for automation and clearly marks where VM Restarts and Manual Interventions are required.
1. Global Configuration Table
Define this in your VS Code environment. All subsequent scripts pull from this table.
powershell
$GlobalConfig = @{
    # Domain & Identity
    DomainName      = "corp.local"
    NetBIOSName     = "CORP"
    SafePassword    = (ConvertTo-SecureString "P@ssword123!" -AsPlainText -Force)
    AdminUser       = "admin01"
    StandardUser    = "user01"
    HmiDevice       = "hmi01"

    # Network 1: Admin (10.5.1.0/24)
    AdminNet_GW     = "10.5.1.1"
    PrimaryDC_IP    = "10.5.1.10"
    MgmtServer_IP   = "10.5.1.20"

    # Network 2: Replica (10.1.1.0/24)
    ReplicaNet_GW   = "10.1.1.1"
    ReplicaDC_IP    = "10.1.1.10"

    # Infrastructure Paths
    GoldImagePath   = "C:\VMs\GoldImage\W2025Core.vhdx"
    WsusPath        = "D:\WSUS"
    MirrorPath      = "D:\DefenderMirror"
}
Use code with caution.

2. Phase 1: The Gold Image (Manual Preparation)
The Gold Image must be prepared manually before any automation begins.
Install OS: Install Windows Server 2025 Core.
Config: Run sconfig to set the timezone and install all Windows Updates.
Sysprep: Open PowerShell and run:
C:\Windows\System32\Sysprep\sysprep.exe /oobe /generalize /shutdown /mode:vm
RESTART/SHUTDOWN: The VM will shut down. Do not turn it back on. This is now your Master Template.
3. Phase 2: VyOS Firewall (Manual Intervention)
You must manually enter these commands into your VyOS CLI to enable the bridge.
bash
configure
set interfaces ethernet eth0 address 10.5.1.1/24
set interfaces ethernet eth1 address 10.1.1.1/24
set system ip forward 1
set firewall name ALLOW_ALL default-action accept
set firewall interface eth0 in name ALLOW_ALL
set firewall interface eth1 in name ALLOW_ALL
commit ; save ; exit
Use code with caution.

4. Phase 3: Infrastructure Deployment (PowerShell)
A. Primary DC (SRV-DC-01)
Promote Forest:
powershell
Install-ADDSForest -DomainName $GlobalConfig.DomainName -InstallDNS -Force
Use code with caution.

RESTART: The server will automatically reboot to finalize AD.
Post-Reboot (Manual/Scripted): Log in and run the object creation:
powershell
# Create Objects
New-ADUser -Name $GlobalConfig.StandardUser -SamAccountName $GlobalConfig.StandardUser -Enabled $true -AccountPassword $GlobalConfig.SafePassword
New-ADUser -Name $GlobalConfig.AdminUser -SamAccountName $GlobalConfig.AdminUser -Enabled $true -AccountPassword $GlobalConfig.SafePassword
Add-ADGroupMember -Identity "Domain Admins" -Members $GlobalConfig.AdminUser
New-ADComputer -Name $GlobalConfig.HmiDevice -SamAccountName $GlobalConfig.HmiDevice

# Authorize & Prep Cloning for DC-02
Add-ADGroupMember -Identity "Cloneable Domain Controllers" -Members "SRV-DC-01$"
Get-ADDCCloningExcludedApplicationList -GenerateXml
New-ADDCCloneConfigFile -CloneComputerName "SRV-DC-02" -Static `
-IPv4Address $GlobalConfig.ReplicaDC_IP -IPv4SubnetMask "255.255.255.0" `
-IPv4DefaultGateway $GlobalConfig.ReplicaNet_GW -IPv4DNSResolver $GlobalConfig.PrimaryDC_IP
Use code with caution.

SHUTDOWN: Shut down SRV-DC-01 to perform the Hyper-V Clone.
B. Replica DC (SRV-DC-02)
Clone VM: Use Hyper-V to copy SRV-DC-01 (Select "Create new unique ID").
RESTART: Power on SRV-DC-01 first, wait 2 minutes, then power on SRV-DC-02.
Result: SRV-DC-02 will detect the XML file, rename itself, and reboot automatically.
C. Update Hub (SRV-MGMT-01)
Install Roles:
powershell
Install-WindowsFeature UpdateServices, Web-Server -IncludeManagementTools
Use code with caution.

RESTART: A restart is recommended after installing WSUS.
Manual/Post-Install:
powershell
# Create Shares
New-SmbShare -Name "DefenderUpdates" -Path $GlobalConfig.MirrorPath -FullAccess "Everyone"
# Init WSUS
& "C:\Program Files\Update Services\Tools\wsusutil.exe" postinstall CONTENT_DIR=$GlobalConfig.WsusPath
Use code with caution.

5. Phase 4: GPO Implementation (PowerShell Scripted)
Run this on SRV-DC-01 after all servers are joined to the domain.
powershell
# 1. Password Policy
Set-ADDefaultDomainPasswordPolicy -Identity $GlobalConfig.DomainName -MinPasswordLength 12 -MaxPasswordAge "90.00:00:00" -ComplexityEnabled $true

# 2. Monthly Security Updates GPO
$GPO_Update = New-GPO -Name "CORP-Update-Policy"
Set-GPRegistryValue -Name "CORP-Update-Policy" -Key "HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate" -ValueName "WUServer" -Type String -Value "http://$($GlobalConfig.MgmtServer_IP):8530"
Set-GPLink -Name "CORP-Update-Policy" -Target "dc=$($GlobalConfig.NetBIOSName),dc=local"

# 3. HMI/Screensaver GPO
$GPO_HMI = New-GPO -Name "CORP-HMI-Fix"
Set-GPRegistryValue -Name "CORP-HMI-Fix" -Key "HKCU\Software\Policies\Microsoft\Windows\Control Panel\Desktop" -ValueName "ScreenSaveActive" -Type String -Value "0"
Set-GPLink -Name "CORP-HMI-Fix" -Target "dc=$($GlobalConfig.NetBIOSName),dc=local"
Use code with caution.

6. Final Health Test (Automated Verification)
Run this from your ADMIN-PC in VS Code.
powershell
$Tests = @()
# Verify VyOS Routing
$Ping = Test-Connection -ComputerName $GlobalConfig.ReplicaDC_IP -Count 1 -Quiet
$Tests += [PSCustomObject]@{Test="VyOS Routing (10.5 -> 10.1)"; Result=($Ping ? "PASS" : "FAIL")}

# Verify AD Replication
$Rep = Invoke-Command -ComputerName $GlobalConfig.PrimaryDC_IP -ScriptBlock { repadmin /replsummary }
$Tests += [PSCustomObject]@{Test="AD Replication Health"; Result=($Rep -match "0 errors" ? "PASS" : "FAIL")}

$Tests | Format-Table -AutoSize
Use code with caution.

Key Resource Details:
SRV-DC-01/02: 2 vCPU, 4GB RAM.
SRV-MGMT-01: 2 vCPU, 8GB RAM (Critical for WSUS Java/SQL services).
VyOS: 1 vCPU, 512MB RAM.
Would you like the PowerShell script to automate the Hyper-V VM creation process from your Gold Image?




