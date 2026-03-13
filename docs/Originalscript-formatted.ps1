# ============================================================
# WINDOWS SERVER 2025 CORE INFRASTRUCTURE AUTOMATION GUIDE
# ============================================================
# This comprehensive guide integrates Gold Image strategy,
# Hyper-V automation, VyOS routing, and PowerShell-driven GPOs
# using a single global variable table for consistency
# ============================================================

# ============================================================
# 1. GLOBAL CONFIGURATION TABLE
# ============================================================
# Define this in your VS Code environment first.
# All subsequent scripts reference these variables for consistency.

$GlobalConfig = @{
    # ----- DOMAIN & IDENTITY CONFIGURATION -----
    DomainName      = "corp.local"                                # Internal domain name for the organization
    SafePassword    = (ConvertTo-SecureString "P@ssword123!" -AsPlainText -Force)  # Secure password object for automation
    AdminUser       = "admin01"                                    # Administrative account name
    StandardUser    = "user01"                                     # Standard domain user account
    HmiDevice       = "hmi01"                                      # HMI (Human-Machine Interface) device name

    # ----- NETWORK 1: ADMIN NETWORK (10.5.1.0/24) -----
    AdminNet_GW     = "10.5.1.1"                                   # Gateway IP for admin network
    PrimaryDC_IP    = "10.5.1.10"                                  # Primary Domain Controller IP
    MgmtServer_IP   = "10.5.1.20"                                  # Management Server (WSUS) IP

    # ----- NETWORK 2: REPLICA NETWORK (10.1.1.0/24) -----
    ReplicaNet_GW   = "10.1.1.1"                                   # Gateway IP for replica network
    ReplicaDC_IP    = "10.1.1.10"                                  # Replica Domain Controller IP

    # ----- INFRASTRUCTURE PATHS -----
    GoldImagePath   = "C:\VMs\GoldImage\W2025Core.vhdx"           # Path to Sysprepped gold image (must be prepared manually)
    VMStorageRoot   = "C:\Hyper-V\Virtual Machines"               # Root folder for all VM storage
    VMSwitchName    = "Internal-Switch"                           # Hyper-V virtual switch name (must exist before script runs)
}

# ============================================================
# 2. PHASE 1: MANUAL GOLD IMAGE PREPARATION
# ============================================================
# MANUAL STEPS - Execute these manually before automation:
#
# 2.1. Install OS: Install Windows Server 2025 Core on a temporary VM
# 2.2. Config: Run 'sconfig' to install all Windows Updates
# 2.3. Sysprep: In PowerShell, run:
#      C:\Windows\System32\Sysprep\sysprep.exe /oobe /generalize /shutdown /mode:vm
# 2.4. MANUAL STEP: VM shuts down automatically. Copy this .vhdx to the path
#      specified in $GlobalConfig.GoldImagePath. DO NOT power it on again!
# ============================================================

# ============================================================
# 3. PHASE 2: AUTOMATED HYPER-V VM CREATION
# ============================================================
# Run this script on your Hyper-V Host to create three servers
# using Differencing Disks (saves disk space and deployment time)

# Define server configuration array with names and memory allocations
$Servers = @(
    @{Name="SRV-DC-01"; RAM=4GB},    # Primary Domain Controller - 4GB RAM
    @{Name="SRV-DC-02"; RAM=4GB},    # Replica Domain Controller - 4GB RAM
    @{Name="SRV-MGMT-01"; RAM=8GB}   # Management Server (WSUS) - 8GB RAM
)

# Loop through each server configuration to create VMs
foreach ($Server in $Servers) {
    # Create unique VM folder path based on server name
    $VMPath = Join-Path $GlobalConfig.VMStorageRoot $Server.Name
    # Create the VM folder (Force parameter suppresses errors if folder exists)
    New-Item -Path $VMPath -ItemType Directory -Force
    
    # 3.1. Create Differencing Disk from Gold Image
    # Build full path for the new VHDX file
    $VHDPath = Join-Path $VMPath "$($Server.Name).vhdx"
    # Create differencing disk (child) pointing to gold image (parent)
    # This saves disk space by only storing changes from the gold image
    New-VHD -ParentPath $GlobalConfig.GoldImagePath -Path $VHDPath -Differencing
    
    # 3.2. Create the Virtual Machine
    # Create new VM with specified name, memory, disk, switch, and path
    New-VM -Name $Server.Name -MemoryStartupBytes $Server.RAM -VHDPath $VHDPath -SwitchName $GlobalConfig.VMSwitchName -Path $VMPath
    # Configure dynamic memory for better resource utilization
    Set-VMMemory -VMName $Server.Name -DynamicMemoryEnabled $True -MinimumBytes 1GB -MaximumBytes $Server.RAM
}

# ============================================================
# 4. PHASE 3: VYOS ROUTING (MANUAL CONFIGURATION)
# ============================================================
# MANUAL STEP - Enter these commands into your VyOS CLI
# to bridge the admin and replica subnets
#
# configure                                    # Enter configuration mode
# set interfaces ethernet eth0 address 10.5.1.1/24    # Configure admin network interface
# set interfaces ethernet eth1 address 10.1.1.1/24    # Configure replica network interface
# set system ip forward 1                       # Enable IP forwarding (routing)
# set firewall name ALLOW_ALL default-action accept    # Create permissive firewall policy
# set firewall interface eth0 in name ALLOW_ALL       # Apply policy to eth0 inbound
# set firewall interface eth1 in name ALLOW_ALL       # Apply policy to eth1 inbound
# commit ; save                                 # Commit and save configuration
# ============================================================

# ============================================================
# 5. PHASE 4: SERVER ROLES & AD PROMOTION
# ============================================================

# 5.A. SRV-DC-01 (Primary Domain Controller)
# ----- Run these commands on SRV-DC-01 -----
#
# Promote server to Domain Controller and create new forest:
# Install-ADDSForest -DomainName $GlobalConfig.DomainName -InstallDNS -Force
#
# NOTE: Server RESTARTS automatically after promotion
#
# After reboot, create AD objects:
# New-ADUser -Name $GlobalConfig.StandardUser -AccountPassword $GlobalConfig.SafePassword -Enabled $true
# New-ADComputer -Name $GlobalConfig.HmiDevice
#
# Prepare for cloning (create DC clone configuration file):
# New-ADDCCloneConfigFile -Static -IPv4Address $GlobalConfig.ReplicaDC_IP `
#   -IPv4DNSResolver $GlobalConfig.PrimaryDC_IP -IPv4SubnetMask "255.255.255.0" `
#   -IPv4DefaultGateway $GlobalConfig.ReplicaNet_GW
#
# IMPORTANT: SHUTDOWN SRV-DC-01 before starting SRV-DC-02 clone
# ============================================================

# 5.B. SRV-MGMT-01 (Update Hub / WSUS Server)
# ----- Run these commands on SRV-MGMT-01 -----
#
# Install WSUS and Web Server roles:
# Install-WindowsFeature UpdateServices, Web-Server -IncludeManagementTools
#
# RESTART: Highly recommended after WSUS installation
#
# After restart, configure WSUS and create SMB share:

# Create SMB share for Defender updates (accessible to all domain computers)
New-SmbShare -Name "DefenderUpdates" -Path "D:\DefenderMirror" -FullAccess "Everyone"

# Initialize WSUS with content directory on D: drive
& "wsusutil.exe" postinstall CONTENT_DIR=D:\WSUS

# ============================================================
# 6. PHASE 5: GPO SECURITY BASELINE (POWERSHELL SCRIPTED)
# ============================================================
# Run these commands on SRV-DC-01 to automate domain-wide policies

# 6.1. Password Policy - Configure domain-wide password requirements
Set-ADDefaultDomainPasswordPolicy `
    -Identity $GlobalConfig.DomainName `           # Target domain
    -MinPasswordLength 12 `                         # Require minimum 12 characters
    -MaxPasswordAge "90.00:00:00" `                 # Passwords expire after 90 days
    -ComplexityEnabled $true                         # Require complex passwords

# 6.2. Update Policy - Point all computers to local WSUS server
# Create new GPO for update settings
$GPO_Update = New-GPO -Name "CORP-Updates"

# Configure WSUS server address in registry policy
Set-GPRegistryValue `
    -Name "CORP-Updates" `                          # Target GPO name
    -Key "HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate" `  # Registry key path
    -ValueName "WUServer" `                          # Registry value name
    -Type String `                                    # Registry value type
    -Value "http://$($GlobalConfig.MgmtServer_IP):8530"  # WSUS server URL

# Link the GPO to the domain
Set-GPLink -Name "CORP-Updates" -Target "dc=corp,dc=local"

# 6.3. Disable Screensaver (For HMI devices)
# Create separate GPO for HMI-specific settings
$GPO_HMI = New-GPO -Name "CORP-HMI"

# Disable screensaver via user policy
Set-GPRegistryValue `
    -Name "CORP-HMI" `                               # Target GPO name
    -Key "HKCU\Software\Policies\Microsoft\Windows\Control Panel\Desktop" `  # User registry key
    -ValueName "ScreenSaveActive" `                  # Screensaver active setting
    -Type String `                                    # Registry value type
    -Value "0"                                        # 0 = Disabled, 1 = Enabled

# Link the HMI GPO to the domain
Set-GPLink -Name "CORP-HMI" -Target "dc=corp,dc=local"

# ============================================================
# 7. FINAL AUTOMATED HEALTH TEST
# ============================================================
# Run this from your ADMIN-PC (IP: 10.5.1.50) to validate infrastructure

# Initialize empty array for test results
$Report = @()

# Test 1: Validate VyOS routing between subnets
$PingDC2 = Test-Connection -ComputerName $GlobalConfig.ReplicaDC_IP -Count 1 -Quiet
$Report += [PSCustomObject]@{
    Test="VyOS Routing";                              # Test description
    Result=($PingDC2 ? "PASS" : "FAIL")               # PASS if ping successful
}

# Test 2: Validate Active Directory replication status
$Repl = Invoke-Command -ComputerName $GlobalConfig.PrimaryDC_IP -ScriptBlock { 
    repadmin /replsummary                             # Get AD replication summary
}
$Report += [PSCustomObject]@{
    Test="AD Replication";                             # Test description
    Result=($Repl -match "0 errors" ? "PASS" : "FAIL")  # PASS if no errors reported
}

# Display formatted test results table
$Report | Format-Table -AutoSize

# ============================================================
# IMPLEMENTATION COMPLETE
# ============================================================
# You now have a scalable, variable-driven Server Core 2025 
# environment with automated deployment and configuration
# ============================================================