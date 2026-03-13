# Gold Image One-Liner Runbook

Use these commands in order when you start from a ready gold image VHDX.

## First (Hyper-V host): check config + dry run

```powershell
Set-Location C:\Users\DELL\HyperV-Lab-01; .\scripts\Deploy-CoreInfrastructure.ps1 -Stages HyperVDeploy -WhatIf
```

## Second (Hyper-V host): deploy VMs from gold image

```powershell
Set-Location C:\Users\DELL\HyperV-Lab-01; .\scripts\Deploy-CoreInfrastructure.ps1 -Stages HyperVDeploy
```

## Next (Hyper-V host): print VyOS commands

```powershell
Set-Location C:\Users\DELL\HyperV-Lab-01; .\scripts\Deploy-CoreInfrastructure.ps1 -Stages VyOSGuide
```

## Next (inside SRV-DC-01): promote DC

```powershell
Set-Location C:\Users\DELL\HyperV-Lab-01; .\scripts\Deploy-CoreInfrastructure.ps1 -Stages PrimaryDC
```

## Next (inside SRV-DC-01 after reboot): apply GPO

```powershell
Set-Location C:\Users\DELL\HyperV-Lab-01; .\scripts\Deploy-CoreInfrastructure.ps1 -Stages GPO
```

## Next (inside SRV-DC-01): health + summary

```powershell
Set-Location C:\Users\DELL\HyperV-Lab-01; .\scripts\Deploy-CoreInfrastructure.ps1 -Stages @('HealthCheck','Summary')
```

## Optional single-line starter (host only)

This runs non-destructive routing guide + VM creation + summary from host side.

```powershell
Set-Location C:\Users\DELL\HyperV-Lab-01; .\scripts\Deploy-CoreInfrastructure.ps1 -Stages @('VyOSGuide','HyperVDeploy','Summary')
```
