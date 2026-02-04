# Telemetry Ingestion Demo (APIM Standard V2 → Functions Flex → Cosmos DB)

## Overview

This demo provisions a production-grade telemetry ingestion pipeline:

![Architecture diagram](docs/architecture.png)

- **API Management** (Standard V2 tier, External VNet mode with outbound integration)
- **Function App** (Flex Consumption, .NET 8 isolated)
- **Cosmos DB** (NoSQL) with container `telemetry` (partition key `/deviceId`)
- **VNet Architecture** with 3 subnets:
  - APIM Outbound (10.10.1.0/24) - Outbound gateway for backend integration (delegated to Microsoft.Web/serverFarms)
  - Functions (10.10.2.0/24) - Function App VNet integration (delegated to Microsoft.App/environments)
  - Private Endpoint (10.10.3.0/24) - Cosmos DB + Function App private endpoints
- **Private Endpoint + Private DNS** for secure Cosmos DB + Function App access
- **NSG Rules** for APIM outbound subnet with inbound/outbound traffic control
- **Backend Configuration** with automatic Function App routing (private endpoint)

> The Function receives `POST /telemetry`, validates payload, and stores it in Cosmos DB via APIM gateway.

## Folder Structure

- infra/: Bicep templates
  - main.bicep: Main infrastructure deployment
  - network.bicep: VNet, subnets, and NSG configuration
  - apim-policy.bicep: APIM backend and policy (deployed after Function App is ready)
  - parameters.sample.json: Sample parameters file
- functionapp/: .NET 8 isolated Function App
- scripts/: test scripts (test-telemetry.ps1)
- docs/architecture.drawio: architecture diagram

## IaC Deployment (Bicep)

### Prerequisites

Before deploying the Bicep template, ensure you have:

1. **Azure CLI** (v2.50.0 or later)

   - [Install Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)
   - Verify: `az --version`
2. **Azure Account & Subscription**

   - Active Azure subscription with appropriate permissions
   - Logged in to Azure: `az login`
   - Set active subscription: `az account set --subscription "<subscription-id>"`
3. **Required Permissions**

   - Owner or Contributor role on the subscription
   - Ability to create:
     - Resource Groups
     - VNets and Subnets
     - API Management (Standard V2)
     - Function Apps (Flex Consumption)
     - Cosmos DB accounts
     - Network security groups and private endpoints
4. **Resource Limits** (verify in your subscription)

   - At least 1 resource group quota
   - Sufficient vCPU quota for Function App (Flex Consumption)
   - Cosmos DB account quota (typically 5 per subscription by default)
   - APIM Standard V2 quota

### Deployment Steps

#### Phase 1: Infrastructure Deployment

1) Create a resource group:

   ```bash
   az group create --name <rg> --location <region>
   ```
2) Edit parameters (apimPublisherEmail, apimPublisherName):

   ```bash
   cp infra/parameters.sample.json infra/parameters.json
   # Edit parameters.json with your values
   ```
3) Deploy the main Bicep template (infrastructure only, no APIM backend/policy):

   ```bash
   az deployment group create \
     --resource-group <rg> \
     --template-file infra/main.bicep \
     --parameters infra/parameters.json
   ```

   > Note: This deployment takes 15-20 minutes. Monitor progress in Azure Portal under Resource Group → Deployments.

4) Save the output values (you'll need these for Phase 2):

   ```bash
   # Get outputs
   apimName=$(az deployment group show --resource-group <rg> --name main --query properties.outputs.apimName.value -o tsv)
   functionAppName=$(az deployment group show --resource-group <rg> --name main --query properties.outputs.functionAppName.value -o tsv)
   functionAppId=$(az deployment group show --resource-group <rg> --name main --query properties.outputs.functionAppId.value -o tsv)
   ```

#### Phase 2: APIM Backend and Policy Deployment

After the Function App is fully deployed and running, deploy the APIM backend and policy:

```bash
az deployment group create \
  --resource-group <rg> \
  --template-file infra/apim-policy.bicep \
  --parameters apimName=$apimName \
               functionAppName=$functionAppName \
               functionAppId=$functionAppId
```

> **Why two phases?** The APIM backend configuration requires the Function App's host key, which is only available after the Function runtime is fully initialized. Deploying in two phases ensures the Function App is ready before configuring APIM to route requests to it.

### Bicep Resources Created

**Phase 1 (main.bicep + network.bicep)**:
- **VNet** (10.10.0.0/16) with 3 subnets:
  - snet-apim-outbound (10.10.1.0/24) - delegated to Microsoft.Web/serverFarms
  - snet-function (10.10.2.0/24) - delegated to Microsoft.App/environments
  - snet-private-endpoint (10.10.3.0/24) - for private endpoints
- **NSG** for APIM outbound subnet with inbound/outbound rules
- **APIM Service** (Standard V2, External VNet with outbound integration)
- **APIM API** (telemetry-api) with path `/telemetry`
- **APIM Operation** (POST /telemetry)
- **Function App** (Flex Consumption, VNet-integrated)
- **Storage Account** with deployment container
- **Log Analytics Workspace** and **Application Insights**
- **Cosmos DB** with database `telemetrydb` and container `telemetry`
- **Private Endpoints** for Cosmos DB and Function App
- **Private DNS Zones** for privatelink.documents.azure.com and privatelink.azurewebsites.net
- **Role Assignments** for Function App managed identity (Storage Blob Data Owner, Cosmos DB Data Contributor)

**Phase 2 (apim-policy.bicep)**:
- **APIM Backend** - Function App backend with host key authentication
- **APIM Operation Policy** - Routes POST /telemetry requests to Function App backend

## Function App Settings

These are set by the Bicep template (app settings):

- `CosmosDb__AccountEndpoint` - Cosmos DB endpoint
- `CosmosDb__DatabaseName` = `telemetrydb`
- `CosmosDb__ContainerName` = `telemetry`
- `APPLICATIONINSIGHTS_CONNECTION_STRING` - Application Insights connection

The Function App uses **Managed Identity** for Cosmos DB authentication (no connection strings).

## Local Development

### Prerequisites

1. **Azure Functions Core Tools**

   ```bash
   # Windows (via chocolatey)
   choco install azure-functions-core-tools-4

   # Or download from: https://github.com/Azure/azure-functions-core-tools/releases
   ```

   Verify: `func --version`

2. **.NET 8 SDK**

   ```bash
   # Verify
   dotnet --version
   ```

3. **Cosmos DB Emulator** (for local testing)

   - Download from: https://learn.microsoft.com/en-us/azure/cosmos-db/emulator
   - Start the emulator (it runs on `https://localhost:8081` by default)
   - Default primary key: `C2y6yDjf5/R+ob0N8A7Cgv30VRDJIWEHLM+4QDU5DE2nQ9nDuVTqobD4b8mGGyPMbIZnqyMsEcaGQy67XIw/Jw==`

### Running the Function Locally

1) Navigate to the function app directory:

   ```bash
   cd functionapp
   ```

2) Restore NuGet packages:

   ```bash
   dotnet restore
   ```

3) Start the Cosmos DB Emulator (if you don't have it running):

   - Windows: Launch the Emulator application from Start Menu
   - Or check: `https://localhost:8081/_explorer/index.html`

4) Run the Function locally:

   ```bash
   func start
   ```

   Expected output:

   ```
   Functions:

           TelemetryIngest: [POST] http://localhost:7071/api/telemetry

   For detailed output, run func with --verbose flag.
   ```

   The first invocation will:
   - Create the Cosmos DB `telemetrydb` database (if not exists)
   - Create the `telemetry` container (if not exists)
   - Initialize the Cosmos DB client

5) The function is now listening at `http://localhost:7071/api/telemetry`

### Testing the Function Locally

#### Option 1: Using the Test Script

```powershell
# From the scripts directory
cd scripts

# Test the local function
.\test-telemetry.ps1 -BaseUrl "http://localhost:7071"
```

#### Option 2: Using curl

```bash
curl -X POST http://localhost:7071/api/telemetry \
  -H "Content-Type: application/json" \
  -d '{
    "deviceId": "device-001",
    "timestamp": "2026-02-04T08:00:00Z",
    "type": "telemetry",
    "source": "IoT-Sensor",
    "tags": {
      "location": "rack-01"
    },
    "metrics": {
      "temperature": 33.2,
      "humidity": 41.7,
      "vibration": 0.021
    }
  }'
```

#### Option 3: Using PowerShell

```powershell
$payload = @{
  deviceId = "device-001"
  timestamp = [DateTime]::UtcNow.ToString("O")
  type = "telemetry"
  source = "IoT-Sensor"
  tags = @{ location = "rack-01" }
  metrics = @{ temperature = 33.2; humidity = 41.7 }
} | ConvertTo-Json

Invoke-RestMethod -Method Post `
  -Uri "http://localhost:7071/api/telemetry" `
  -ContentType "application/json" `
  -Body $payload
```

#### Expected Response

```json
{
  "id": "8f3e5c2a1b4d6a9e7c2f5b8d3a1e4c7f",
  "deviceId": "device-001",
  "timestamp": "2026-02-04T08:00:00.0000000+00:00"
}
```

#### Verify Data in Cosmos DB Emulator

1. Open `https://localhost:8081/_explorer/index.html` in your browser
2. Navigate to `telemetrydb` → `telemetry` container
3. Click "Items" to view stored documents

### Debugging Locally

Run with verbose output:

```bash
func start --verbose
```

For detailed logging in the code, use the `ILogger`:

```csharp
_logger.LogInformation("Telemetry received for device: {deviceId}", payload.DeviceId);
_logger.LogError(ex, "Failed to store telemetry");
```

## Build & Deploy the Function (CI/CD)

### Option 1: Manual Deployment (Azure Functions Core Tools - Recommended)

This is the simplest method and automatically handles all packaging requirements.

1) Build the Function locally:

   ```bash
   cd functionapp
   dotnet publish -c Release
   ```

2) Deploy using Azure Functions Core Tools:

   ```bash
   # Get your function app name from the Bicep deployment output
   functionAppName="tmdemo-func"
   resourceGroup="rg-tmdemo"

   # Deploy directly (handles .azurefunctions metadata automatically)
   func azure functionapp publish $functionAppName
   ```

3) Verify deployment:

   ```bash
   # Check function app status
   az functionapp show --name $functionAppName --resource-group $resourceGroup

   # Stream logs
   az webapp log tail --name $functionAppName --resource-group $resourceGroup
   ```

### Option 2: VS Code Azure Functions Extension

1) Install extension: **Azure Functions** (ms-azuretools.vscode-azurefunctions)

2) In VS Code:
   - Open Command Palette: `Ctrl+Shift+P`
   - Search: "Azure Functions: Deploy to Function App"
   - Select your subscription and function app
   - Confirm deployment

### Option 3: GitHub Actions Deployment

1) Generate publish profile:

   ```bash
   az functionapp deployment list-publishing-profiles \
     --name $functionAppName \
     --resource-group $resourceGroup \
     --xml > PublishProfile.xml
   ```

2) Add repository secrets in GitHub:

   - `AZURE_FUNCTIONAPP_PUBLISH_PROFILE`: Copy contents of `PublishProfile.xml`
   - `AZURE_FUNCTIONAPP_NAME`: Your function app name (e.g., `tmdemo-func`)

3) Create `.github/workflows/functionapp-ci.yml`:

   ```yaml
   name: Deploy Function App (Flex Consumption)

   on:
     push:
       branches:
         - main
       paths:
         - 'functionapp/**'

   jobs:
     build-and-deploy:
       runs-on: ubuntu-latest
       steps:
         - name: Checkout
           uses: actions/checkout@v4

         - name: Setup .NET
           uses: actions/setup-dotnet@v4
           with:
             dotnet-version: '8.0.x'

         - name: Restore
           run: dotnet restore functionapp/Telemetry.FunctionApp.csproj

         - name: Build
           run: dotnet build functionapp/Telemetry.FunctionApp.csproj -c Release --no-restore

         - name: Publish
           run: dotnet publish functionapp/Telemetry.FunctionApp.csproj -c Release -o functionapp/publish

         - name: Deploy to Azure Functions
           uses: Azure/functions-action@v1
           with:
             app-name: ${{ secrets.AZURE_FUNCTIONAPP_NAME }}
             publish-profile: ${{ secrets.AZURE_FUNCTIONAPP_PUBLISH_PROFILE }}
             package: functionapp/publish
   ```

4) Commit and push to trigger the workflow:

   ```bash
   git add .github/workflows/functionapp-ci.yml
   git commit -m "Add GitHub Actions CI/CD workflow"
   git push origin main
   ```

### Testing Deployed Function

After deployment, test the function via its public URL:

```bash
functionAppName="tmdemo-func"
functionUrl="https://$functionAppName.azurewebsites.net/api/telemetry"

# Get the function key (if needed)
functionKey=$(az functionapp keys list --name $functionAppName --resource-group $resourceGroup --query "functionKeys.default" -o tsv)

# Test with PowerShell
$payload = @{
  deviceId = "device-prod-001"
  timestamp = [DateTime]::UtcNow.ToString("O")
  type = "telemetry"
  source = "Production-Sensor"
  metrics = @{ temperature = 32.5; humidity = 42.1 }
} | ConvertTo-Json

Invoke-RestMethod -Method Post -Uri $functionUrl `
  -ContentType "application/json" `
  -Body $payload `
  -Headers @{ "x-functions-key" = $functionKey }
```

### Monitoring Deployed Function

View logs in Azure Portal:

1. Go to Function App → Functions → TelemetryIngest
2. Monitor tab shows invocations and errors
3. Log Stream shows real-time logs

Or use CLI:

```bash
# Stream logs
az webapp log tail --name $functionAppName --resource-group $resourceGroup

# View Application Insights
az monitor app-insights metrics show \
  --app $functionAppName \
  --resource-group $resourceGroup
```

### Rollback Deployment

If needed, rollback to previous version:

```bash
# Swap slots (if using deployment slots)
az functionapp deployment slot swap \
  --name $functionAppName \
  --resource-group $resourceGroup \
  --slot staging
```

### GitHub Actions

## APIM Configuration

- **API**: `telemetry-api` (path: `/telemetry`)
- **Backend**: Function App (https://{functionAppName}.azurewebsites.net/api) via private DNS + private endpoint
- **Operation**: `POST /telemetry`
- **Authentication**: Function App host key (x-functions-key header)
- **Policy**: `set-backend-service` to route requests to Function App backend

### Testing APIM Gateway

```powershell
# Get APIM gateway URL
$apimName = "tmdemo-apim"
$gateway = az apim show --name $apimName --resource-group <rg> --query "gatewayUrl" -o tsv

# Send test payload
$payload = @{
  deviceId = "device-001"
  timestamp = [DateTime]::UtcNow.ToString("O")
  type = "telemetry"
  source = "IoT-Sensor"
  tags = @{ location = "rack-01" }
  metrics = @{ temperature = 33.2; humidity = 41.7 }
} | ConvertTo-Json

Invoke-RestMethod -Method Post -Uri "$gateway/telemetry/telemetry" -ContentType "application/json" -Body $payload
```

## Test Script

Run direct Function test (requires private network access to the Function App):

```powershell
./scripts/test-telemetry.ps1 -BaseUrl "https://<functionapp>.azurewebsites.net"
```

Or test via APIM gateway:

```powershell
./scripts/test-telemetry.ps1 -BaseUrl "<apim-gateway-url>/telemetry"
```

## VNet Integration Details

### Subnet Configuration

- **snet-apim-outbound** (10.10.1.0/24)
  - Delegation: Microsoft.Web/serverFarms
  - Purpose: APIM Standard V2 outbound virtual network integration
  - NSG: Applied with required inbound/outbound rules
  
- **snet-function** (10.10.2.0/24)
  - Delegation: Microsoft.App/environments
  - Purpose: Function App (Flex Consumption) VNet integration
  - Service Endpoints: Microsoft.Storage

- **snet-private-endpoint** (10.10.3.0/24)
  - Purpose: Private endpoints for Cosmos DB and Function App
  - Network Policies: Disabled for private endpoints

### NSG Rules (APIM Outbound Subnet)

**Inbound**:

- Port 3443: ApiManagement → control plane
- Port 443: VirtualNetwork → internal communication
- Port 6390: AzureLoadBalancer → health probes

**Outbound**:

- VNet → VNet: internal communication
- VNet → Internet: backend connectivity
- VNet → AzureCloud: Azure services

## Security Features

1. **Private Endpoints**: Cosmos DB and Function App not exposed to public internet
2. **Function App Public Access Disabled**: Inbound access only via private endpoint
3. **Managed Identity**: Function App authenticates to Storage and Cosmos DB without secrets
4. **NSG Rules**: Principle of least privilege for APIM outbound network access
5. **External APIM with VNet Integration**: API gateway publicly accessible but can reach private backends
6. **Two-Phase Deployment**: Function App host keys secured until runtime is ready

## Monitoring

- **Application Insights**: Application performance and custom metrics
- **Log Analytics**: Centralized logging for APIM, Function App, Cosmos DB

Query APIM logs:

```powershell
az monitor log-analytics query \
  --workspace "tmdemo-log" \
  --analytics-query "AzureDiagnostics | where ResourceProvider == 'MICROSOFT.APIMANAGEMENT' | limit 50"
```

## Cost Optimization

- **APIM Standard V2**: ~$0.40/hour (vs ~$0.59/hour for Developer)
- **Flex Consumption**: Pay only for executed invocations
- **Cosmos DB**: 400 RU/s (adjustable, pay per RU)
- **Private Endpoint**: $0.01/hour

## Next Steps

1. Review and edit `infra/parameters.json`
2. Deploy Phase 1 infrastructure with `az deployment group create`
3. Wait for Function App runtime to initialize (5-10 minutes)
4. Deploy Phase 2 APIM backend and policy with `az deployment group create`
5. Deploy Function code (via GitHub Actions or manual deployment)
6. Test via APIM gateway or Function direct URL
7. Monitor in Application Insights dashboard

## Architecture Notes

- **APIM Standard V2**: Supports outbound VNet integration (not full VNet injection like Premium v2)
- **Function Flex Consumption**: Requires delegation to Microsoft.App/environments
- **Two-Phase Deployment**: Necessary because Function host keys are only available after runtime initialization
