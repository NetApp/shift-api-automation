$Global:LogFolder = ".\logs\shift_api_automation"
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
    $logFile = Join-Path $Global:LogFolder ("shift_api_automation_" + (Get-Date -Format 'yyyyMMdd_HHmm') + ".log")
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
    $body = @{
        loginId  = $Username
        password = $Password
    } | ConvertTo-Json
    try {
        Log-Info "Creating session for user: $Username"
        $response = Invoke-RestMethod -Method Post -Uri $url -Headers $headers -Body $body -SkipCertificateCheck
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
        "netapp-sie-sessionid" = $SessionId
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

function Add-Site {
    param (
        [string]$SessionId,
        [object]$Config,
        [string]$SiteType 
    )

    Log-Info "Creating $SiteType site using POST api/setup/site API"
    $baseUri = [Uri]$Config.shift_server_ip
    $builder = New-Object System.UriBuilder($baseUri)
    $builder.Port = 3700
    $builder.Path = "api/setup/site"
    $url = $builder.Uri.AbsoluteUri
    $headers = @{
        "Content-Type" = "application/json"
        "netapp-sie-sessionid" = $SessionId
    }

    if ($SiteType -eq "source") {
        $payload = @{
            "name" = $Config.source_site_name
            "connectorId" = "connector_id"
            "sitePurpose" = @{ "_id" = "1" }
            "location" = @{ "_id" = "1" }
            "virtualizationEnvironments" = @(
                @{
                    "provider" = @{ "_id" = "1" }
                    "version" = "7"
                    "credentials" = @{
                        "endPoint" = $Config.vmware_config.endpoint
                        "loginId"  = $Config.vmware_config.username
                        "password" = $Config.vmware_config.password
                        "skipSSLValidation" = $Config.vmware_config.skip_vmware_sll_validation
                    }
                }
            )
            "storageEnvironments" = @(
                @{
                    "provider" = @{ "_id" = "2" }
                    "version" = "9"
                    "credentials" = @{
                        "endPoint" = $Config.ontap_config.endpoint
                        "loginId"  = $Config.ontap_config.username
                        "password" = $Config.ontap_config.password
                        "skipSSLValidation" = $Config.ontap_config.skip_ontap_sll_validation
                    }
                }
            )
            "sddcEnvironments" = @()
            "storageType" = "ontap_nfs"
            "hypervisor" = "vmware"
        }
    }
    elseif ($SiteType -eq "destination") {
        $payload = @{
            "name" = $Config.destination_site_name
            "connectorId" = "connector_id"
            "sitePurpose" = @{ "_id" = "2" }
            "location" = @{ "_id" = "1" }
            "virtualizationEnvironments" = @(
                @{
                    "provider" = @{ "_id" = "3" }
                    "version" = "7"
                    "credentials" = @{
                        "endPoint" = $Config.hyperv_config.endpoint
                        "loginId"  = $Config.hyperv_config.username
                        "password" = $Config.hyperv_config.password
                        "endPointType" = $Config.hyperv_config.endpoint_type
                    }
                }
            )
            "storageEnvironments" = @(
                @{
                    "provider" = @{ "_id" = "2" }
                    "version" = "9"
                    "credentials" = @{
                        "endPoint" = $Config.ontap_config.endpoint
                        "loginId"  = $Config.ontap_config.username
                        "password" = $Config.ontap_config.password
                        "skipSSLValidation" = $Config.ontap_config.skip_ontap_sll_validation
                    }
                }
            )
            "sddcEnvironments" = @()
            "storageType" = "ontap_nfs"
            "hypervisor" = "hyperv"
        }
    }
    else {
        Log-Error "Invalid site type provided: $SiteType"
        return $null
    }

    try {
        $response = Invoke-RestMethod -Method Post -Uri $url -Headers $headers -Body ($payload | ConvertTo-Json -Depth 10) -SkipCertificateCheck
        if ($response._id) {
            Log-Info "$SiteType site created with id: $($response._id)"
            return $response._id
        } else {
            Log-Error "$SiteType site id not created; response did not contain _id property."
            return $false
        }
    } catch {
        Log-Error "$SiteType site creation failed. Error: $_"
        return $false
    }
}

function Get-SiteList {
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
        $response = Invoke-RestMethod -Method Get -Uri $url -Headers $headers -SkipCertificateCheck
        return $response.list
    } catch {
        Log-Error "Failed to get site list. Error: $_"
        return $null
    }
}

function Get-VmwareSiteDetailsById {
    param (
        [string]$SessionId,
        [string]$SiteId,
        [object]$Config
    )
    Log-Info "Getting VMware site details for site id $SiteId"
    $siteList = Get-SiteList -SessionId $SessionId -Config $Config
    if (-not $siteList) { return $false }
    foreach ($site in $siteList) {
        if ($site.hypervisor -eq "vmware" -and $site._id -eq $SiteId) {
            Log-Info "VMware site details found: $(ConvertTo-Json $site -Depth 5)"
            return $site
        }
    }
    Log-Error "VMware site details not found for site id $SiteId"
    return $false
}

function Get-HypervSiteDetailsById {
    param (
        [string]$SessionId,
        [string]$SiteId,
        [object]$Config
    )
    Log-Info "Getting Hyper-V site details for site id $SiteId"
    $siteList = Get-SiteList -SessionId $SessionId -Config $Config
    if (-not $siteList) { return $false }
    foreach ($site in $siteList) {
        if ($site.hypervisor -eq "hyperv" -and $site._id -eq $SiteId) {
            Log-Info "Hyper-V site details found: $(ConvertTo-Json $site -Depth 5)"
            return $site
        }
    }
    Log-Error "Hyper-V site details not found for site id $SiteId"
    return $false
}

function Wait-ForSiteDiscovery {
    param (
        [string]$SessionId,
        [string]$SiteId,
        [object]$Config,
        [int]$Timeout = 20,
        [string]$SiteType = "source"
    )
    Log-Info "Waiting for site discovery to complete for site id $SiteId"
    $expectedStatus = 4
    for ($i = 0; $i -le $Timeout; $i++) {
        if ($SiteType -eq "source") {
            $site = Get-VmwareSiteDetailsById -SessionId $SessionId -SiteId $SiteId -Config $Config
        } else {
            $site = Get-HypervSiteDetailsById -SessionId $SessionId -SiteId $SiteId -Config $Config
        }
        if ($site -and $site.discoveryStatuses) {
            foreach ($status in $site.discoveryStatuses) {
                if ($status.status -eq $expectedStatus) {
                    Log-Info "Site discovery completed for site id $SiteId"
                    return $true
                }
            }
        }
        Start-Sleep -Seconds 1
    }
    Log-Error "Site discovery did not complete within $Timeout seconds for site id $SiteId"
    return $false
}

function Create-Sites {
    param (
        [string]$SessionId,
        [object]$Config
    )
    $sourceSiteId = $null
    $destinationSiteId = $null

    $sourceSiteId = Add-Site -SessionId $SessionId -Config $Config -SiteType "source"
    if (-not $sourceSiteId) {
        Log-Error "Source site creation failed."
    }
    else {
        $vmwareDetails = Get-VmwareSiteDetailsById -SessionId $SessionId -SiteId $sourceSiteId -Config $Config
        if (-not $vmwareDetails) {
            Log-Error "Source site details not present."
        }
        $discoveryStatus = Wait-ForSiteDiscovery -SessionId $SessionId -SiteId $sourceSiteId -Config $Config -SiteType "source"
        if (-not $discoveryStatus) {
            Log-Error "Source site discovery did not complete successfully."
        }
    }

    $destinationSiteId = Add-Site -SessionId $SessionId -Config $Config -SiteType "destination"
    if (-not $destinationSiteId) {
        Log-Error "Destination site creation failed."
    }
    else {
        $hypervDetails = Get-HypervSiteDetailsById -SessionId $SessionId -SiteId $destinationSiteId -Config $Config
        if (-not $hypervDetails) {
            Log-Error "Destination site details not found."
        }
        $discoveryStatus = Wait-ForSiteDiscovery -SessionId $SessionId -SiteId $destinationSiteId -Config $Config -SiteType "destination"
        if (-not $discoveryStatus) {
            Log-Error "Destination site discovery did not complete successfully."
        }
    }
    return @{ source = $sourceSiteId; destination = $destinationSiteId }
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
        $response = Invoke-RestMethod -Method Get -Uri $url -Headers $headers -SkipCertificateCheck
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
        $response = Invoke-RestMethod -Method Get -Uri $url -Headers $headers -SkipCertificateCheck
        return $response.list
    }
    catch {
        Log-Error "Error fetching unprotected VMs list: $_"
        return $null
    }
}

function Create-ResourceGroup {
    param(
        [string]$SessionId,
        [string]$SourceSiteId,
        [string]$DestinationSiteId,
        [object]$ConfigEntry
    )

    $shiftServerIp = $ConfigEntry.shift_server_ip
    $sourceSiteId = $SourceSiteId
    $destinationSiteId = $DestinationSiteId
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
            $response = Invoke-RestMethod -Method Post -Uri $url -Headers $headers -Body ($payload | ConvertTo-Json -Depth 5) -SkipCertificateCheck
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


function Get-Blueprint {
    param (
         [string]$SessionId,
         [object]$Config
    )
    $baseUri = [Uri]$Config.shift_server_ip
    $builder = New-Object System.UriBuilder($baseUri)
    $builder.Port = 3700
    $builder.Path = "api/setup/drplan"
    $url = $builder.Uri.AbsoluteUri
    $headers = @{
         "Content-Type"="application/json"
         "netapp-sie-sessionid"=$SessionId
    }
    try {
         $response = Invoke-RestMethod -Method Get -Uri $url -Headers $headers -SkipCertificateCheck
         return $response
    }
    catch {
         Log-Error "Failed to get blueprint details. Error: $_"
         return $null
    }
}

function Get-BlueprintById {
    param (
         [string]$SessionId,
         [string]$BlueprintId,
         [object]$Config
    )
    Log-Info "Retrieving blueprint using GET /api/setup/drplan by id $BlueprintId"
    $response = Get-Blueprint -SessionId $SessionId -Config $Config
    if (-not $response -or -not $response.list) {
        Log-Error "No blueprint data returned."
        return $null
    }
    foreach ($blueprint in $response.list) {
        if ($blueprint._id -eq $BlueprintId) {
            Log-Info "Retrieved blueprint by id $BlueprintId is $(ConvertTo-Json $blueprint -Depth 5)"
            return $blueprint
        }
    }
    Log-Error "Retrieved blueprint by id $BlueprintId is not found"
    return $null
}

function Get-Site {
    param(
         [string]$SessionId,
         [object]$Config
    )
    $baseUri = [Uri]$Config.shift_server_ip
    $builder = New-Object System.UriBuilder($baseUri)
    $builder.Port = 3700
    $builder.Path = "api/setup/site"
    $url = $builder.Uri.AbsoluteUri
    $headers = @{
         "Content-Type"="application/json"
         "netapp-sie-sessionid"=$SessionId
    }
    try {
         $response = Invoke-RestMethod -Method Get -Uri $url -Headers $headers -SkipCertificateCheck
         return $response
    }
    catch {
         Log-Error "Failed to get site information. Error: $_"
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
    $siteData = Get-Site -SessionId $SessionId -Config $Config
    if (-not $siteData -or -not $siteData.list) {
         Log-Error "No site information available."
         return $null
    }
    foreach ($site in $siteData.list) {
         if ($site.name -eq $SiteName) {
              Log-Info "Site details for $SiteName are $(ConvertTo-Json $site -Depth 5)"
              return $site
         }
    }
    Log-Error "Site details for $SiteName are not found"
    return $null
}

function Get-SiteUsingSiteId {
    param(
         [string]$SessionId,
         [string]$SiteId,
         [object]$Config
    )
    Log-Info "Getting vmware site virtual environment details using GET /api/setup/site/$SiteId API for $SiteId"
    $baseUri = [Uri]$Config.shift_server_ip
    $builder = New-Object System.UriBuilder($baseUri)
    $builder.Port = 3700
    $builder.Path = "api/setup/site/$SiteId"
    $url = $builder.Uri.AbsoluteUri
    $headers = @{
         "Content-Type"="application/json"
         "netapp-sie-sessionid"=$SessionId
    }
    try {
         $response = Invoke-RestMethod -Method Get -Uri $url -Headers $headers -SkipCertificateCheck
         Log-Info "VMware site virtual environment details are $(ConvertTo-Json $response -Depth 5) for site id $SiteId"
         return $response
    }
    catch {
         Log-Error "VMware site virtual environment details not created for site id $SiteId. Error: $_"
         return $null
    }
}

function Get-VMwareVirtualDetailsUsingSiteId {
    param(
         [string]$SessionId,
         [string]$SiteId,
         [object]$Config
    )
    Log-Info "Getting vmware site virtual environment details using GET /api/setup/site API for $SiteId"
    $siteDetails = Get-SiteUsingSiteId -SessionId $SessionId -SiteId $SiteId -Config $Config
    if (-not $siteDetails) {
         Log-Error "VMware site virtual environment details not created for site id $SiteId"
         return $null
    }
    else {
         if ($siteDetails.virtualizationEnvironments -and $siteDetails.virtualizationEnvironments.Count -gt 0) {
             Log-Info "VMware site virtual environment details created for site id $SiteId"
             return $siteDetails.virtualizationEnvironments[0]._id
         }
         else {
             Log-Error "No virtualization environments found for site id $SiteId"
             return $null
         }
    }
}

function Get-AllResourceGroups {
    param(
         [string]$SessionId,
         [object]$Config
    )
    $baseUri = [Uri]$Config.shift_server_ip
    $builder = New-Object System.UriBuilder($baseUri)
    $builder.Port = 3700
    $builder.Path = "api/setup/protectionGroup"
    $url = $builder.Uri.AbsoluteUri
    $headers = @{
         "Content-Type" = "application/json"
         "netapp-sie-sessionid" = $SessionId
    }
    try {
         $response = Invoke-RestMethod -Method Get -Uri $url -Headers $headers -SkipCertificateCheck
         return $response
    }
    catch {
         Log-Error "Failed to get resource groups. Error: $_"
         return $null
    }
}

function Get-ResourceGroupDetailsByName {
    param(
         [string]$SessionId,
         [string]$ResourceGroupName,
         [object]$Config
    )
    Log-Info "Getting resource group details using GET /api/setup/protectionGroup API for $ResourceGroupName"
    $rgResponse = Get-AllResourceGroups -SessionId $SessionId -Config $Config
    if (-not $rgResponse -or -not $rgResponse.list) {
         Log-Error "No resource groups available."
         return @()
    }
    $matchingGroups = @()
    foreach ($rg in $rgResponse.list) {
         if ($rg.name -eq $ResourceGroupName) {
             $matchingGroups += $rg
         }
    }
    if ($matchingGroups.Count -gt 0) {
         Log-Info "Found resource group details for $ResourceGroupName : $(ConvertTo-Json $matchingGroups -Depth 5)"
         return $matchingGroups
    }
    else {
         Log-Error "Resource group details for $ResourceGroupName not found"
         return @()
    }
}

function Get-ResourcesBySiteVirtenvId {
    param(
         [string]$SessionId,
         [string]$SiteId,
         [string]$VirtEnvId,
         [object]$Config
    )
    $baseUri = [Uri]$Config.shift_server_ip
    $builder = New-Object System.UriBuilder($baseUri)
    $builder.Port = 3700
    $builder.Path = "api/setup/site/${SiteId}/virtEnv/${VirtEnvId}/resource"
    $url = $builder.Uri.AbsoluteUri
    $headers = @{
         "Content-Type" = "application/json"
         "netapp-sie-sessionid" = $SessionId
    }
    try {
         $response = Invoke-RestMethod -Method Get -Uri $url -Headers $headers -SkipCertificateCheck
         return $response.list
    }
    catch {
         Log-Error "Failed to get resources. Error: $_"
         return @()
    }
}

function Create-Blueprint {
    param(
         [string]$SessionId,
         [object]$Config
    )
    Log-Info "Creating DRplan using POST /api/setup/drplan API for data"
    $baseUri = [Uri]$Config.shift_server_ip
    $builder = New-Object System.UriBuilder($baseUri)
    $builder.Port = 3700
    $builder.Path = "api/setup/drplan"
    $url = $builder.Uri.AbsoluteUri
    $headers = @{
         "Content-Type"="application/json"
         "netapp-sie-sessionid"=$SessionId
    }
    $sourceSite = Get-SiteDetailsByName -SessionId $SessionId -SiteName $Config.source_site_name -Config $Config
    if (-not $sourceSite) { Log-Error "Source site not found"; return $null }
    $targetSite = Get-SiteDetailsByName -SessionId $SessionId -SiteName $Config.destination_site_name -Config $Config
    if (-not $targetSite) { Log-Error "Target site not found"; return $null }
    $sourceVirtEnv = Get-VMwareVirtualDetailsUsingSiteId -SessionId $SessionId -SiteId $sourceSite._id -Config $Config
    $targetVirtEnv = Get-VMwareVirtualDetailsUsingSiteId -SessionId $SessionId -SiteId $targetSite._id -Config $Config
    $uniqueRGNames = $Config.vm_details | Where-Object { $_.resource_group_name } | Select-Object -ExpandProperty resource_group_name -Unique
    $resourceGroupList = @()
    foreach ($rgName in $uniqueRGNames) {
         $rgDetails = Get-ResourceGroupDetailsByName -SessionId $SessionId -ResourceGroupName $rgName -Config $Config
         if ($rgDetails) { $resourceGroupList += $rgDetails }
    }
    $rg_list = @()
    foreach ($rg in $resourceGroupList) {
         $rg_list += @{ _id = $rg._id }
    }
    $rg_to_boot_order = @{}
    foreach ($vm_detail in $Config.vm_details) {
         $rgName = $vm_detail.resource_group_name
         if ($rgName -and -not $rg_to_boot_order.ContainsKey($rgName)) {
             $rg_to_boot_order[$rgName] = $vm_detail.boot_order
         }
    }
    $bootList = @()
    foreach ($rg in $resourceGroupList) {
         $order = $rg_to_boot_order[$rg.name]
         if (-not $order) { $order = $Config.vm_details[0].boot_order }
         $bootList += @{ protectionGroup = @{ _id = $rg._id }; order = $order }
    }
    $vm_boot_order_map = @{}
    foreach ($vm_detail in $Config.vm_details) {
         $vm_boot_order_map[$vm_detail.name] = $vm_detail.boot_order
    }
    $vms_payload_list = @()
    $vm_name_to_id = @{}
    foreach ($rg in $resourceGroupList) {
         if ($rg.vms) {
             foreach ($vm in $rg.vms) {
                 $vm_name_to_id[$vm.name] = $vm._id
                 $order = $vm_boot_order_map[$vm.name]
                 if (-not $order) { $order = 0 }
                 $vms_payload_list += @{ vm = @{ _id = $vm._id }; order = $order }
             }
         }
    }
    Log-Info "vm_name_to_id: ${vm_name_to_id}"
    foreach ($i in 0..($Config.vm_details.Count - 1)) {
        if ($null -eq $Config.vm_details[$i]) {
            Log-Error "vm_details index $i is null."
            exit 1
        }

        if (-not $Config.vm_details[$i].PSObject.Properties.Match("_id")) {
            $vmName = $Config.vm_details[$i].name
            if ($vm_name_to_id.ContainsKey($vmName)) {
                $Config.vm_details[$i] | Add-Member -MemberType NoteProperty -Name _id -Value ($vm_name_to_id[$vmName].ToString()) -Force
            }
            else {
                Log-Error "VM id not found for VM name $vmName. Please check that the resource group was created correctly."
                exit 1
            }
        }
        else {
            if ($null -ne $Config.vm_details[$i]._id) {
                $Config.vm_details[$i]._id = $Config.vm_details[$i]._id.ToString()
            }
            else {
                $vmName = $Config.vm_details[$i].name
                if ($vm_name_to_id.ContainsKey($vmName)) {
                    $Config.vm_details[$i] | Add-Member -MemberType NoteProperty -Name _id -Value ($vm_name_to_id[$vmName].ToString()) -Force
                }
                else {
                    Log-Error "VM id not found for VM name $vmName. Please check that the resource group was created correctly."
                    exit 1
                }
            }
        }
    }
    $sourceResources = Get-ResourcesBySiteVirtenvId -SessionId $SessionId -SiteId $sourceSite._id -VirtEnvId $sourceVirtEnv -Config $Config | Where-Object { -not ($_.providerParams.type -eq "STANDARD_PORTGROUP") }
    $targetResources = Get-ResourcesBySiteVirtenvId -SessionId $SessionId -SiteId $targetSite._id -VirtEnvId $targetVirtEnv -Config $Config
    $combinedResources = @($sourceResources + $targetResources)
    $vmSettings = @()
    foreach ($vm_detail in $Config.vm_details) {
         $vm_network_data = $vm_detail.networkDetails
         $network_list = @()
         foreach ($resource in $combinedResources) {
             if ($vm_network_data -contains $resource.name -and $resource.providerParams.type -eq "DISTRIBUTED_PORTGROUP") {
                 $network_list += @{ uuid = $resource.uuid; name = $resource.name; portGroupType = $resource.providerParams.type }
             }
         }
         Log-Info "vm_detail: $vm_detail"
         $vm_setting = @{
             vm = @{ _id = $vm_detail._id }
             name = $vm_detail.name
             numCPUs = $vm_detail.numCPUs
             memoryMB = $vm_detail.memoryMB
             ip = $vm_detail.ip
             vmGeneration = $vm_detail.vmGeneration
             nicIp = @()
             isSecureBootEnable = $vm_detail.isSecureBootEnable
             retainMacAddress = $vm_detail.retainMacAddress
             networkDetails = $network_list
             networkName = $vm_network_data
             order = $vm_detail.boot_order
             ipAllocType = $vm_detail.ipAllocType
             powerOnFlag = $vm_detail.powerOnFlag
         }
         if ($vm_detail.serviceAccountOverrideFlag) {
             $vm_setting.serviceAccountOverrideFlag = $vm_detail.serviceAccountOverrideFlag
             $vm_setting.serviceAccount = @{
                 loginId = $vm_detail.serviceAccount.loginId
                 password = $vm_detail.serviceAccount.password
             }
         }
         $vmSettings += $vm_setting
    }
    $mappings = @()
    if ($Config.mappings) {
        foreach ($prop in $Config.mappings.PSObject.Properties) {
            $sourceKey = $prop.Name
            $targetVal = $prop.Value
            $mapping = @{
                sourceResource = @{ _id = ($combinedResources | Where-Object { $_.name -eq $sourceKey })._id }
                targetResource = @{ _id = ($combinedResources | Where-Object { $_.name -eq $targetVal })._id }
            }
            $mappings += $mapping
        }
    }
    $blueprintPayload = @{
         name = $Config.blueprint_name
         sourceSite = @{ _id = $sourceSite._id }
         sourceVirtEnv = @{ _id = $sourceVirtEnv }
         targetSite = @{ _id = $targetSite._id }
         targetVirtEnv = @{ _id = $targetVirtEnv }
         rpoSeconds = 0
         rtoSeconds = 0
         protectionGroups = $rg_list
         bootOrder = @{
             protectionGroups = $bootList
             vms = $vms_payload_list
         }
         vmSettings = $vmSettings
         mappings = $mappings
         ipConfig = @{ type = $Config.ip_type; targetNetworks = @() }
         serviceAccounts = @(
              @{ os = "windows"; loginId = $Config.windows_loginId; password = $Config.windows_password },
              @{ os = "linux"; loginId = $Config.linux_loginId; password = $Config.linux_password }
         )
    }
    $body = $blueprintPayload | ConvertTo-Json -Depth 10
    try {
         $response = Invoke-RestMethod -Method Post -Uri $url -Headers $headers -Body $body -SkipCertificateCheck
         if ($response._id) {
             Log-Info "Blueprint id created is $($response._id)"
             return $response._id
         }
         else {
             Log-Error "Failed to create blueprint. Response: $(ConvertTo-Json $response)"
             return $null
         }
    }
    catch {
         Log-Error "Failed to create blueprint, Error: $_"
         return $null
    }
}

function Run-ComplianceCheck {
    param(
        [string]$SessionId,
        [string]$ShiftServerIp,
        [string]$BlueprintId
    )

    Start-Sleep -Seconds 20

    try {
        $baseUri = [Uri]$ShiftServerIp
        $builder = New-Object System.UriBuilder($baseUri)
        $builder.Port = 3700
        $builder.Path = "api/setup/compliance/drplan/$BlueprintId/checkrequest"
        $builder.Query = "async=true"
        $url = $builder.Uri.AbsoluteUri

        $headers = @{
            "Content-Type"         = "application/json"
            "netapp-sie-sessionid" = $SessionId
        }

        Log-Info "Executing compliance check for blueprint id $BlueprintId at $url"
        $response = Invoke-RestMethod -Method Post -Uri $url -Headers $headers -TimeoutSec 300 -SkipCertificateCheck

        $compliance_status = $response.status
        $compliance_task_id = $response.taskId

        if (-not $compliance_task_id) {
            Log-Error "Compliance check request for blueprint $BlueprintId failed using POST $url"
            return $null
        }
        else {
            Log-Info "Compliance check initiated with task id: $compliance_task_id"
        }
    }
    catch {
        Log-Error "Failed to execute compliance check for blueprint $BlueprintId. Error: $_"
        return $null
    }

    $timeout = 12
    $compliance_result = $null
    for ($i = 0; $i -lt $timeout; $i++) {
        try {
            $baseUri = [Uri]$ShiftServerIp
            $builder = New-Object System.UriBuilder($baseUri)
            $builder.Port = 3700
            $builder.Path = "api/setup/compliance/drplan/$compliance_task_id/checkrequest"
            $builder.Query = "taskId=$compliance_task_id"
            $statusUrl = $builder.Uri.AbsoluteUri

            Log-Info "Checking compliance status for task id $compliance_task_id at $statusUrl (Attempt $($i + 1))"
            $statusResponse = Invoke-RestMethod -Method Post -Uri $statusUrl -Headers $headers -TimeoutSec 300 -SkipCertificateCheck
            $current_status = $statusResponse.status
            $compliance_result = $statusResponse.result

            if ($current_status -eq "succeeded") {
                Log-Info "Compliance check status is $current_status"
                return $compliance_task_id
            }
            else {
                Log-Info "Compliance check status is $current_status, retrying after 5 seconds"
            }
        }
        catch {
            Log-Error "Failed to check compliance status for task id $compliance_task_id. Error: $_"
        }
        Start-Sleep -Seconds 5
    }

    Log-Error "Timeout occurred while verifying compliance check status after $timeout attempts"
    return $null
}

function Trigger-Migration {
    param(
        [string]$SessionId,
        [string]$BlueprintId,
        [string]$MigrationMode,
        [object]$Config
    )

    if ($MigrationMode -eq "clone_based_migration") {
         $type = "migrate"
    }
    else {
         $type = "convert"
    }

    $baseUri = [Uri]$Config.shift_server_ip
    $builder = New-Object System.UriBuilder($baseUri)
    $builder.Port = 3704
    $builder.Path = "api/recovery/drPlan/$BlueprintId/$type/execution"
    $url = $builder.Uri.AbsoluteUri

    $headers = @{
         "Content-Type" = "application/json"
         "netapp-sie-sessionid" = $SessionId
    }

    $body = @{
         "serviceAccounts" = @{
              "common" = @{
                   "loginId" = $null
                   "password" = $null
              }
              "vms" = @()
         }
    } | ConvertTo-Json

    try {
         Log-Info "Executing blueprint id $BlueprintId with mode $MigrationMode using URL $url"
         $response = Invoke-RestMethod -Method Post -Uri $url -Headers $headers -Body $body -ErrorAction Stop -SkipCertificateCheck
         if ($response._id) { 
              Log-Info "Blueprint $BlueprintId executed with mode $MigrationMode successfully with id $($response._id)."
              return $response._id
         }
         else {
              Log-Error "Blueprint execution did not return an execution id."
              return $false
         }
    }
    catch {
         Log-Error "Failed to execute blueprint $BlueprintId with mode $MigrationMode. Error: $_"
         return $false
    }
}

function Trigger-Migration-Workflow {
    param (
        [object]$MigrationConfig,
        [int]$Index,
        [string]$BlueprintId
    )

    Log-Info "Starting trigger migration workflow $($Index + 1)"
    $shift_username = $MigrationConfig.shift_username
    $shift_password = $MigrationConfig.shift_password
    $blueprint_id = $BlueprintId
    $migration_mode = $MigrationConfig.migration_mode

    if (-not $shift_username -or -not $shift_password -or -not $blueprint_id) {
        Log-Error "Missing required details for migration index $($Index + 1). Skipping this migration."
        return
    }

    $sessionId = New-DromSession -Username $shift_username -Password $shift_password -Config $MigrationConfig
    if (-not $sessionId) {
        Log-Error "Failed to create session for migration index $($Index + 1). Skipping this migration."
        return
    }

    $executionId = Trigger-Migration -SessionId $sessionId -BlueprintId $blueprint_id -MigrationMode $migration_mode -Config $MigrationConfig
    if ($executionId) {
        Log-Info "Migration index $($Index + 1) executed successfully; Execution ID: $executionId"
        return $executionId
    }
    else {
        Log-Error "Migration index $($Index + 1) execution failed."
    }

    $endSession = End-DromSession -SessionId $sessionId -Config $MigrationConfig
    if (-not $endSession) {
         Log-Error "Could not properly end session for migration index $($Index + 1)."
    }
}

function Get-BlueprintStatus {
    param(
        [string]$SessionId,
        [object]$Config
    )
    $baseUri = [Uri]$Config.shift_server_ip
    $builder = New-Object System.UriBuilder($baseUri)
    $builder.Port = 3704
    $builder.Path = "api/recovery/drplan/status"
    $url = $builder.Uri.AbsoluteUri

    $headers = @{
        "Content-Type" = "application/json"
        "netapp-sie-sessionid" = $SessionId
    }

    try {
        Log-Info "Retrieving blueprint status via GET $url"
        $response = Invoke-RestMethod -Method GET -Uri $url -Headers $headers -SkipCertificateCheck
        Log-Info "Blueprint status successfully retrieved."
        return $response
    }
    catch {
        Log-Error "Error occurred while retrieving blueprint status: $_"
        return $null
    }
}

function Verify-BlueprintStatus {
    param(
        [string]$SessionId,
        [string]$BlueprintId,
        [object]$Config,
        [int]$Timeout = 40
    )
    Log-Info "Check blueprint status for id $BlueprintId with timeout $Timeout seconds"
    for ($i = 0; $i -lt $Timeout; $i++) {
        $blueprintStatus = Get-BlueprintStatus -SessionId $SessionId -Config $Config
        if ($blueprintStatus) {
            foreach ($blueprint in $blueprintStatus) {
                if ($blueprint.drPlan._id -eq $BlueprintId) {
                    $status = $blueprint.drPlan.recoveryStatus
                    if ($status -match "complete" -or $status -match "error") {
                        Log-Info "Blueprint status for blueprint id $BlueprintId is $status"
                        return $status
                    }
                }
            }
            Log-Info "Verifying blueprint status for blueprint id $BlueprintId : Current status is $status"
        }
        Start-Sleep -Seconds 30
    }
    Log-Error "Timeout occurred while verifying blueprint status for blueprint id $BlueprintId"
    return $null
}

function Get-JobSteps {
    param(
        [string]$SessionId,
        [string]$ExecutionId,
        [object]$Config
    )
    $baseUri = [Uri]$Config.shift_server_ip
    $builder = New-Object System.UriBuilder($baseUri)
    $builder.Port = 3704
    $builder.Path = "api/recovery/execution/$ExecutionId/steps"
    $url = $builder.Uri.AbsoluteUri

    $headers = @{
        "Content-Type" = "application/json"
        "netapp-sie-sessionid" = $SessionId
    }

    try {
        Log-Info "Retrieving job steps for execution id $ExecutionId via GET $url"
        $response = Invoke-RestMethod -Method GET -Uri $url -Headers $headers -SkipCertificateCheck
        Log-Info "Job steps successfully retrieved for execution id $ExecutionId"
        Log-Info "Job type for execution id $ExecutionId is $($response.type)"
        Log-Info "Job steps: $($response.steps | Out-String)"
        return $response
    }
    catch {
        Log-Error "Failed to retrieve job steps for execution id $ExecutionId. Error: $_"
        return $null
    }
}

function Validate-JobSteps {
    param(
        [string]$SessionId,
        [string]$ExecutionId,
        [object]$Config
    )
    $jobResponse = Get-JobSteps -SessionId $SessionId -ExecutionId $ExecutionId -Config $Config
    if ($jobResponse) {
        $jobSteps = $jobResponse.steps
        $allSuccessful = $true
        foreach ($step in $jobSteps) {
            if ($step.status -ne 4) {
                Log-Error "Job step $($step.description) is not successful"
                $allSuccessful = $false
            }
            else {
                Log-Info "Job step $($step.description) is successful"
            }
        }
        return $allSuccessful
    }
    else {
        Log-Error "Failed to fetch job steps for execution id $ExecutionId"
        return $false
    }
}

function Check-MigrationStatus {
    param(
        [string]$SessionId,
        [string]$BlueprintId,
        [string]$ExecutionId,
        [object]$Config
    )

    $blueprintStatus = Verify-BlueprintStatus -SessionId $SessionId -BlueprintId $BlueprintId -Config $Config
    if ($blueprintStatus) {
        Log-Info "Final blueprint status for blueprint id $BlueprintId : $blueprintStatus"
    }
    else {
        Log-Error "Could not verify blueprint status for blueprint id $BlueprintId"
    }

    $jobSuccess = Validate-JobSteps -SessionId $SessionId -ExecutionId $ExecutionId -Config $Config
    if ($jobSuccess) {
        Log-Info "Job steps successfully completed for execution id $ExecutionId"
    }
    else {
        Log-Error "Job steps for execution id $ExecutionId did not complete successfully."
    }

    return $blueprintStatus
}

function Get-Blueprint {
    param(
        [string]$SessionId,
        [object]$Config
    )

    $baseUri = [Uri]$Config.shift_server_ip
    $builder = New-Object System.UriBuilder($baseUri)
    $builder.Port = 3700
    $builder.Path = "api/setup/drplan"
    $url = $builder.Uri.AbsoluteUri

    $headers = @{
        "Content-Type" = "application/json"
        "netapp-sie-sessionid" = $SessionId
    }

    try {
        Log-Info "Retrieving blueprint using GET /api/setup/drplan with URL $url"
        $response = Invoke-RestMethod -Method Get -Uri $url -Headers $headers -ErrorAction Stop -SkipCertificateCheck
        if ($response.fetchedCount -ne $null) {
            Log-Info "Retrieved blueprint count is $($response.fetchedCount)"
            return @{ blueprintCount = $response.fetchedCount; blueprintList = $response.list }
        }
        else {
            Log-Error "Blueprint response format is unexpected."
            return $null
        }
    }
    catch {
        Log-Error "Failed to retrieve blueprint, Error: $_"
        return $null
    }
}

function Get-BlueprintIdByName {
    param(
        [string]$SessionId,
        [string]$BlueprintName,
        [object]$Config

    )
    Log-Info "Retrieving blueprint using GET /api/setup/drplan by name $BlueprintName"
    $blueprintResult = Get-Blueprint -SessionId $SessionId -Config $Config
    foreach ($blueprint in $blueprintResult.blueprintList) {
        if ($blueprint.name -eq $BlueprintName) {
            Log-Info "Retrieved blueprint by name $BlueprintName"
            if (-not $blueprint._id) {
                Log-Error "Blueprint '$BlueprintName' was found but its _id property is null."
                return $false
            }
            return $blueprint._id
        }
    }
    Log-Error "Retrieval of blueprint id by name $BlueprintName is not found"
    return $false
}

function Prepare-VM {
    param (
        [string]$SessionId,
        [string]$BlueprintId,
        [object]$Config
    )
    $prepareVmStatus = Wait-ForPrepareVMExecution -Config $Config -SessionId $SessionId -BlueprintId $BlueprintId
    Write-Log "INFO" "Status of Prepare VM is $prepareVmStatus for blueprint $BlueprintId"
    if (-not $prepareVmStatus) {
        Write-Log "ERROR" "Prepare VM for blueprint id $BlueprintId did not complete successfully."
    }
    else {
        Write-Log "INFO" "Prepare VM successfully completed for blueprint id $BlueprintId"
    }
    return $prepareVmStatus
}

function Wait-ForPrepareVMExecution {
    param (
        [object]$Config,
        [string]$SessionId,
        [string]$BlueprintId,
        [int]$Timeout = 1000
    )
    Write-Log "INFO" "Waiting for prepare VM to complete for blueprint id $BlueprintId"

    $expectedStatus = 4
    $failedStatus = 5

    for ($i = 0; $i -le $Timeout; $i++) {
        $blueprintList = Get-BlueprintStatus -SessionId $SessionId -Config $Config
        if ($blueprintList -ne $null) {
            foreach ($prepareItem in $blueprintList) {
                if ($prepareItem.drPlan._id -eq $BlueprintId) {
                    $currentStatus = $prepareItem.lastExecution.status
                    if ($currentStatus -eq $expectedStatus) {
                        Write-Log "INFO" "Status is $expectedStatus. Exiting wait after prepare VM completion."
                        return $true
                    }
                    elseif ($currentStatus -eq $failedStatus) {
                        Write-Log "ERROR" "Status is $failedStatus. Exiting wait after prepare VM failure."
                        return $false
                    }
                }
            }
        }
        Start-Sleep -Seconds 20
    }

    Write-Log "ERROR" "Exceeded timeout of $Timeout seconds. Prepare VM is not completed."
    return $false
}

function Full-MigrationWorkflow {
    param (
        [string]$SessionId,
        [object]$MigrationConfig,
        [int]$Index
    )
    $migration_mode = $MigrationConfig.migration_mode
    Log-Info "Starting execution for: $($MigrationConfig.execution_name)"
    $source_site_id = $null
    $destination_site_id = $null
    $resource_group_ids = $null
    $blueprint_id = $null
    $execution_id = $null
    if (($MigrationConfig.do_create_sites -eq $null) -or ($MigrationConfig.do_create_sites -eq $true)) {
        try {
            $sites = Create-Sites -SessionId $SessionId -Config $MigrationConfig
            $source_site_id = $sites.source
            $destination_site_id = $sites.destination
        }
        catch { Log-Error "Create sites failed: $_" }
    }
    else { Log-Info "Skipping site creation as per configuration." }
    if (($MigrationConfig.do_add_resource_group -eq $null) -or ($MigrationConfig.do_add_resource_group -eq $true)) {
        try {
            if (-not $source_site_id) { 
                $sourceSite = Get-SiteDetailsByName -SessionId $SessionId -SiteName $MigrationConfig.source_site_name -Config $MigrationConfig
                if (-not $sourceSite) { Log-Error "Source site not found" }
                $source_site_id = $sourceSite._id
            }
            if (-not $destination_site_id) { 
                $targetSite = Get-SiteDetailsByName -SessionId $SessionId -SiteName $MigrationConfig.destination_site_name -Config $MigrationConfig
                $destination_site_id = $targetSite._id 
            }
            if ($source_site_id -and $destination_site_id) {
                $resource_group_ids = Create-ResourceGroup -SessionId $SessionId -ConfigEntry $MigrationConfig -SourceSiteId $source_site_id -DestinationSiteId $destination_site_id
            }
            else { Log-Error "No source and destination site IDs available, cannot create resource group" }
        }
        catch { Log-Error "Add resource group failed: $_" }
    }
    else { Log-Info "Skipping resource group creation as per configuration." }
    if (($MigrationConfig.do_create_blueprint -eq $null) -or ($MigrationConfig.do_create_blueprint -eq $true)) {
        try {
            $blueprint_id = Create-Blueprint -SessionId $SessionId -Config $MigrationConfig
        }
        catch {
            Log-Error "Create blueprint failed: $_"
        }
    }
    else { Log-Info "Skipping blueprint creation as per configuration." }
    if (-not $blueprint_id) { 
        $blueprint_name = $MigrationConfig.blueprint_name
        $blueprint_id = Get-BlueprintIdByName -SessionId $SessionId -BlueprintName $blueprint_name -Config $MigrationConfig
    }
    if ($blueprint_id -and ((($MigrationConfig.do_compliance -eq $null) -or ($MigrationConfig.do_compliance -eq $true)))) {
        try {
            if ($blueprint_id) { $complianceTaskId = Run-ComplianceCheck -SessionId $SessionId -ShiftServerIp $MigrationConfig.shift_server_ip -BlueprintId $blueprint_id }
            else { Log-Error "No blueprint id available, cannot check status." }
        }
        catch { Log-Error "Compliance check failed: $_" }
    }
    if ((($MigrationConfig.do_prepare_vm -eq $null) -or ($MigrationConfig.do_prepare_vm -eq $true))) {
        try {
            if ($blueprint_id) { $execution_id = Prepare-VM -SessionId $SessionId -BlueprintId $blueprint_id -Config $MigrationConfig}
            else { Log-Error "No blueprint id available, cannot trigger migration." }
        }
        catch { Log-Error "Trigger migration failed: $_" }
    }
    else { Log-Info "Skipping migration trigger as per configuration." }
    if ((($MigrationConfig.do_trigger_migration -eq $null) -or ($MigrationConfig.do_trigger_migration -eq $true))) {
        try {
            if ($blueprint_id) { $execution_id = Trigger-Migration-Workflow -MigrationConfig $MigrationConfig -Index $Index -BlueprintId $blueprint_id}
            else { Log-Error "No blueprint id available, cannot trigger migration." }
        }
        catch { Log-Error "Trigger migration failed: $_" }
    }
    else { Log-Info "Skipping migration trigger as per configuration." }
    if ((($MigrationConfig.do_check_status -eq $null) -or ($MigrationConfig.do_check_status -eq $true))) {
        try {
            if ($blueprint_id) {
                if (-not $executionId) { 
                    $executionId = $MigrationConfig.execution_id
                    if ($executionId) {
                        $status = Check-MigrationStatus -SessionId $SessionId -BlueprintId $blueprint_id -ExecutionId $executionId -Config $MigrationConfig
                        Log-Info "Final migration status for index $executionIndex : $status"
                    }
                    else{
                        Log-Error "Execution id not found. Cannot check migration status" 
                    }
                }
                else{
                    Log-Error "Execution id not found." 
                }
                
            }
            else { Log-Info "No blueprint id and execution id available, skipping migration status check." }
        }
        catch { Log-Error "Check migration status failed: $_" }
    }
    else { Log-Info "Skipping status check as per configuration." }
}


$configPath = ".\shift_api_automation.json"
if (-not (Test-Path $configPath)) { 
    Log-Error "Configuration file $configPath not found."
    exit 1 
    }
$configData = Get-Content $configPath -Raw | ConvertFrom-Json
$executions = $configData.executions
if (-not $executions) { 
    Log-Error "No Execution details found in input file"
    exit 1 
    }
foreach ($idx in (0..($executions.Count - 1))) {
    $migrationConfig = $executions[$idx]
    Log-Info "Starting workflow $($idx + 1)"
    $shift_username = $migrationConfig.shift_username
    $shift_password = $migrationConfig.shift_password
    if (-not $shift_username -or -not $shift_password) {
        Log-Error "Missing credentials for migration index $($idx + 1). Skipping this migration."
        continue
    }
    $session_id = New-DromSession -Username $shift_username -Password $shift_password -Config $migrationConfig
    if (-not $session_id) {
        Log-Error "Failed to create session for migration index $($idx + 1). Skipping this migration."
        continue
    }
    Full-MigrationWorkflow -SessionId $session_id -MigrationConfig $migrationConfig -Index $idx
    End-DromSession -SessionId $session_id -Config $migrationConfig
}
Log-Info "Please find the logs of the execution in the latest file of the logs folder"