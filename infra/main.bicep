targetScope = 'subscription'

@description('Azure region for all resources')
param location string = 'centralus'

@description('Resource name prefix')
param prefix string = 'corp'

@description('Availability zones to deploy into. Set to [] for regions that do not support zones.')
param zones array = ['1', '2', '3']

@description('Admin username for the spoke VMs.')
param adminUsername string

@description('Admin password for the spoke VMs.')
@secure()
param adminPassword string

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${prefix}-network-${location}'
  location: location
}

module network 'network.bicep' = {
  scope: rg
  params: {
    location: location
    prefix: prefix
    zones: zones
    adminUsername: adminUsername
    adminPassword: adminPassword
  }
}

output hubVnetId string = network.outputs.hubVnetId
output spoke1VnetId string = network.outputs.spoke1VnetId
output spoke2VnetId string = network.outputs.spoke2VnetId
output firewallPrivateIp string = network.outputs.firewallPrivateIp
output logAnalyticsWorkspaceId string = network.outputs.logAnalyticsWorkspaceId
