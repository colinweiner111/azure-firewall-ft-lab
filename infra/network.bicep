param location string
param prefix string
param zones array = ['1', '2', '3']
param adminUsername string
@secure()
param adminPassword string

// Route tables created first (routes added after firewall is deployed)
resource spoke1RouteTable 'Microsoft.Network/routeTables@2024-01-01' = {
  name: 'rt-${prefix}-spoke1'
  location: location
  properties: {
    disableBgpRoutePropagation: true
  }
}

resource spoke2RouteTable 'Microsoft.Network/routeTables@2024-01-01' = {
  name: 'rt-${prefix}-spoke2'
  location: location
  properties: {
    disableBgpRoutePropagation: true
  }
}

// Hub VNet — subnets defined as child resources for reliable symbolic references
resource hubVnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: 'vnet-${prefix}-hub'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.0.0.0/24']
    }
  }
}

resource fwSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-01-01' = {
  parent: hubVnet
  name: 'AzureFirewallSubnet'
  properties: {
    addressPrefix: '10.0.0.0/26'
  }
}

resource fwMgmtSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-01-01' = {
  parent: hubVnet
  name: 'AzureFirewallManagementSubnet'
  properties: {
    addressPrefix: '10.0.0.64/26'
  }
  dependsOn: [fwSubnet] // subnets on same VNet must be created sequentially
}

resource bastionSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-01-01' = {
  parent: hubVnet
  name: 'AzureBastionSubnet'
  properties: {
    addressPrefix: '10.0.0.128/26'
  }
  dependsOn: [fwMgmtSubnet] // subnets on same VNet must be created sequentially
}

// Spoke 1 VNet
resource spoke1Vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: 'vnet-${prefix}-spoke1'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.1.0.0/24']
    }
    subnets: [
      {
        name: 'snet-workload'
        properties: {
          addressPrefix: '10.1.0.0/24'
          routeTable: {
            id: spoke1RouteTable.id
          }
        }
      }
    ]
  }
}

// Spoke 2 VNet
resource spoke2Vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: 'vnet-${prefix}-spoke2'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.2.0.0/24']
    }
    subnets: [
      {
        name: 'snet-workload'
        properties: {
          addressPrefix: '10.2.0.0/24'
          routeTable: {
            id: spoke2RouteTable.id
          }
        }
      }
    ]
  }
}

// Public IPs for firewall data-plane and management-plane
resource fwPip 'Microsoft.Network/publicIPAddresses@2024-01-01' = {
  name: 'pip-${prefix}-fw'
  location: location
  zones: zones
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource fwMgmtPip 'Microsoft.Network/publicIPAddresses@2024-01-01' = {
  name: 'pip-${prefix}-fw-mgmt'
  location: location
  zones: zones
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

// Log Analytics workspace for firewall diagnostics
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${prefix}-hub'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// Firewall Policy (Standard tier to match firewall SKU)
resource firewallPolicy 'Microsoft.Network/firewallPolicies@2024-01-01' = {
  name: 'afwp-${prefix}-hub'
  location: location
  properties: {
    sku: {
      tier: 'Standard'
    }
    threatIntelMode: 'Alert'
  }
}

// Rule collection group — spoke-to-spoke + internet egress; everything else is implicitly denied
resource ruleCollectionGroup 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2024-01-01' = {
  parent: firewallPolicy
  name: 'rcg-${prefix}-default'
  properties: {
    priority: 100
    ruleCollections: [
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'net-allow-spoke-to-spoke'
        priority: 100
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'allow-spoke-to-spoke'
            sourceAddresses: ['10.1.0.0/24', '10.2.0.0/24']
            destinationAddresses: ['10.1.0.0/24', '10.2.0.0/24']
            destinationPorts: ['*']
            ipProtocols: ['Any']
          }
        ]
      }
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'app-allow-internet-egress'
        priority: 200
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'ApplicationRule'
            name: 'allow-http-https'
            sourceAddresses: ['10.1.0.0/24', '10.2.0.0/24']
            protocols: [
              { protocolType: 'Http', port: 80 }
              { protocolType: 'Https', port: 443 }
            ]
            targetFqdns: ['*']
          }
        ]
      }
    ]
  }
}

// Azure Firewall with management interface (enables out-of-band management)
resource firewall 'Microsoft.Network/azureFirewalls@2024-01-01' = {
  name: 'afw-${prefix}-hub'
  location: location
  zones: zones
  properties: {
    sku: {
      name: 'AZFW_VNet'
      tier: 'Standard'
    }
    firewallPolicy: {
      id: firewallPolicy.id
    }
    ipConfigurations: [
      {
        name: 'fw-ipconfig'
        properties: {
          subnet: {
            id: fwSubnet.id
          }
          publicIPAddress: {
            id: fwPip.id
          }
        }
      }
    ]
    managementIpConfiguration: {
      name: 'fw-mgmt-ipconfig'
      properties: {
        subnet: {
          id: fwMgmtSubnet.id
        }
        publicIPAddress: {
          id: fwMgmtPip.id
        }
      }
    }
  }
}

// Default routes in spoke route tables pointing to firewall private IP
resource spoke1DefaultRoute 'Microsoft.Network/routeTables/routes@2024-01-01' = {
  parent: spoke1RouteTable
  name: 'default-to-firewall'
  properties: {
    addressPrefix: '0.0.0.0/0'
    nextHopType: 'VirtualAppliance'
    nextHopIpAddress: firewall.properties.ipConfigurations[0].properties.privateIPAddress
  }
}

resource spoke2DefaultRoute 'Microsoft.Network/routeTables/routes@2024-01-01' = {
  parent: spoke2RouteTable
  name: 'default-to-firewall'
  properties: {
    addressPrefix: '0.0.0.0/0'
    nextHopType: 'VirtualAppliance'
    nextHopIpAddress: firewall.properties.ipConfigurations[0].properties.privateIPAddress
  }
}

// Explicit spoke-to-spoke routes — override the more-specific peering system routes so traffic is forced through the firewall
resource spoke1ToSpoke2Route 'Microsoft.Network/routeTables/routes@2024-01-01' = {
  parent: spoke1RouteTable
  name: 'spoke2-via-firewall'
  properties: {
    addressPrefix: '10.2.0.0/24'
    nextHopType: 'VirtualAppliance'
    nextHopIpAddress: firewall.properties.ipConfigurations[0].properties.privateIPAddress
  }
}

resource spoke2ToSpoke1Route 'Microsoft.Network/routeTables/routes@2024-01-01' = {
  parent: spoke2RouteTable
  name: 'spoke1-via-firewall'
  properties: {
    addressPrefix: '10.1.0.0/24'
    nextHopType: 'VirtualAppliance'
    nextHopIpAddress: firewall.properties.ipConfigurations[0].properties.privateIPAddress
  }
}

// VNet peerings — hub <-> spoke1
// dependsOn bastionSubnet ensures all hub subnets are fully provisioned (Succeeded) before peering starts
resource hubToSpoke1 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-01-01' = {
  parent: hubVnet
  name: 'peer-hub-to-spoke1'
  properties: {
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    remoteVirtualNetwork: {
      id: spoke1Vnet.id
    }
  }
  dependsOn: [bastionSubnet]
}

resource spoke1ToHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-01-01' = {
  parent: spoke1Vnet
  name: 'peer-spoke1-to-hub'
  properties: {
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    useRemoteGateways: false
    remoteVirtualNetwork: {
      id: hubVnet.id
    }
  }
  dependsOn: [bastionSubnet]
}

// VNet peerings — hub <-> spoke2
resource hubToSpoke2 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-01-01' = {
  parent: hubVnet
  name: 'peer-hub-to-spoke2'
  properties: {
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    remoteVirtualNetwork: {
      id: spoke2Vnet.id
    }
  }
  dependsOn: [bastionSubnet]
}

resource spoke2ToHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-01-01' = {
  parent: spoke2Vnet
  name: 'peer-spoke2-to-hub'
  properties: {
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    useRemoteGateways: false
    remoteVirtualNetwork: {
      id: hubVnet.id
    }
  }
  dependsOn: [bastionSubnet]
}

// Diagnostic settings — stream all firewall logs and metrics to Log Analytics
resource fwDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: firewall
  name: 'diag-${prefix}-fw'
  properties: {
    workspaceId: logAnalytics.id
    logs: [
      { category: 'AzureFirewallApplicationRule', enabled: true }
      { category: 'AzureFirewallNetworkRule', enabled: true }
      { category: 'AzureFirewallDnsProxy', enabled: true }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

// Bastion public IP
resource bastionPip 'Microsoft.Network/publicIPAddresses@2024-01-01' = {
  name: 'pip-${prefix}-bastion'
  location: location
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

// Azure Bastion (Basic SKU — sufficient for SSH/RDP access to private VMs)
resource bastion 'Microsoft.Network/bastionHosts@2024-01-01' = {
  name: 'bastion-${prefix}-hub'
  location: location
  sku: { name: 'Basic' }
  properties: {
    ipConfigurations: [
      {
        name: 'bastion-ipconfig'
        properties: {
          subnet: { id: bastionSubnet.id }
          publicIPAddress: { id: bastionPip.id }
        }
      }
    ]
  }
}

// NIC for spoke1 VM
resource spoke1Nic 'Microsoft.Network/networkInterfaces@2024-01-01' = {
  name: 'nic-${prefix}-spoke1-vm'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          subnet: { id: spoke1Vnet.properties.subnets[0].id }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

// Linux VM in spoke1 — no public IP, access via Bastion
resource spoke1Vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: 'vm-${prefix}-spoke1'
  location: location
  properties: {
    hardwareProfile: { vmSize: 'Standard_B1s' }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'Standard_LRS' }
        deleteOption: 'Delete'
      }
    }
    osProfile: {
      computerName: 'vm-spoke1'
      adminUsername: adminUsername
      adminPassword: adminPassword
      linuxConfiguration: {
        disablePasswordAuthentication: false
      }
    }
    networkProfile: {
      networkInterfaces: [ { id: spoke1Nic.id } ]
    }
  }
}

// NIC for spoke2 VM
resource spoke2Nic 'Microsoft.Network/networkInterfaces@2024-01-01' = {
  name: 'nic-${prefix}-spoke2-vm'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          subnet: { id: spoke2Vnet.properties.subnets[0].id }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

// Linux VM in spoke2 — no public IP, access via Bastion
resource spoke2Vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: 'vm-${prefix}-spoke2'
  location: location
  properties: {
    hardwareProfile: { vmSize: 'Standard_B1s' }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'Standard_LRS' }
        deleteOption: 'Delete'
      }
    }
    osProfile: {
      computerName: 'vm-spoke2'
      adminUsername: adminUsername
      adminPassword: adminPassword
      linuxConfiguration: {
        disablePasswordAuthentication: false
      }
    }
    networkProfile: {
      networkInterfaces: [ { id: spoke2Nic.id } ]
    }
  }
}

output hubVnetId string = hubVnet.id
output spoke1VnetId string = spoke1Vnet.id
output spoke2VnetId string = spoke2Vnet.id
output firewallPrivateIp string = firewall.properties.ipConfigurations[0].properties.privateIPAddress
output logAnalyticsWorkspaceId string = logAnalytics.id
