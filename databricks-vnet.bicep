@description('The Azure region for all resources.')
param location string = resourceGroup().location

@description('The name of the Virtual Network.')
param vnetName string = 'vnet-databricks'

@description('The name of the Databricks Workspace.')
param workspaceName string = 'dbw-injected-workspace'

// Variables
var managedResourceGroupName = 'databricks-rg-${workspaceName}-managed'
var publicSubnetName = 'public-subnet-dbx'
var privateSubnetName = 'private-subnet-dbx'
var peSubnetName = 'PESubnet'
var gatewaySubnetName = 'VNetGatewaySubnet'
var vmSubnetName = 'PESubnetVM'  // Optional subnet for VMs or other resources in the same VNet

// 1. Network Security Group
resource databricksNsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: 'nsg-databricks'
  location: location
  properties: {
    securityRules: []
  }
}

// 2. Virtual Network with ALL 4 Subnets
resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.0.0.0/16']
    }
    subnets: [
      {
        name: peSubnetName
        properties: {
          addressPrefix: '10.0.0.0/24'
        }
      }
      {
        name: vmSubnetName
        properties: {
          addressPrefix: '10.0.2.0/24'
        }
      }
      {
        name: gatewaySubnetName
        properties: {
          addressPrefix: '10.0.1.0/24'
        }
      }
      {
        name: publicSubnetName
        properties: {
          addressPrefix: '10.0.5.0/24'
          networkSecurityGroup: { id: databricksNsg.id }
          delegations: [
            {
              name: 'databricks-del-public'
              properties: { serviceName: 'Microsoft.Databricks/workspaces' }
            }
          ]
        }
      }
      {
        name: privateSubnetName
        properties: {
          addressPrefix: '10.0.4.0/24'
          networkSecurityGroup: { id: databricksNsg.id }
          delegations: [
            {
              name: 'databricks-del-private'
              properties: { serviceName: 'Microsoft.Databricks/workspaces' }
            }
          ]
        }
      }
    ]
  }
}

// 3. Databricks Workspace
resource databricksWorkspace 'Microsoft.Databricks/workspaces@2024-05-01' = {
  name: workspaceName
  location: location
  sku: { name: 'premium' }
  properties: {
    managedResourceGroupId: subscriptionResourceId('Microsoft.Resources/resourceGroups', managedResourceGroupName)
    parameters: {
      customVirtualNetworkId: { value: vnet.id }
      customPublicSubnetName: { value: publicSubnetName }
      customPrivateSubnetName: { value: privateSubnetName }
      enableNoPublicIp: { value: true }
    }
    publicNetworkAccess: 'Enabled'
  }
}

// 4. Private DNS Zone
resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.azuredatabricks.net'
  location: 'global'
}

resource dnsVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZone
  name: 'link-to-vnet'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnet.id }
  }
}

// 5. Private Endpoints - SEQUENTIAL DEPLOYMENT
// UI/API Private Endpoint - Created FIRST
resource uiPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-09-01' = {
  name: '${workspaceName}-ui-pe'
  location: location
  properties: {
    subnet: { 
      id: '${vnet.id}/subnets/${peSubnetName}'
    }
    privateLinkServiceConnections: [
      {
        name: 'databricks-ui-link'
        properties: {
          privateLinkServiceId: databricksWorkspace.id
          groupIds: ['databricks_ui_api']
        }
      }
    ]
  }
  dependsOn: [
    databricksWorkspace
  ]
}

// Browser Auth Private Endpoint - Created SECOND (depends on UI endpoint)
resource browserAuthPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-09-01' = {
  name: '${workspaceName}-browser-pe'
  location: location
  properties: {
    subnet: { 
      id: '${vnet.id}/subnets/${peSubnetName}'
    }
    privateLinkServiceConnections: [
      {
        name: 'databricks-browser-link'
        properties: {
          privateLinkServiceId: databricksWorkspace.id
          groupIds: ['browser_authentication']
        }
      }
    ]
  }
  dependsOn: [
    uiPrivateEndpoint  // CRITICAL: Wait for UI endpoint to complete
  ]
}

// 6. DNS Zone Groups
resource uiDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = {
  parent: uiPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'config1'
        properties: { privateDnsZoneId: privateDnsZone.id }
      }
    ]
  }
}

resource browserDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = {
  parent: browserAuthPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'config1'
        properties: { privateDnsZoneId: privateDnsZone.id }
      }
    ]
  }
}
