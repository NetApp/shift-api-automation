$Global:LogFolder = ".\logs\get_site"
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

    $logFile = Join-Path $Global:LogFolder ("get_site_" + (Get-Date -Format 'yyyyMMdd_HHmm') + ".log")
    Add-Content -Path $logFile -Value $logEntry
}

function Log-Info {
    param([string]$Message)
    Write-Log -Level "INFO" -Message $Message
}

function Log-Error {
    param([string]$Message)
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
    } catch {
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
        $null = Invoke-RestMethod -Method Post -Uri $url -Headers $headers -Body $body
        return $true
    } catch {
        Log-Error "Failed to end session $SessionId. Error: $_"
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
        Log-Info "Retrieving site list"
        $response = Invoke-RestMethod -Method Get -Uri $url -Headers $headers
        return $response.list
    } catch {
        Log-Error "Failed to get site list. Error: $_"
        return $null
    }
}

try {
    Log-Info "Starting Get Site workflow"

    $configPath = ".\get_site.json"
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

        $sessionId = New-DromSession -Username $shift_username -Password $shift_password -Config $execution
        if (-not $sessionId) {
            Log-Error "Unable to create session for index $($idx + 1). Skipping."
            continue
        }

        $siteList = Get-SiteList -SessionId $sessionId -Config $execution
        if ($siteList) {
            Log-Info "Site list retrieved successfully:"
            Write-Host (ConvertTo-Json $siteList -Depth 5)
        } else {
            Log-Error "No site details retrieved."
        }

        End-DromSession -SessionId $sessionId -Config $execution
    }
}
catch {
    Log-Error "An error occurred during the Get Site workflow: $_"
}
finally {
    Log-Info "Get Site workflow execution completed. Please check the logs above for details."
}