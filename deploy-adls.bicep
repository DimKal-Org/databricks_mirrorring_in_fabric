@description('The name of the storage account')
param storageAccountName string = 'storage${uniqueString(resourceGroup().id)}'

@description('The location of the storage account')
param location string = resourceGroup().location

@description('The name of the storage container')
param containerName string = 'samplecontainer'

@description('The IP address to allow access')
param myIpAddress string

@description('The name of the VNet for private endpoints')
param vnetName string

@description('The name of the subnet for private endpoints')
param peSubnetName string = 'PESubnet'

// Storage Account
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    isHnsEnabled: true
    publicNetworkAccess: 'Disabled'  // Changed to Disabled for private endpoints
    networkAcls: {
      resourceAccessRules: []
      bypass: 'AzureServices'
      virtualNetworkRules: []
      ipRules: [
        {
          value: myIpAddress
          action: 'Allow'
        }
      ]
      defaultAction: 'Deny'
    }
  }
}

// Blob Container
resource storageContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  name: '${storageAccount.name}/default/${containerName}'
  properties: {
    publicAccess: 'None'
  }
}

// Reference to existing VNet
resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' existing = {
  name: vnetName
}

// Private DNS Zones
resource blobPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.blob.${environment().suffixes.storage}'
  location: 'global'
}

resource dfsPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.dfs.${environment().suffixes.storage}'
  location: 'global'
}

// DNS Zone VNet Links
resource blobDnsVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: blobPrivateDnsZone
  name: 'link-to-vnet-blob'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnet.id }
  }
}

resource dfsDnsVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: dfsPrivateDnsZone
  name: 'link-to-vnet-dfs'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnet.id }
  }
}

// SEQUENTIAL PRIVATE ENDPOINTS
// Blob Private Endpoint - Created FIRST
resource blobPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-09-01' = {
  name: '${storageAccountName}-blob-pe'
  location: location
  properties: {
    subnet: {
      id: '${vnet.id}/subnets/${peSubnetName}'
    }
    privateLinkServiceConnections: [
      {
        name: 'blob-connection'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: ['blob']
        }
      }
    ]
  }
  dependsOn: [
    storageAccount
  ]
}

// DFS Private Endpoint - Created SECOND (depends on blob endpoint)
resource dfsPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-09-01' = {
  name: '${storageAccountName}-dfs-pe'
  location: location
  properties: {
    subnet: {
      id: '${vnet.id}/subnets/${peSubnetName}'
    }
    privateLinkServiceConnections: [
      {
        name: 'dfs-connection'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: ['dfs']
        }
      }
    ]
  }
  dependsOn: [
    blobPrivateEndpoint  // SEQUENTIAL: Wait for blob endpoint
  ]
}

// DNS Zone Groups
resource blobDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = {
  parent: blobPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'config1'
        properties: { privateDnsZoneId: blobPrivateDnsZone.id }
      }
    ]
  }
}

resource dfsDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = {
  parent: dfsPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'config1'
        properties: { privateDnsZoneId: dfsPrivateDnsZone.id }
      }
    ]
  }
}

// Outputs
output storageAccountName string = storageAccount.name
output containerName string = storageContainer.name
output blobPrivateEndpointId string = blobPrivateEndpoint.id
output dfsPrivateEndpointId string = dfsPrivateEndpoint.id
