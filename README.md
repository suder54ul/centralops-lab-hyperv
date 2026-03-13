# Server 2025 Core Infrastructure Deployment

PowerShell automation for a Hyper-V lab environment covering:
- Active Directory Domain Services (primary DC setup)
- DNS configuration
- Group Policy deployment
- WSUS policy targeting
- Multi-network routing with VyOS guidance

## Repository Structure

- `config/lab.config.psd1` - environment-specific configuration values
- `scripts/Deploy-CoreInfrastructure.ps1` - modular deployment script
- `docs/VyOS-Setup.md` - VyOS command runbook
- `logs/` - transcript logs (auto-created at runtime)

## Prerequisites

### Hyper-V host (`HyperVDeploy`)
- Hyper-V enabled on Windows host
- Gold image VHDX exists at `GoldImagePath`
- Virtual switches exist:
  - `AdminSwitch`
  - `ReplicaSwitch`
- Elevated PowerShell session

### Primary DC VM (`PrimaryDC`, `GPO`, `HealthCheck`)
- Windows Server 2025 Core with static networking
- Available modules/features:
  - `ADDSDeployment`
  - `ActiveDirectory`
  - `DnsServer`
  - `GroupPolicy` (for GPO stage)
- Reboot planned after domain promotion (`-NoRebootOnCompletion` is used)

## Command Copy Safety

- Copy commands from fenced code blocks only.
- Ignore text such as `(http://_vscodecontentref_/...)` if it appears in chat/preview rendering.
- Valid command example:

```powershell
.\scripts\Deploy-CoreInfrastructure.ps1 -Stages HyperVDeploy
```

## Quick Start

1. Edit `config/lab.config.psd1` for your environment.
2. Open elevated PowerShell for infrastructure stages (`HyperVDeploy`, `PrimaryDC`, `GPO`, `HealthCheck`).
3. Run stages one at a time by role.

### Stage commands

```powershell
.\scripts\Deploy-CoreInfrastructure.ps1 -Stages VyOSGuide
.\scripts\Deploy-CoreInfrastructure.ps1 -Stages HyperVDeploy
.\scripts\Deploy-CoreInfrastructure.ps1 -Stages PrimaryDC
.\scripts\Deploy-CoreInfrastructure.ps1 -Stages GPO
.\scripts\Deploy-CoreInfrastructure.ps1 -Stages @('HealthCheck','Summary')
```

### Optional

```powershell
.\scripts\Deploy-CoreInfrastructure.ps1 -Stages VyOSGuide -LogPath .\logs\vyos-only.log
.\scripts\Deploy-CoreInfrastructure.ps1 -Stages HyperVDeploy -WhatIf
```

## Recommended Execution Order

1. `VyOSGuide`
2. `HyperVDeploy`
3. Boot/configure `SRV-DC-01` hostname and network
4. `PrimaryDC`
5. Reboot `SRV-DC-01`
6. `GPO`
7. `HealthCheck` and `Summary`

## Security Notes

- `SafePassword` is plain text in config for lab convenience.
- For production, use a secure secret source (vault or prompt).
- Restrict repository access when real credentials are present.

## Updating GitHub

```powershell
git add README.md
git commit -m "Clean README and command guidance"
git push
```

## Disclaimer

Intended for lab and controlled environments. Validate all stages in non-production before broader use.
