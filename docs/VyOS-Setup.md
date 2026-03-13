# VyOS Routing Configuration

Use these commands on your VyOS router to enable routing between:
- Admin network: `10.5.1.0/24`
- Replica network: `10.1.1.0/24`

```vyos
configure

set interfaces ethernet eth0 address 10.5.1.1/24
set interfaces ethernet eth1 address 10.1.1.1/24
set interfaces ethernet eth0 description 'Admin-Network'
set interfaces ethernet eth1 description 'Replica-Network'

set system ip forward 1

set firewall name ALLOW_ALL default-action accept
set firewall interface eth0 in name ALLOW_ALL
set firewall interface eth1 in name ALLOW_ALL

commit
save
show interfaces
```

## Validation

From an Admin network machine, test reachability to `10.1.1.10` (replica DC).
