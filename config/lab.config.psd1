@{
    DomainName      = 'corp.local'
    DomainNetBIOS   = 'CORP'
    SafePassword    = 'P@ssword123!'
    AdminUser       = 'admin01'
    StandardUser    = 'user01'
    HmiDevice       = 'hmi01'

    AdminNet_GW     = '10.5.1.1'
    PrimaryDC_IP    = '10.5.1.10'
    MgmtServer_IP   = '10.5.1.20'
    AdminPC_IP      = '10.5.1.50'

    ReplicaNet_GW   = '10.1.1.1'
    ReplicaDC_IP    = '10.1.1.10'

    GoldImagePath   = 'C:\VMs\GoldImage\W2025Core.vhdx'
    WsusContentPath = 'D:\WSUS'
    MirrorPath      = 'D:\DefenderMirror'

    VMRootPath      = 'C:\VMs'
    AdminSwitchName = 'AdminSwitch'
    ReplicaSwitchName = 'ReplicaSwitch'
}
