# End-to-End Secure Databricks Mirroring in Microsoft Fabric over Private Endpoints

### Description
This playbook provides a comprehensive, step-by-step guide for implementing Databricks Mirroring into Microsoft Fabric in fully private network environments. It covers both the infrastructure prerequisites, resource deployment and the detailed configuration required when the Databricks control plane and its underlying storage are secured behind Private Endpoints. **The guide is designed to help architects and engineers achieve a secure, repeatable, and production-ready demo or guided integration** without compromising network isolation or governance.


## Infrastructure Setup: Databricks Mirroring in Fabric with Private Networking

This section describes the infrastructure deployment for enabling **Databricks Mirroring in Microsoft Fabric** when both Azure Databricks and the underlying Azure Data Lake Storage (ADLS) Gen2 are deployed within a **Virtual Network (VNet)** and secured behind **private endpoints**. This architecture ensures that all data access occurs over private network paths, eliminating exposure to the public internet and meeting enterprise security and compliance requirements.

The infrastructure is deployed using three Bicep templates that work together to create a complete, secure environment for Databricks-to-Fabric data mirroring.

---

### 🎯 Architecture Overview

The deployment creates a **private, network-isolated environment** with the following key characteristics:

- **VNet-Injected Azure Databricks Workspace** with no public IP addresses
- **ADLS Gen2 Storage Account** with network access restrictions and firewall rules
- **Private Endpoints** for Databricks UI/API and browser authentication
- **Private DNS resolution** for seamless connectivity within the VNet
- **Windows Jump Box VM** for secure administrative access to private resources

This architecture is critical for scenarios where:
- Data must remain within a private network boundary
- Public internet access to data storage and compute is prohibited
- Compliance frameworks require network isolation (e.g., financial services, healthcare)
- Fabric mirroring needs to access Databricks workspaces through private connectivity

---
## 🛠️ Step 1: Infrastructure Setup
### 📦 (Infra) Bicep File #1: Databricks Workspace with VNet Injection

**File**: `databricks-vnet.bicep`

#### Purpose

This Bicep template deploys a **Premium Azure Databricks workspace** with full VNet injection, private endpoints, and private DNS resolution. It creates the foundational network infrastructure and configures Databricks to operate entirely within a private network, ensuring no data egress over public networks.

#### Why This Matters for Databricks Mirroring

Databricks Mirroring in Fabric requires connectivity to the Databricks workspace. When operating in a secure environment, the workspace must be accessible via **private endpoints** rather than public endpoints. This template ensures:
- The Databricks control plane and data plane communicate over private IPs
- All user and application traffic to Databricks flows through the VNet
- DNS resolution automatically directs traffic to private endpoint IPs


#### 🔒 Add Private Endpoints for secure access to Databricks

To ensure secure access to Databricks workspace, create two private endpoints:

- One for `ui` (privatelink.azuredatabricks.net)
- One for `browser` (privatelink.azuredatabricks.net)

Deploy both endpoints into the `PESubnet`.


#### Resources Deployed

| Resource Type | Resource Name | Purpose | Key Configuration |
|--------------|---------------|---------|-------------------|
| Network Security Group | nsg-databricks | Controls traffic for Databricks subnets | Empty rules (Databricks manages rules) |
| Virtual Network | vnet-databricks | Isolated network for Databricks and storage | 10.0.0.0/16 with 4 subnets |
| Subnets | PESubnet, PESubnetVM, VNetGatewaySubnet, public-subnet-dbx, private-subnet-dbx | Segregated traffic for endpoints, gateway, and Databricks | Delegated to Databricks, NSG attached |
| Databricks Workspace | dbw-injected-workspace | VNet-injected workspace | Premium SKU, no public IP, private endpoints |
| Private DNS Zone | privatelink.azuredatabricks.net | DNS for private endpoints | Linked to VNet |
| Private Endpoints | UI/API, Browser Auth | Private access to Databricks services | Group IDs: databricks_ui_api, browser_authentication |
| DNS Zone Groups | uiDnsGroup, browserDnsGroup | Auto-register private IPs | Linked to DNS zone |

---

📢 **Go to the 'Networking' blade of the Databricks workspace resource and Disable the public access. You will be accessing the workspace through the VM only.**

#### 🔧 Execution in Azure CLI:
```bash
# Make sure to set the $RgName variable to your target resource group before running this command.
$RgName='fabric-databricks-security'
$vnet_name='vnet-databricks-fabric'
$workspace_name='dbx-demo-workspace'
az deployment group create \
--name deployVNetDatabricks \
--resource-group $RgName \
--template-file "databricks-vnet.bicep" \
--parameters vnetName=$vnet_name workspaceName=$workspace_name
```

### 📦 (Infra) Bicep File #2: ADLS Gen2 Storage Account with Network Restrictions

**File**: `deploy-adls.bicep`

#### Purpose

This template deploys an **Azure Data Lake Storage (ADLS) Gen2 account** with strict network access controls. It ensures that the storage is only accessible from trusted networks and services.

#### Why This Matters for Databricks Mirroring

Fabric must access the ADLS Gen2 storage where Databricks stores data. This template ensures:
- Public access is disabled
- Access is restricted to specific IPs or Azure services
- Hierarchical Namespace is enabled for Delta Lake compatibility


#### 🔒 Add Private Endpoints for Storage

To ensure secure access from Databricks to the storage account, create two private endpoints:

- One for `blob` (blob.core.windows.net)
- One for `dfs` (dfs.core.windows.net)

Deploy both endpoints into the `PESubnet`.

> 🔐 These endpoints ensure that all traffic between Databricks and the storage account remains within the VNet.

#### Resources Deployed

| Resource Type | Resource Name | Purpose | Key Configuration |
|--------------|---------------|---------|-------------------|
| Storage Accounts | storage account name | ADLS Gen2–enabled storage account used as the data lake | StorageV2, Standard_LRS, isHnsEnabled=true, publicNetworkAccess=Disabled, allowBlobPublicAccess=false, network ACLs with defaultAction=Deny and IP allow rule |
| Blob Services - Containers | container name | Blob container within the storage account | publicAccess=None |
| Private Dns Zones | privatelink.blob.core.windows.net | Private DNS zone for Blob service private endpoint name resolution | Location: global |
| Private Dns Zones | privatelink.dfs.core.windows.net | Private DNS zone for DFS (ADLS Gen2) private endpoint name resolution | Location: global |
| Virtual Network Links | link-to-vnet-blob | Links Blob private DNS zone to the existing VNet | registrationEnabled=false, linked to existing VNet |
| Virtual Network Links | link-to-vnet-dfs | Links DFS private DNS zone to the existing VNet | registrationEnabled=false, linked to existing VNet |
| Private Endpoints | ${storageAccountName}-blob-pe | Private endpoint for Blob service access to the storage account | Subnet: ${peSubnetName}, groupIds=['blob'], dependsOn storage account |
| Private Endpoints | ${storageAccountName}-dfs-pe | Private endpoint for DFS (ADLS Gen2) service access | Subnet: ${peSubnetName}, groupIds=['dfs'], dependsOn Blob private endpoint |
| Private Dns Zone Groups | default (Blob PE) | Associates Blob private endpoint with Blob private DNS zone | Linked to privatelink.blob.core.windows.net |
| Private Dns Zone Groups | default (DFS PE) | Associates DFS private endpoint with DFS private DNS zone | Linked to privatelink.dfs.core.windows.net |

---

#### 🔧 Execution in Azure CLI:
> ***IMPORTANT !!!***

> Run the following command in your laptop and get your Public IP address.
```bash
$ipaddr = (Invoke-WebRequest -Uri 'https://api.ipify.org').Content
```

```bash
# Deployment Command (Run in Azure CLI)
$RgName='fabric-databricks-security'
$storage_account_name='storageaccountdbxfabric'
$container_name='samplecontainer'
$ipaddr='<your IP>'
$vnet_name='vnet-databricks-fabric'
az deployment group create \
--name deployADLS \
--resource-group $RgName \
--template-file "deploy-adls.bicep" \
--parameters myIpAddress=$ipaddr storageAccountName=$storage_account_name containerName=$container_name vnetName=$vnet_name
```

📢 **Add the role Blob Data Contributor to your account.**

📢 **Create a folder in the container you just created and call it `fabric_catalog`.**

### 📦 (Infra) Bicep File #3: Windows Jump Box VM for Secure Access

**File**: `simple-vm.bicep`

#### Purpose

This template deploys a **Windows Server 2025 VM** as a **jump box** for secure access to private resources. It enables administrators to manage Databricks and storage from within the VNet.

#### Why This Matters for Databricks Mirroring

With all resources behind private endpoints, a jump box is required to:
- Access Databricks UI and APIs
- Run administrative tools and scripts
- Test connectivity and configure mirroring


#### Resources Deployed

| Resource Type | Resource Name | Purpose | Key Configuration |
|--------------|---------------|---------|-------------------|
| Virtual Machine | simple-vm | Admin access to private network | Windows Server 2025, Trusted Launch |
| Network Interface | simple-vm-nic | Connects VM to VNet | Accelerated networking, NSG attached |
| Public IP | simple-vm-pip | RDP access | Static, Standard SKU |
| Network Security Group | simple-vm-nsg | RDP firewall rules | Allows port 3389 from specified CIDR |

---

#### 🔧 Execution in Azure CLI:
```bash
# Deployment Command (Run in Azure CLI)
$RgName = 'fabric-databricks-security'
$virtual_machine_name='simple-vm'
$virtual_machine_size='Standard_D8s_v3'
$admin_user_name='azureadmin'
$admin_password='YOUR_SECURE_PASSWORD!2026'
$existing_virtual_network_name='vnet-databricks-fabric'
az deployment group create \
--name deployVM \
--resource-group $RgName \
--template-file simple-vm.bicep \
--parameters virtualMachineName=$virtual_machine_name virtualMachineSize=$virtual_machine_size adminUsername=$admin_user_name adminPassword=$admin_password existingVirtualNetworkName=$existing_virtual_network_name existingVnetResourceGroup=$RgName
```

### 🔗 How the Three Templates Work Together

1. **databricks-vnet.bicep**: Sets up the VNet, subnets, NSG, Databricks workspace, private endpoints, and DNS.
2. **deploy-adls.bicep**: Deploys the ADLS Gen2 storage with secure access.
3. **simple-vm.bicep**: Deploys a jump box VM for secure access to the private network.

---

## 🔧 Step 2: Databricks Configuration for Mirroring

### Objective
Configure Azure Databricks to securely access the ADLS Gen2 storage account deployed in the previous step, enabling Fabric to mirror data from Databricks.

### Tasks

#### 1. Configure Databricks Access to Storage

From the Databricks workspace:

**a. Create Storage Credential in Databricks UI**
1. Open Databricks workspace > **Catalog Explorer**
2. Go to **External data > Credentials**
3. Click **Create credential**
4. Select **Azure Managed Identity**
5. Enter:
   - Credential name
   - Access Connector Resource ID (The resource Id of the databricks unity catalog resource "unity-catalog-access-connector".)
6. Click **Create**

> 🛡️ **Important**: Ensure that the Azure resource representing the Unity Catalog (typically a managed identity or service principal) is assigned the **Storage Blob Data Contributor** role on the ADLS Gen2 storage account. This permission is required for Unity Catalog to access and manage data in the external location.

**b. Grant Permissions on Credential**

1. Open the credential > **Permissions** tab
2. Click **Grant**
3. Assign privileges to users or groups

**c. Create an External Location**
1. Go to **External data > External Locations**
2. Click **Create location**
3. Enter:
   - Name
   - Storage Credential
   - URL (e.g., `abfss://<container>@<storage>.dfs.core.windows.net/<folder_in_container>`)
4. Click **Create**

> 🔐 Ensure that the credential has access to both the blob and dfs endpoints.

**d. (Optional) Grant Permissions on External Location**

1. Open the external location > **Permissions** tab
2. Click **Grant**
3. Assign privileges to users or groups

**e. Create a Catalog**

Create a Unity Catalog that uses the external location as its storage root. This allows Fabric to discover and mirror tables from Databricks.

**f. Run the test to ensure that traffic to the storage account is routed through the private endpoint.**

Run the following script using a Notebook to ensure that traffic is routed through the private endpoint. ***You have to create a cluster first!***
```python
import socket

# Replace with your storage account name
storage_account_name = "storageaccountdbxfabric"
# Use 'dfs' for ADLS Gen2 or 'blob' for standard blob
endpoint = f"{storage_account_name}.dfs.core.windows.net"

try:
    # 1. Check DNS Resolution
    ip_address = socket.gethostbyname(endpoint)
    print(f"✅ DNS Resolved {endpoint} to: {ip_address}")
    
    # 2. Check if it's a Private IP (usually 10.x.x.x or similar in your VNet range)
    if ip_address.startswith("10.") or ip_address.startswith("192.168.") or ip_address.startswith("172."):
        print("🔒 Confirmed: Traffic is routing via Private IP.")
    else:
        print("⚠️ Warning: Traffic resolved to a Public IP. Check NCC configuration.")

except Exception as e:
    print(f"❌ Connection Failed: {e}")
```

**g. Create sample data to the catalog you created**

**h. Enable External Data Access**** Step 4: Create Storage Credential in Databricks UI

#### 🔓 Enable External Data Access on the Metastore

1. Open Databricks workspace > **Catalog Explorer**
2. Go to **Metastore > Credentials**
3. Click **Enable External Data Access**

Before Fabric can mirror data from Unity Catalog, external data access must be enabled on the metastore. Run the following command.
```python
spark.sql("GRANT EXTERNAL USE SCHEMA ON SCHEMA <catalog_name>.<database_name> TO `user@company.com`")
```

> 📘 Refer to the official documentation: https://learn.microsoft.com/en-us/fabric/mirroring/azure-databricks-tutorial#prerequisites

---
### ✅ Validation Checklist

- [ ] Blob and DFS private endpoints are created and in `Approved` state
- [ ] Databricks workspace has a managed identity with access to the storage account
- [ ] Storage credential is created in Databricks
- [ ] External location is created and points to the correct container
- [ ] Catalog is created and accessible in Unity Catalog


### 🔍 Next Step
Proceed to configuring Microsoft Fabric to connect to the Databricks workspace and enable mirroring from the newly created catalog.

## 🌐 Step 3: Configure Microsoft Fabric for Private Network Access

### Objective
Enable Microsoft Fabric to securely connect to the Databricks workspace and ADLS Gen2 storage account using the private network infrastructure created earlier.

### Tasks

> 🔗 For detailed steps on configuring Trusted Workspace Access, refer to: https://learn.microsoft.com/en-us/fabric/security/trusted-workspace-access

#### 1. Create a VNet Data Gateway

In Microsoft Fabric:
- Navigate to the **VNet Data Gateway** section.
- Create a new gateway using the **`VNetGatewaySubnet`** that was provisioned in Step 1.
- Ensure that the subnet is **delegated to the Power Platform (vnetaccesslinks)**.

> ⚠️ Delegation is required for the gateway to function correctly.

#### 2. Establish Trusted Workspace Access to Storage

- Enable **Workspace Identity** on the Fabric workspace that will perform the mirroring.
- Retrieve the **Managed Identity** of the workspace.
- Assign the identity the **Storage Blob Data Reader** role on the ADLS Gen2 storage account.

#### 3. Handle Network Restrictions

To allow Fabric to access the storage account:

**Option A (Temporary Public Access):**
- Temporarily enable public access on the storage account.
- Add the Fabric workspace id as **trusted source**.
- Once the connection is established, **re-disable public access**.

**Option B (Custom Deployment):**
- Deploy a **custom private endpoint** or **managed private endpoint** to allow Fabric to access the storage account without enabling public access.
```json
{
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
    "contentVersion": "1.0.0.0",
    "resources": [
        {
            "type": "Microsoft.Storage/storageAccounts",
            "apiVersion": "2023-01-01",
            "name": "<storageaccountname>",
            "id": "/subscriptions/<subscription ID>/resourceGroups/<resourcegroup>/providers/Microsoft.Storage/storageAccounts/<storageaccountname>",
            "location": "<Azure Region>",
            "kind": "StorageV2",
            "properties": {
                "networkAcls": {
                    "resourceAccessRules": [
                        {
                            "tenantId": "<tenant ID>",
                            "resourceId": "/subscriptions/<subscription ID>/resourcegroups/Fabric/providers/Microsoft.Fabric/workspaces/<Fabric workspace ID>"
                        }]
                }
            }
        }
    ]
}

```
---

> 🛡️ **Important**: Ensure that the Fabric Workspace Managed Identity is assigned the **Storage Blob Data Reader** role on the ADLS Gen2 storage account. This permission is required for the Fabric Workspace to access and read tje data from the storage account.

## 🔁 Step 4: Create Fabric Connections and Enable Mirroring

### Objective
Create the necessary connections in Fabric to Databricks and ADLS Gen2, and configure the mirroring item.

### Tasks

#### 1. Create a new virtual network data gateway in Fabric
> ⚠️ You need to create a new VNet Data gateway that will use the `VNetGatewaySubnet` subnet that was created in Step 1.

1. Go to **Manage connections and gateways**.
2. Click on **Virtual network data gateways** tab.
3. Click **New**.
4. Select the appropriate options on the fields that are present.
5. Click **Save**.

#### 2. Create Connections in Fabric

> ⚠️ You must create the Databricks and Storage connections in advance using **Settings > Manage connections and gateways**. These connections cannot be created inline during the mirroring item creation process.

- **Connection 1: Azure Databricks**
  - Use the **VNet Data Gateway** created in point 1.
  - Choose an appropriate **authentication method** (e.g., OAuth 2.0, personal access token, Azure AD passthrough).

- **Connection 2: ADLS Gen2 Storage**
  - Use the **VNet Data Gateway**.
  - Authenticate using the **Workspace Identity**.

#### 3. Create the Mirroring Item

- In Fabric, open the workspace for which you enabled the identity and create a new **Item**.
- Select a **Databricks Mirroring** item.
- Select the **Databricks connection** in the **Data Tab**. This will be used to connect to the control plane.
- Select the **Storage connection** in the **Network Security**. This will be used to connect to the data plane.
- Configure the mirroring settings (e.g. table selection).

>### ✅ Once configured, Fabric will begin mirroring data from Databricks into OneLake using the secure, private network path.
