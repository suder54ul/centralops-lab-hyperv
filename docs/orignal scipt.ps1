This is the final, comprehensive automation guide for your Windows Server 2025 Core infrastructure. It integrates the Gold Image strategy, Hyper-V automation, VyOS routing, and PowerShell-driven GPOs using a single global variable table.
1. Global Configuration Table
Define this in your VS Code environment. All scripts below reference these variables.
powershell
$GlobalConfig = @{
    # Domain & Identity
    DomainName      = "corp.local"
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
    GoldImagePath   = "C:\VMs\GoldImage\W2025Core.vhdx" # Must be Sysprepped
    VMStorageRoot   = "C:\Hyper-V\Virtual Machines"
    VMSwitchName    = "Internal-Switch" # Ensure this exists in Hyper-V
}
Use code with caution.

2. Phase 1: Manual Gold Image Preparation
Install OS: Install Windows Server 2025 Core on a temporary VM.
Config: Run sconfig to install all Windows Updates.
Sysprep: In PowerShell, run:
C:\Windows\System32\Sysprep\sysprep.exe /oobe /generalize /shutdown /mode:vm
MANUAL STEP: The VM shuts down. Move this .vhdx to the path in $GlobalConfig.GoldImagePath. Do not power it on again.
3. Phase 2: Automated Hyper-V VM Creation
Run this script on your Hyper-V Host to spawn the three servers using Differencing Disks (saving space and time).
powershell
$Servers = @(
    @{Name="SRV-DC-01"; RAM=4GB},
    @{Name="SRV-DC-02"; RAM=4GB},
    @{Name="SRV-MGMT-01"; RAM=8GB}
)

foreach ($Server in $Servers) {
    $VMPath = Join-Path $GlobalConfig.VMStorageRoot $Server.Name
    New-Item -Path $VMPath -ItemType Directory -Force
    
    # 1. Create Differencing Disk from Gold Image
    $VHDPath = Join-Path $VMPath "$($Server.Name).vhdx"
    New-VHD -ParentPath $GlobalConfig.GoldImagePath -Path $VHDPath -Differencing
    
    # 2. Create the VM
    New-VM -Name $Server.Name -MemoryStartupBytes $Server.RAM -VHDPath $VHDPath -SwitchName $GlobalConfig.VMSwitchName -Path $VMPath
    Set-VMMemory -VMName $Server.Name -DynamicMemoryEnabled $True -MinimumBytes 1GB -MaximumBytes $Server.RAM
}
Use code with caution.

# 4. Phase 3: VyOS Routing (Manual Configuration)
# Enter these commands into your VyOS CLI to bridge the subnets.
# bash
configure
set interfaces ethernet eth0 address 10.5.1.1/24
set interfaces ethernet eth1 address 10.1.1.1/24
set system ip forward 1
set firewall name ALLOW_ALL default-action accept
set firewall interface eth0 in name ALLOW_ALL
set firewall interface eth1 in name ALLOW_ALL
commit ; save
Use code with caution.

5. Phase 4: Server Roles & AD Promotion
A. SRV-DC-01 (Primary DC)
Promote: Install-ADDSForest -DomainName $GlobalConfig.DomainName -InstallDNS -Force
RESTART: Server reboots automatically.
Objects: Run New-ADUser and New-ADComputer commands for user01 and hmi01.
Cloning Prep: Run New-ADDCCloneConfigFile with the $GlobalConfig.ReplicaDC_IP.
SHUTDOWN: Power off to allow SRV-DC-02 to start as a clone.
B. SRV-MGMT-01 (Update Hub)
Roles: Install-WindowsFeature UpdateServices, Web-Server -IncludeManagementTools
RESTART: Highly recommended after WSUS install.
Post-Install:
powershell
New-SmbShare -Name "DefenderUpdates" -Path "D:\DefenderMirror" -FullAccess "Everyone"
& "wsusutil.exe" postinstall CONTENT_DIR=D:\WSUS
Use code with caution.

6. Phase 5: GPO Security Baseline (PowerShell Scripted)
Run this on SRV-DC-01 to automate domain-wide policies.
powershell
# 1. Password Complexity
Set-ADDefaultDomainPasswordPolicy -Identity $GlobalConfig.DomainName -MinPasswordLength 12 -MaxPasswordAge "90.00:00:00" -ComplexityEnabled $true

# 2. Update Policy (Pointing to MGMT Server)
$GPO_Update = New-GPO -Name "CORP-Updates"
Set-GPRegistryValue -Name "CORP-Updates" -Key "HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate" -ValueName "WUServer" -Type String -Value "http://$($GlobalConfig.MgmtServer_IP):8530"
Set-GPLink -Name "CORP-Updates" -Target "dc=corp,dc=local"

# 3. Disable Screensaver (For HMI)
$GPO_HMI = New-GPO -Name "CORP-HMI"
Set-GPRegistryValue -Name "CORP-HMI" -Key "HKCU\Software\Policies\Microsoft\Windows\Control Panel\Desktop" -ValueName "ScreenSaveActive" -Type String -Value "0"
Set-GPLink -Name "CORP-HMI" -Target "dc=corp,dc=local"
Use code with caution.

7. Final Automated Health Test
Run this from your ADMIN-PC (10.5.1.50).
powershell
$Report = @()
# Test Routing across VyOS
$PingDC2 = Test-Connection -ComputerName $GlobalConfig.ReplicaDC_IP -Count 1 -Quiet
$Report += [PSCustomObject]@{Test="VyOS Routing"; Result=($PingDC2 ? "PASS" : "FAIL")}

# Test AD Sync
$Repl = Invoke-Command -ComputerName $GlobalConfig.PrimaryDC_IP -ScriptBlock { repadmin /replsummary }
$Report += [PSCustomObject]@{Test="AD Replication"; Result=($Repl -match "0 errors" ? "PASS" : "FAIL")}

$Report | Format-Table -AutoSize
Use code with caution.

Implementation Complete. You have a scalable, variable-driven Server Core 2025 environment.
