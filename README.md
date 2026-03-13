# Server 2025 Core Infrastructure Deployment

Production-style PowerShell automation for a Hyper-V lab:
- Active Directory Domain Services (primary DC setup)
- DNS configuration
- Group Policy deployment
- WSUS policy targeting
- Multi-network topology with VyOS routing guidance

## Repository Structure

- `config/lab.config.psd1` - all environment-specific values
- `scripts/Deploy-CoreInfrastructure.ps1` - modular deployment script
- `docs/VyOS-Setup.md` - copy/paste VyOS router commands
- `logs/` - generated transcript logs per execution (auto-created)

## Prerequisites

### Hyper-V Host (for `HyperVDeploy` stage)
- Windows Server / Windows with Hyper-V enabled
- Gold image exists at `GoldImagePath` in the config file
- Virtual switches exist:
  - `AdminSwitch`
  - `ReplicaSwitch`
- Run PowerShell as Administrator

### Primary Domain Controller VM (for `PrimaryDC`, `GPO`, `HealthCheck`)
- Windows Server 2025 Core with static network configured
- Required modules/features available:
  - `ADDSDeployment`
  - `ActiveDirectory`
  - `DnsServer`
  - `GroupPolicy` (for GPO stage)
- Domain promotion reboot planning (script uses `-NoRebootOnCompletion`)

## Quick Start

1. Edit `config/lab.config.psd1` for your lab values.
2. Open elevated PowerShell for infrastructure stages (`HyperVDeploy`, `PrimaryDC`, `GPO`, `HealthCheck`).
3. Run one stage at a time by host role.

### Show VyOS commands only

```powershell
.\scripts\Deploy-CoreInfrastructure.ps1 -Stages VyOSGuide
```

### Deploy Hyper-V VMs (run on Hyper-V host)

```powershell
.\scripts\Deploy-CoreInfrastructure.ps1 -Stages HyperVDeploy
```

### Configure primary DC (run inside SRV-DC-01)

```powershell
.\scripts\Deploy-CoreInfrastructure.ps1 -Stages PrimaryDC
```

### Apply GPO configuration (run inside SRV-DC-01 after promotion)

```powershell
.\scripts\Deploy-CoreInfrastructure.ps1 -Stages GPO
```

### Run health checks

```powershell
.\scripts\Deploy-CoreInfrastructure.ps1 -Stages @('HealthCheck','Summary')
```

### Optional custom transcript path

```powershell
.\scripts\Deploy-CoreInfrastructure.ps1 -Stages VyOSGuide -LogPath .\logs\vyos-only.log
```

### Dry-run for stages that support ShouldProcess

```powershell
.\scripts\Deploy-CoreInfrastructure.ps1 -Stages HyperVDeploy -WhatIf
```

## Recommended Execution Order

1. `VyOSGuide`
2. `HyperVDeploy`
3. Boot/configure `SRV-DC-01` network and host name
4. `PrimaryDC`
5. Reboot `SRV-DC-01`
6. `GPO`
7. `HealthCheck` and `Summary`

## Security Notes

- `SafePassword` is plain text in config for lab convenience.
- For production, replace with a secure secret retrieval workflow (vault or prompt).
- Restrict access to this repo if real credentials are used.

## Push to GitHub

```powershell
git init
git add .
git commit -m "Initial Server 2025 core infrastructure automation"
git branch -M main
git remote add origin https://github.com/<your-user>/<your-repo>.git
git push -u origin main
```

## Disclaimer

This automation is intended for lab and controlled infrastructure environments. Validate every stage in a non-production environment before broader use.
