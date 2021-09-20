param(
    [Parameter(Mandatory = $false)]
    [bool] $Simulate = $true
)

$ErrorActionPreference = "Stop"

$cloudEnvironment = Get-AutomationVariable -Name "AzureOptimization_CloudEnvironment" -ErrorAction SilentlyContinue # AzureCloud|AzureChinaCloud
if ([string]::IsNullOrEmpty($cloudEnvironment))
{
    $cloudEnvironment = "AzureCloud"
}
$authenticationOption = Get-AutomationVariable -Name "AzureOptimization_AuthenticationOption" -ErrorAction SilentlyContinue # RunAsAccount|ManagedIdentity
if ([string]::IsNullOrEmpty($authenticationOption))
{
    $authenticationOption = "RunAsAccount"
}

$sqlserver = Get-AutomationVariable -Name  "AzureOptimization_SQLServerHostname"
$sqlserverCredential = Get-AutomationPSCredential -Name "AzureOptimization_SQLServerCredential"
$SqlUsername = $sqlserverCredential.UserName 
$SqlPass = $sqlserverCredential.GetNetworkCredential().Password 
$sqldatabase = Get-AutomationVariable -Name  "AzureOptimization_SQLServerDatabase" -ErrorAction SilentlyContinue
if ([string]::IsNullOrEmpty($sqldatabase))
{
    $sqldatabase = "azureoptimization"
}
$storageAccountSink = Get-AutomationVariable -Name  "AzureOptimization_StorageSink"
$storageAccountSinkRG = Get-AutomationVariable -Name  "AzureOptimization_StorageSinkRG"
$storageAccountSinkSubscriptionId = Get-AutomationVariable -Name  "AzureOptimization_StorageSinkSubId"
$storageAccountSinkContainer = Get-AutomationVariable -Name  "AzureOptimization_RemediationLogsContainer" -ErrorAction SilentlyContinue 
if ([string]::IsNullOrEmpty($storageAccountSinkContainer)) {
    $storageAccountSinkContainer = "remediationlogs"
}

$minFitScore = [double] (Get-AutomationVariable -Name  "AzureOptimization_RemediateUnattachedDisksMinFitScore" -ErrorAction SilentlyContinue)
if (-not($minFitScore -gt 0.0)) {
    $minFitScore = 5.0
}

$minWeeksInARow = [int] (Get-AutomationVariable -Name  "AzureOptimization_RemediateUnattachedDisksMinWeeksInARow" -ErrorAction SilentlyContinue)
if (-not($minWeeksInARow -gt 0)) {
    $minWeeksInARow = 4
}

$tagsFilter = Get-AutomationVariable -Name  "AzureOptimization_RemediateUnattachedDisksTagsFilter" -ErrorAction SilentlyContinue
# example: '[ { "tagName": "a", "tagValue": "b" }, { "tagName": "c", "tagValue": "d" } ]'
if (-not($tagsFilter)) {
    $tagsFilter = '{}'
}
$tagsFilter = $tagsFilter | ConvertFrom-Json

$remediationAction = [double] (Get-AutomationVariable -Name  "AzureOptimization_RemediateUnattachedDisksAction" -ErrorAction SilentlyContinue) # Delete / Downsize
if (-not($remediationAction)) {
    $remediationAction = "Delete"
}

$recommendationId = Get-AutomationVariable -Name  "AzureOptimization_RecommendationUnattachedDisksId" -ErrorAction SilentlyContinue
if (-not($recommendationId)) {
    $recommendationId = 'c84d5e86-e2d6-4d62-be7c-cecfbd73b0db'
}

$SqlTimeout = 0
$recommendationsTable = "Recommendations"

Write-Output "Logging in to Azure with $authenticationOption..."

switch ($authenticationOption) {
    "RunAsAccount" { 
        $ArmConn = Get-AutomationConnection -Name AzureRunAsConnection
        Connect-AzAccount -ServicePrincipal -EnvironmentName $cloudEnvironment -Tenant $ArmConn.TenantID -ApplicationId $ArmConn.ApplicationID -CertificateThumbprint $ArmConn.CertificateThumbprint
        break
    }
    "ManagedIdentity" { 
        Connect-AzAccount -Identity
        break
    }
    Default {
        $ArmConn = Get-AutomationConnection -Name AzureRunAsConnection
        Connect-AzAccount -ServicePrincipal -EnvironmentName $cloudEnvironment -Tenant $ArmConn.TenantID -ApplicationId $ArmConn.ApplicationID -CertificateThumbprint $ArmConn.CertificateThumbprint
        break
    }
}

# get reference to storage sink
Select-AzSubscription -SubscriptionId $storageAccountSinkSubscriptionId
$sa = Get-AzStorageAccount -ResourceGroupName $storageAccountSinkRG -Name $storageAccountSink

Write-Output "Querying for unattached disks recommendations with fit score >= $minFitScore made consecutively for the last $minWeeksInARow weeks."

$tries = 0
$connectionSuccess = $false
do {
    $tries++
    try {
        $Conn = New-Object System.Data.SqlClient.SqlConnection("Server=tcp:$sqlserver,1433;Database=$sqldatabase;User ID=$SqlUsername;Password=$SqlPass;Trusted_Connection=False;Encrypt=True;Connection Timeout=$SqlTimeout;") 
        $Conn.Open() 
        $Cmd=new-object system.Data.SqlClient.SqlCommand
        $Cmd.Connection = $Conn
        $Cmd.CommandTimeout = $SqlTimeout
        $Cmd.CommandText = @"
        SELECT InstanceId, Cloud, TenantGuid, COUNT(InstanceId)
        FROM [dbo].[$recommendationsTable] 
        WHERE RecommendationSubTypeId = '$recommendationId' AND FitScore >= $minFitScore AND GeneratedDate >= GETDATE()-(7*$minWeeksInARow)
        GROUP BY InstanceId, Cloud, TenantGuid
        HAVING COUNT(InstanceId) >= $minWeeksInARow
"@    
        $sqlAdapter = New-Object System.Data.SqlClient.SqlDataAdapter
        $sqlAdapter.SelectCommand = $Cmd
        $unattachedDisks = New-Object System.Data.DataTable
        $sqlAdapter.Fill($unattachedDisks) | Out-Null            
        $connectionSuccess = $true
    }
    catch {
        Write-Output "Failed to contact SQL at try $tries."
        Write-Output $Error[0]
        Start-Sleep -Seconds ($tries * 20)
    }    
} while (-not($connectionSuccess) -and $tries -lt 3)

if (-not($connectionSuccess))
{
    throw "Could not establish connection to SQL."
}

Write-Output "Found $($unattachedDisks.Rows.Count) remediation opportunities."

$Conn.Close()    
$Conn.Dispose()            

$logEntries = @()

$datetime = (get-date).ToUniversalTime()
$hour = $datetime.Hour
$min = $datetime.Minute
$timestamp = $datetime.ToString("yyyy-MM-ddT$($hour):$($min):00.000Z")

$ctx = Get-AzContext

foreach ($disk in $unattachedDisks.Rows)
{
    $isEligible = $false
    $logDetails = $null
    if ([string]::IsNullOrEmpty($tagsFilter))
    {
        $isEligible = $true
    }
    else
    {
        $diskTags = Get-AzTag -ResourceId $disk.InstanceId -ErrorAction SilentlyContinue
        if ($diskTags)
        {
            foreach ($tagFilter in $tagsFilter)
            {
                if ($diskTags.Properties.TagsProperty.($tagFilter.tagName) -eq $tagFilter.tagValue)
                {
                    $isEligible = $true
                }
                else
                {
                    $isEligible = $false
                    break
                }
            }
        }
    }

    $subscriptionId = $disk.InstanceId.Split("/")[2]
    $resourceGroup = $disk.InstanceId.Split("/")[4]
    $instanceName = $disk.InstanceId.Split("/")[8]
    
    if ($isEligible)
    {
        $diskState = "Unknown"
        $currentSku = "Unknown"

        Write-Output "Performing $remediationAction action (SIMULATE=$Simulate) on $($disk.InstanceId) disk..."
        if ($ctx.Environment.Name -eq $disk.Cloud -and $ctx.Tenant.Id -eq $disk.TenantGuid)
        {
            if ($ctx.Subscription.Id -ne $subscriptionId)
            {
                Select-AzSubscription -SubscriptionId $subscriptionId | Out-Null
                $ctx = Get-AzContext
            }
            $diskObj = Get-AzDisk -ResourceGroupName $resourceGroup -DiskName $instanceName -ErrorAction SilentlyContinue
            if (-not($diskObj.ManagedBy))
            {
                $diskState = "Unattached"
                $currentSku = $diskObj.Sku.Name
                if ($remediationAction -eq "Downsize")
                {
                    if (-not($Simulate) -and $diskObj.Sku.Name -ne 'Standard_LRS')
                    {
                        $diskObj.Sku = [Microsoft.Azure.Management.Compute.Models.DiskSku]::new('Standard_LRS')
                        $diskObj | Update-AzDisk | Out-Null
                    }
                    else
                    {
                        Write-Output "Skipping as disk is already HDD."                        
                    }
                }
                elseif ($remediationAction -eq "Delete")
                {
                    if (-not($Simulate))
                    {
                        Remove-AzDisk -ResourceGroupName $resourceGroup -DiskName $instanceName -Force | Out-Null
                    }
                }
                else
                {
                    Write-Output "Skipping as action is not supported."
                }
            }
            else
            {
                if ($diskObj)
                {
                    Write-Output "Skipping as disk is not unattached."    
                    $diskState = "Attached"    
                }
                else
                {
                    Write-Output "Skipping as disk was already removed."    
                    $diskState = "Removed"                        
                }
            }
        }
        else
        {
            Write-Output "Could not apply remediation as disk is in another cloud/tenant."    
        }
    }

    $logDetails = @{
        IsEligible = $isEligible
        RemediationAction = $remediationAction
        DiskState = $diskState
        CurrentSku = $currentSku
    }

    $logentry = New-Object PSObject -Property @{
        Timestamp = $timestamp
        Cloud = $disk.Cloud
        TenantGuid = $disk.TenantGuid
        SubscriptionGuid = $subscriptionId
        ResourceGroupName = $resourceGroup.ToLower()
        InstanceName = $instanceName.ToLower()
        InstanceId = $disk.InstanceId.ToLower()
        Simulate = $Simulate
        LogDetails = $logDetails | ConvertTo-Json
        RecommendationSubTypeId = $recommendationId
    }
    
    $logEntries += $logentry
}
    
$today = $datetime.ToString("yyyyMMdd")
$csvExportPath = "$today-unattacheddisksfiltered.csv"

$logEntries | Export-Csv -Path $csvExportPath -NoTypeInformation

$csvBlobName = $csvExportPath

$csvProperties = @{"ContentType" = "text/csv"};

Set-AzStorageBlobContent -File $csvExportPath -Container $storageAccountSinkContainer -Properties $csvProperties -Blob $csvBlobName -Context $sa.Context -Force
