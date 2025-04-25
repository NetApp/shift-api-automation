$Global:LogFolder = ".\logs\add_resource_group"
if (-not (Test-Path $Global:LogFolder)) {
    New-Item -ItemType Directory -Path $Global:LogFolder | Out-Null
}

function Write-Log {
    param(
        [string]$Level,
        [string]$Message
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logEntry = "$timestamp [$Level] $Message"
    Write-Host $logEntry

    $logFile = Join-Path $Global:LogFolder ("create_resource_group_" + (Get-Date -Format 'yyyyMMdd_HHmm') + ".log")
    Add-Content -Path $logFile -Value $logEntry
}

function Log-Info {
    param ([string]$Message)
    Write-Log -Level "INFO" -Message $Message
}

function Log-Error {
    param ([string]$Message)
    Write-Log -Level "ERROR" -Message $Message
}

function Get-VMwareVirtEnv {
    param (
        [string]$SessionId,
        [string]$SiteId,
        [string]$ShiftServerIp
    )
    $builder = New-Object System.UriBuilder($ShiftServerIp)
    $builder.Port = 3700
    $builder.Path = "api/setup/site/$SiteId"
    $url = $builder.Uri.AbsoluteUri
    $headers = @{
        "Content-Type"          = "application/json"
        "netapp-sie-sessionid"  = $SessionId
    }
    try {
        Log-Info "Getting VMware virtual environment details for site $SiteId from $url"
        $response = Invoke-RestMethod -Method Get -Uri $url -Headers $headers
        if ($response.virtualizationEnvironments -and $response.virtualizationEnvironments.Count -gt 0) {
            Log-Info "Retrieved virtualization environment for site $SiteId : $($response.virtualizationEnvironments[0]._id)"
            return $response.virtualizationEnvironments[0]._id
        }
        else {
            Log-Error "No virtualization environments found for site $SiteId"
            return $null
        }
    }
    catch {
        Log-Error "Error getting virtualization environment for site $SiteId : $_"
        return $null
    }
}

function Get-UnprotectedVMList {
    param(
        [string]$SessionId,
        [string]$SourceSiteId,
        [string]$SourceVirtEnv,
        [string]$ShiftServerIp
    )
    $builder = New-Object System.UriBuilder($ShiftServerIp)
    $builder.Port = 3700
    $builder.Path = "api/setup/vm/unprotected"
    $builder.Query = "siteId=$SourceSiteId&virtEnvId=$SourceVirtEnv"
    $url = $builder.Uri.AbsoluteUri

    $headers = @{
        "Content-Type" = "application/json"
        "netapp-sie-sessionid"  = $SessionId
    }
    try {
        Log-Info "Fetching unprotected VMs list from $url"
        $response = Invoke-RestMethod -Method Get -Uri $url -Headers $headers
        return $response.list
    }
    catch {
        Log-Error "Error fetching unprotected VMs list: $_"
        return $null
    }
}

function New-DromSession {
    param (
        [string]$Username,
        [string]$Password,
        [object]$Config
    )
    $baseUri = [Uri]$Config.shift_server_ip
    $builder = New-Object System.UriBuilder($baseUri)
    $builder.Port = 3698
    $builder.Path = "api/tenant/session"
    $url = $builder.Uri.AbsoluteUri

    $headers = @{ "Content-Type" = "application/json" }
    $body = @{ loginId = $Username; password = $Password } | ConvertTo-Json

    try {
        Log-Info "Creating session for user: $Username"
        $response = Invoke-RestMethod -Method Post -Uri $url -Headers $headers -Body $body
        if ($response.session -and $response.session._id) {
            return $response.session._id
        }
        else {
            Log-Error "Session creation did not return a valid session id."
            return $null
        }
    }
    catch {
        Log-Error "Session creation failed. Error: $_"
        return $null
    }
}

function End-DromSession {
    param (
        [string]$SessionId,
        [object]$Config
    )
    $baseUri = [Uri]$Config.shift_server_ip
    $builder = New-Object System.UriBuilder($baseUri)
    $builder.Port = 3698
    $builder.Path = "api/tenant/session/end"
    $url = $builder.Uri.AbsoluteUri

    $headers = @{
        "Content-Type" = "application/json"
        "netapp-sie-sessionid"  = $SessionId
    }
    $body = @{ sessionId = "$SessionId" } | ConvertTo-Json

    try {
        Log-Info "Ending session $SessionId"
        Invoke-RestMethod -Method Post -Uri $url -Headers $headers -Body $body | Out-Null
        return $true
    }
    catch {
        Log-Error "Failed to end session $SessionId. Error: $_"
        return $false
    }
}

function Create-ResourceGroup {
    param(
        [string]$SessionId,
        [object]$ConfigEntry,
        [string]$sourceSiteId,
        [string]$destinationSiteId
    )

    $shiftServerIp = $ConfigEntry.shift_server_ip
    $migrationMode = $ConfigEntry.migration_mode

    $sourceVirtEnv = $ConfigEntry.sourceVirtEnv
    $destinationVirtEnv = $ConfigEntry.destinationVirtEnv

    if (-not $sourceVirtEnv) {
        Log-Info "Source virtualization environment not specified. Fetching from API for site $sourceSiteId"
        $sourceVirtEnv = Get-VMwareVirtEnv -SessionId $SessionId -SiteId $sourceSiteId -ShiftServerIp $shiftServerIp
        if (-not $sourceVirtEnv) {
            Log-Error "Could not determine source virtualization environment for site $sourceSiteId"
            return $null
        }
    }
    if (-not $destinationVirtEnv) {
        Log-Info "Destination virtualization environment not specified. Fetching from API for site $destinationSiteId"
        $destinationVirtEnv = Get-VMwareVirtEnv -SessionId $SessionId -SiteId $destinationSiteId -ShiftServerIp $shiftServerIp
        if (-not $destinationVirtEnv) {
            Log-Error "Could not determine destination virtualization environment for site $destinationSiteId"
            return $null
        }
    }

    $vmDetails = $ConfigEntry.vm_details
    if (-not $vmDetails) {
        Log-Error "No vm_details found in configuration."
        return $null
    }

    $unprotectedVMList = Get-UnprotectedVMList -SessionId $SessionId -SourceSiteId $sourceSiteId -SourceVirtEnv $sourceVirtEnv -ShiftServerIp $shiftServerIp
    if (-not $unprotectedVMList) {
        Log-Error "Unable to fetch unprotected VMs for site $sourceSiteId."
        return $null
    }

    $groups = @{}
    foreach ($vm in $vmDetails) {
        $rgName = $vm.resource_group_name
        if (-not $rgName) {
            Log-Error "Missing resource_group_name in vm_details entry."
            return $null
        }
        if (-not $groups.ContainsKey($rgName)) {
            $groups[$rgName] = @()
        }
        $groups[$rgName] += $vm
    }

    $resourceGroupIds = @()

    foreach ($rgName in $groups.Keys) {
        Log-Info "Creating resource group '$rgName' for source site $sourceSiteId and destination site $destinationSiteId"

        $vms = @()
        $bootOrderList = @()
        $bootDelayList = @()
        $datastoreMappingList = @()

        foreach ($vm in $groups[$rgName]) {
            $vmName = $vm.name
            $vmId = $vm.id
            if (-not $vmId) {
                $matchingVM = $unprotectedVMList | Where-Object { $_.name -eq $vmName }
                if ($matchingVM) {
                    $vmId = $matchingVM._id
                    Log-Info "Found VM id for '$vmName': $vmId"
                }
                else {
                    Log-Error "VM id not provided and could not fetch vm id for VM: $vmName"
                    continue
                }
            }

            $vms += @{ _id = $vmId }
            $bootOrderList += @{ vm = @{ _id = $vmId }; order = [int]$vm.boot_order }
            $bootDelayList += @{ vm = @{ _id = $vmId }; delaySecs = [int]$vm.delay }
            $datastoreMappingList += @{
                vm = @{ _id = $vmId }
                datastoreName = $vm.datastore_name
                qtreeName = $vm.qtree_name
                volumeName = $vm.datastore_name
            }
        }

        $baseUri = [Uri]$shiftServerIp
        $builder = New-Object System.UriBuilder($baseUri)
        $builder.Port = 3700
        $builder.Path = "api/setup/protectionGroup"
        $url = $builder.Uri.AbsoluteUri

        $headers = @{
            "Content-Type" = "application/json"
            "netapp-sie-sessionid"  = $SessionId
        }

        $payload = @{
            name = $rgName
            sourceSite = @{ _id = $sourceSiteId }
            sourceVirtEnv = @{ _id = $sourceVirtEnv }
            vms = $vms
            bootOrder = @{ vms = $bootOrderList }
            bootDelay = $bootDelayList
            scripts = @()
            replicationPlan = @{
                targetSite = @{ _id = $destinationSiteId }
                targetVirtEnv = @{ _id = $destinationVirtEnv }
                datastoreQtreeMapping = $datastoreMappingList
                snapshotType = $migrationMode
                frequencyMins = "30"
                retryCount = 3
                numSnapshotsToRetain = 2
            }
            migrationMode = $migrationMode
        }

        try {
            Log-Info "POST $url with payload for resource group '$rgName'"
            $response = Invoke-RestMethod -Method Post -Uri $url -Headers $headers -Body ($payload | ConvertTo-Json -Depth 5)
            if ($response -and $response._id) {
                $rgId = $response._id
                Log-Info "Resource group '$rgName' created with id: $rgId"
                $resourceGroupIds += $rgId
            }
            else {
                Log-Error "Resource group '$rgName' creation failed. Response: $response"
            }
        }
        catch {
            Log-Error "Error creating resource group '$rgName': $_"
        }
    }
    return $resourceGroupIds
}

function Get-Site {
    param (
        [string]$SessionId,
        [object]$Config
    )

    $baseUri = [Uri]$Config.shift_server_ip
    $builder = New-Object System.UriBuilder($baseUri)
    $builder.Port = 3700
    $builder.Path = "api/setup/site"
    $url = $builder.Uri.AbsoluteUri
    $headers = @{
        "Content-Type" = "application/json"
        "netapp-sie-sessionid" = $SessionId
    }

    try {
        Log-Info "Retrieving site list"
        $response = Invoke-RestMethod -Method Get -Uri $url -Headers $headers
        return $response.list
    } catch {
        Log-Error "Failed to get site list. Error: $_"
        return $null
    }
}

function Get-SiteDetailsByName {
    param(
        [string]$SessionId,
        [string]$SiteName,
        [object]$Config
    )
    Log-Info "Getting site details by name using GET /api/setup/site API for $SiteName"
    $siteList = Get-Site -SessionId $SessionId -Config $Config
    if (-not $siteList) {
        Log-Error "No site list returned."
        return $false
    }
    foreach ($site in $siteList) {
        if ($site.name -eq $SiteName) {
            Log-Info "Site details fetched for $SiteName"
            return $site
        }
    }
}

$configPath = ".\add_resource_group.json"
if (-Not (Test-Path $configPath)) {
    Log-Error "Configuration file $configPath not found."
    exit 1
}
try {
    $configData = Get-Content $configPath -Raw | ConvertFrom-Json
}
catch {
    Log-Error "Failed to read configuration file. Error: $_"
    exit 1
}

$executions = $configData.executions
if (-not $executions) {
    Log-Error "No executions defined in the configuration file."
    exit 1
}

foreach ($idx in 0..($executions.Count - 1)) {
    $workflowIndex = $idx + 1
    Log-Info "Starting resource group workflow $workflowIndex"

    $entry = $executions[$idx]
    $shiftUsername = $entry.shift_username
    $shiftPassword = $entry.shift_password
    if (-not $shiftUsername -or -not $shiftPassword) {
        Log-Error "Missing credentials for resource group index $workflowIndex. Skipping this resource group."
        continue
    }


    $sessionId = New-DromSession -Username $shiftUsername -Password $shiftPassword -Config $entry
    if (-not $sessionId) {
        Log-Error "Failed to create session for resource group index $workflowIndex. Skipping this execution."
        continue
    }
    $sourceSiteName = $entry.source_site_name
    $destinationSiteName = $entry.destination_site_name

    $sourceSiteDetails = Get-SiteDetailsByName -SessionId $sessionId -SiteName $sourceSiteName -Config $entry
    $destinationSiteDetails = Get-SiteDetailsByName -SessionId $sessionId -SiteName $destinationSiteName -Config $entry

    if (-not $sourceSiteDetails -or -not $destinationSiteDetails) {
        Log-Error "Error retrieving site details for source or destination."
        continue
    }

    $sourceSiteId = $sourceSiteDetails._id
    $destinationSiteId = $destinationSiteDetails._id
    if (-not $sourceSiteId -or -not $destinationSiteId) {
        Log-Error "Missing site IDs for resource group index $workflowIndex. Skipping this resource group."
        continue
    }
    $resourceGroupIds = Create-ResourceGroup -SessionId $sessionId -ConfigEntry $entry -sourceSiteId $sourceSiteId -destinationSiteId $destinationSiteId
    if ($resourceGroupIds) {
        foreach ($rgId in $resourceGroupIds) {
            Log-Info "Resource group created with id: $rgId"
        }
    }
    else {
        Log-Error "Failed to create any resource group for index $workflowIndex."
    }

    End-DromSession -SessionId $sessionId -Config $entry
}

Log-Info "Please find the logs of the execution in the latest file of the logs folder"