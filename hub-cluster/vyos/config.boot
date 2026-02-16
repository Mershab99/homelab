// VyOS configuration — synced to VyOS via HTTP API by the sync CronJob.
// This is VyOS CLI format, not YAML.

system {
    host-name vyos-supermicro
    domain-name homelab.dev
    time-zone UTC
    name-server 1.1.1.1
    name-server 8.8.8.8
}

interfaces {
    ethernet eth0 {
        description WAN
        address dhcp
        // For static WAN, replace with:
        // address <WAN-IP>/24
        // NOTE: Update firewall and NAT if using static
    }
    ethernet eth1 {
        description LAN
        address 192.168.1.1/24
        vif 10 {
            description "BMC VLAN"
            address 10.0.10.1/24
        }
    }
}

container {
    name k3s {
        image rancher/k3s:v1.29-k3s1
        allow-host-networks
        restart on-failure
        cap-add net-admin
        cap-add sys-admin
        memory 0
        environment K3S_TOKEN {
            value <CHANGE-ME>
        }
        volume k3s-data {
            source /var/lib/rancher/k3s
            destination /var/lib/rancher/k3s
            mode rw
        }
        volume k3s-config {
            source /etc/rancher/k3s
            destination /etc/rancher/k3s
            mode rw
        }
    }
}

service {
    dhcp-server {
        shared-network-name LAN {
            subnet 192.168.1.0/24 {
                default-router 192.168.1.1
                dns-server 192.168.1.1
                range 0 {
                    start 192.168.1.100
                    stop 192.168.1.200
                }
            }
        }
    }
    dns {
        forwarding {
            listen-address 192.168.1.1
            allow-from 192.168.1.0/24
        }
    }
    https {
        api-restrict {
            virtual-host <CHANGE-ME>
        }
        certificates {
            certificate <CHANGE-ME>
        }
    }
}

firewall {
    group {
        network-group BMC-NET {
            network 10.0.10.0/24
        }
        network-group LAN-NET {
            network 192.168.1.0/24
        }
    }
    name WAN-IN {
        default-action drop
        rule 10 {
            action accept
            state {
                established enable
                related enable
            }
        }
        rule 20 {
            action drop
            state {
                invalid enable
            }
        }
    }
    name WAN-LOCAL {
        default-action drop
        rule 10 {
            action accept
            state {
                established enable
                related enable
            }
        }
    }
    name LAN-LOCAL {
        default-action accept
        rule 10 {
            action accept
            description "Allow K3s API"
            destination {
                port 6443
            }
            protocol tcp
        }
    }
    name LAN-TO-BMC {
        default-action drop
        rule 10 {
            action accept
            description "Allow IPMI/Redfish from LAN to BMC VLAN"
            destination {
                group {
                    network-group BMC-NET
                }
                port 623,443,80
            }
            protocol tcp_udp
        }
    }
}

nat {
    source {
        rule 100 {
            outbound-interface eth0
            source {
                address 192.168.1.0/24
            }
            translation {
                address masquerade
            }
        }
        rule 110 {
            outbound-interface eth0
            source {
                address 10.0.10.0/24
            }
            translation {
                address masquerade
            }
        }
    }
}

zone-policy {
    zone WAN {
        interface eth0
        default-action drop
        from LAN {
            firewall {
                name LAN-LOCAL
            }
        }
    }
    zone LAN {
        interface eth1
        default-action drop
        from WAN {
            firewall {
                name WAN-IN
            }
        }
    }
}
