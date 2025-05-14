param(
    [Parameter(Mandatory=$true)]
    [string]$InputJson
)
$Global:LogFolder = ".\logs\create_blueprint"
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
    $logFile = Join-Path $Global:LogFolder ("create_blueprint_" + (Get-Date -Format 'yyyyMMdd_HHmm') + ".log")
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
        [Parameter(Mandatory)]
        [PSCredential]$Credential,

        [object]$Config
    )

    $baseUri = [Uri]$Config.shift_server_ip
    $builder = New-Object System.UriBuilder($baseUri)
    $builder.Port = 3698
    $builder.Path = "api/tenant/session"
    $url = $builder.Uri.AbsoluteUri

    $headers = @{ "Content-Type" = "application/json" }

    $username = $Credential.UserName
    $password = $Credential.GetNetworkCredential().Password

    $body = @{ loginId = $username; password = $password } | ConvertTo-Json

    try {
        Log-Info "Creating session for user: $username"
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
        Invoke-RestMethod -Method Post -Uri $url -Headers $headers -Body $body -SkipCertificateCheck | Out-Null
        return $true
    }
    catch {
        Log-Error "Failed to end session $SessionId. Error: $_"
        return $false
    }
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

try {
    $configData = $InputJson | ConvertFrom-Json
    $executions = $configData.executions
    if (-not $executions) { exit 1 }
    for ($idx = 0; $idx -lt $executions.Count; $idx++) {
        $currentConfig = $executions[$idx]
        Log-Info "Starting blueprint creation workflow $($idx + 1)"
        $shift_username = $currentConfig.shift_username
        $shift_password = $currentConfig.shift_password
        if (-not $shift_username -or -not $shift_password) {
            Log-Error "Missing credentials for create blueprint index $($idx + 1). Skipping this create blueprint."
            continue
        }
        $migrationMode = $currentConfig.migration_mode
        if (-not $migrationMode) { $migrationMode = "full" }
        $securePassword = ConvertTo-SecureString $shift_password -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential ($shift_username, $securePassword)
        $sessionId = New-DromSession -Credential $credential -Config $currentConfig
        if (-not $sessionId) {
            Log-Error "Failed to create session for create blueprint index $($idx + 1). Skipping this create blueprint."
            continue
        }
        $blueprintId = Create-Blueprint -SessionId $sessionId -Config $currentConfig
        if ($blueprintId) {
            Log-Info "Successfully processed blueprint creation for create blueprint index $($idx + 1)"
        }
        else {
            Log-Error "Blueprint creation unsuccessful for create blueprint index $($idx + 1)"
        }
        End-DromSession -SessionId $sessionId -Config $currentConfig
    }
}
catch {
    Log-Error "An error occurred during blueprint creation workflows: $_"
}
finally {
    Log-Info "Please find the logs of the execution in the latest file of the logs folder"
}