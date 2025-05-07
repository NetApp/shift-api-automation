$Global:LogFolder = ".\logs\add_site"
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

    $logFile = Join-Path $Global:LogFolder ("create_site_" + (Get-Date -Format 'yyyyMMdd_HHmm') + ".log")
    Add-Content -Path $logFile -Value $logEntry
}

function Log-Info {
    param([string]$Message)
    Write-Log -Level "INFO" -Message $Message
    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [INFO] $Message"
}

function Log-Error {
    param([string]$Message)
    Write-Log -Level "ERROR" -Message $Message
    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [ERROR] $Message"
}

function New-DromSession {
    param (
        [string]$Username,
        [SecureString]$Password,
        [object]$Config
    )
    $baseUri = [Uri]$Config.shift_server_ip
    $builder = New-Object System.UriBuilder($baseUri)
    $builder.Port = 3698
    $builder.Path = "api/tenant/session"
    $url = $builder.Uri.AbsoluteUri
    $headers = @{ "Content-Type" = "application/json" }
    $unsecurePassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password))
    $body = @{ loginId = $Username; password = $unsecurePassword } | ConvertTo-Json
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
        $response = Invoke-RestMethod -Method Post -Uri $url -Headers $headers -Body $body -SkipCertificateCheck
        return $true
    } catch {
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
        [int]$Timeout = 40,
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

try {
    Log-Info "Starting Add Site workflow"

    $configPath = ".\add_site.json"
    if (-Not (Test-Path $configPath)) {
        Log-Error "Configuration file $configPath not found."
        exit 1
    }
    $configData = Get-Content $configPath -Raw | ConvertFrom-Json

    $executions = $configData.executions
    if (-not $executions) {
        Log-Error "No executions found in configuration."
        exit 1
    }

    foreach ($idx in 0..($executions.Count - 1)) {
        $execution = $executions[$idx]
        Log-Info "Starting add site workflow $($idx + 1)"

        $shift_username = $execution.shift_username
        $shift_password = $execution.shift_password

        if (-not $shift_username -or -not $shift_password) {
            Log-Error "Missing credentials for add site index $($idx + 1). Skipping."
            continue
        }

        $securePassword = ConvertTo-SecureString $shift_password -AsPlainText -Force
        $sessionId = New-DromSession -Username $shift_username -Password $securePassword -Config $execution
        if (-not $sessionId) {
            Log-Error "Unable to create session for index $($idx + 1). Skipping."
            continue
        }

        $siteIds = Create-Sites -SessionId $sessionId -Config $execution

        End-DromSession -SessionId $sessionId -Config $execution
    }
}
catch {
    Log-Error "An error occurred during the add site workflow: $_"
}
finally {
    Log-Info "Please check the logs above for the detailed execution information."
}
