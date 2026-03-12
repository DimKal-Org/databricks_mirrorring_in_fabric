// ==============================
// PARAMETERS (inputs to customize the deployment)
// ==============================

@description('The name of the Virtual Machine.')
param virtualMachineName string = 'simple-vm'

@description('The virtual machine size/SKU.')
param virtualMachineSize string = 'Standard_D8s_v3'

@description('Location for all resources (defaults to the resource group location).')
param location string = resourceGroup().location

@description('Admin username for the VM local administrator account.')
param adminUsername string = 'azureadmin'

@description('Admin password for the VM local administrator account.')
@secure()
param adminPassword string

@description('Specify the name of an existing VNet (Virtual Network).')
param existingVirtualNetworkName string = 'databricks-vnet'

@description('Specify the resource group name where the existing VNet lives.')
param existingVnetResourceGroup string = 'databricks-secure-access'

@description('Specify the name of the existing subnet within the VNet.')
param existingSubnetName string = 'PESubnetVM'

@description('Security type for the VM. TrustedLaunch enables Secure Boot + vTPM.')
@allowed([
  'Standard'
  'TrustedLaunch'
])
param securityType string = 'TrustedLaunch'

@description('Optional: Restrict RDP to a single public IP (CIDR). Example: 1.2.3.4/32. Use * to allow from anywhere (not recommended).')
param rdpSourceCidr string = '*'


// ==============================
// VARIABLES (computed names/IDs used across resources)
// ==============================
// These build consistent resource names based on the VM name
var networkInterfaceName = '${virtualMachineName}-nic'
var networkSecurityGroupName = '${virtualMachineName}-nsg'
var publicIpAddressName = '${virtualMachineName}-pip-${uniqueString(virtualMachineName)}'

// Public IP settings: Standard + Static is a modern recommended baseline
var publicIpAddressSku = 'Standard'
var publicIpAddressType = 'Static'

// Subnet resource ID for an EXISTING subnet in an EXISTING VNet (possibly in another RG)
// This lets you attach the VM NIC to a subnet without creating the VNet in this template.
var subnetRef = resourceId(
  existingVnetResourceGroup,
  'Microsoft.Network/virtualNetworks/subnets',
  existingVirtualNetworkName,
  existingSubnetName
)

// Trusted Launch security profile JSON (only applied if securityType == 'TrustedLaunch')
var securityProfileJson = {
  uefiSettings: {
    secureBootEnabled: true
    vTpmEnabled: true
  }
  securityType: securityType
}

// NSG inbound rules: allows RDP (3389). Use rdpSourceCidr to restrict exposure.
var networkSecurityGroupRules = [
  {
    name: 'Allow-RDP'
    properties: {
      priority: 300
      protocol: 'Tcp'
      access: 'Allow'
      direction: 'Inbound'
      sourceAddressPrefix: rdpSourceCidr
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '3389'
    }
  }
]

// ==============================
// RESOURCE: Public IP Address
// Creates an IP that can be assigned to the NIC for inbound access.
// ==============================
resource publicIpAddress 'Microsoft.Network/publicIPAddresses@2022-01-01' = {
  name: publicIpAddressName
  location: location
  sku: {
    name: publicIpAddressSku
  }
  properties: {
    publicIPAllocationMethod: publicIpAddressType
  }
}

// ==============================
// RESOURCE: Network Security Group (NSG)
// Provides firewall rules for inbound/outbound traffic for the NIC/subnet.
// ==============================
resource networkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2022-01-01' = {
  name: networkSecurityGroupName
  location: location
  properties: {
    securityRules: networkSecurityGroupRules
  }
}

// ==============================
// RESOURCE: Network Interface (NIC)
// Connects the VM to the subnet and attaches the NSG and Public IP.
// ==============================
resource networkInterface 'Microsoft.Network/networkInterfaces@2022-01-01' = {
  name: networkInterfaceName
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: subnetRef
          }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: publicIpAddress.id
          }
        }
      }
    ]
    // Accelerated networking improves throughput/latency for supported VM sizes/SKUs
    enableAcceleratedNetworking: true

    // Attach NSG to enforce traffic rules at the NIC level
    networkSecurityGroup: {
      id: networkSecurityGroup.id
    }
  }
}

// ==============================
// RESOURCE: Virtual Machine
// Creates the VM using a generic Windows Server image (NOT SQL).
// ==============================
resource virtualMachine 'Microsoft.Compute/virtualMachines@2022-03-01' = {
  name: virtualMachineName
  location: location
  properties: {

    // VM size/SKU (CPU/RAM/network limits)
    hardwareProfile: {
      vmSize: virtualMachineSize
    }

    // Storage profile: OS disk + OS image reference
    storageProfile: {
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          // Use StandardSSD_LRS for better baseline perf than Standard_LRS (optional)
          storageAccountType: 'StandardSSD_LRS'
        }
      }

      // Windows Server "blank" base image
      // This is the standard VM quickstart pattern for Windows VMs.
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2025-datacenter-g2'
        version: 'latest'
      }
    }

    // Network: connect the VM to the NIC we created
    networkProfile: {
      networkInterfaces: [
        {
          id: networkInterface.id
        }
      ]
    }

    // OS configuration: local admin and Windows agent settings
    osProfile: {
      computerName: virtualMachineName
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: true
        provisionVMAgent: true
      }
    }

    // Security profile: applied only when Trusted Launch is selected
    securityProfile: (securityType == 'TrustedLaunch') ? securityProfileJson : null
  }
}

// ==============================
// OUTPUTS (values printed after deployment)
// Useful for scripts and automation.
// ==============================
output adminUsername string = adminUsername
output publicIpAddress string = publicIpAddress.properties.ipAddress

// Deployment Command (Run in Azure CLI)

// $RgName = 'fabric-databricks-security'
// az deployment group create \
// --name deployVM \
// --resource-group $RgName \
// --template-file SimpleVM.bicep \
// --parameters virtualMachineName='simple-vm' virtualMachineSize='Standard_D8s_v3' adminUsername='azureadmin' adminPassword='Azure_windows_VM!2026' existingVirtualNetworkName='vnet-databricks-fabric' existingVnetResourceGroup=$RgName
// Make sure to set the $RgName variable to your target resource group before running this command.
