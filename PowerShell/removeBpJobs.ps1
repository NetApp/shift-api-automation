$Global:LogFolder = ".\logs\removeBPJobs"
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
    $logFile = Join-Path $Global:LogFolder ("removeBPJobs_" + (Get-Date -Format 'yyyyMMdd_HHmm') + ".log")
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

        [object]$ShiftServerIP
    )

    $baseUri = [Uri]$ShiftServerIP
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
        throw "Invalid credentials provided."
    }
}

function End-DromSession {
    param (
        [string]$SessionId,
        [object]$ShiftServerIP
    )
    $baseUri = [Uri]$ShiftServerIP
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

function Get-BlueprintIDByName {
    param(
        [string]$SessionId,
        [string]$BlueprintName,
        [string]$ShiftServerIp
    )

    $baseUri = [Uri]$ShiftServerIp
    $builder = New-Object System.UriBuilder($baseUri)
    $builder.Port = 3700
    $builder.Path = "api/setup/drplan/byName"
    $builder.Query = "bpName=$BlueprintName"
    $url = $builder.Uri.AbsoluteUri

    $headers = @{
        "Content-Type" = "application/json"
        "netapp-sie-sessionid" = $SessionId
    }

    try {
        Log-Info "Retrieving blueprint ID for '$BlueprintName' using GET $url"
        $response = Invoke-RestMethod -Method Get -Uri $url -Headers $headers -ErrorAction Stop -SkipCertificateCheck
        return $response._id  
    }
    catch {
        Log-Error "Failed to retrieve blueprint ID for '$BlueprintName'. Error: $_"
        return $null
    }
}

function Remove-Blueprint {
    param(
        [string]$SessionId,
        [string]$BlueprintId,
        [string]$BlueprintName,
        [string]$ExcludePrepareJob,
        [string]$ShiftServerIp
    )

    $baseUri = [Uri]$ShiftServerIp
    $builder = New-Object System.UriBuilder($baseUri)
    $builder.Port = 3704
    $builder.Path = "api/recovery/execution/deleteExecution"
    $builder.Query = "drPlanId=$BlueprintId&excludeFlag=$ExcludePrepareJob"
    $url = $builder.Uri.AbsoluteUri

    $headers = @{
        "Content-Type" = "application/json"
        "netapp-sie-sessionid" = $SessionId
    }

    try {
        Log-Info "Deleting blueprint '$BlueprintName' (ID: $BlueprintId) using DELETE $url"
        $response = Invoke-RestMethod -Method Delete -Uri $url -Headers $headers -ErrorAction Stop -SkipCertificateCheck
        return $response
    }
    catch {
        Log-Error "Failed to remove blueprint '$BlueprintName'. Error: $_"
        return $null
    }
}


try {
    $configPath = ".\removeBpJobs.json"
    if (-not (Test-Path $configPath)) { 
        Log-Error "Configuration file not found at path $configPath"
        exit 1 
    }
    $configData = Get-Content $configPath -Raw | ConvertFrom-Json
    $executions = $configData.executions
    if (-not $executions) { 
        Log-Error "No executions found in configuration."
        exit 1 
    }
    
    foreach ($execution in $executions) {
        $shift_username = $execution.shift_username
        $shift_password = $execution.shift_password
        $securePassword = ConvertTo-SecureString $shift_password -AsPlainText -Force
        $shift_server_ip = $execution.shift_server_ip
        $credential = New-Object System.Management.Automation.PSCredential ($shift_username, $securePassword)
        $sessionId = New-DromSession -Credential $credential -ShiftServerIP $shift_server_ip

        foreach ($bpDetail in $execution.blueprint_details) {
            foreach ($bpName in $bpDetail.PSObject.Properties.Name) {
                $ExcludePrepareJob = $bpDetail.$bpName
                switch ($ExcludePrepareJob) {
                    "true" {
                        Log-Info "Prepare job cleanup flag is set to true by user, preparevm jobs will be marked for cleanup."
                    }
                    "false" {
                        Log-Info "Prepare job cleanup flag is set to false by user, preparevm jobs will not be marked for cleanup."
                    }
                    default {
                        $ExcludePrepareJob = "false"
                        Log-Info "Prepare job cleanup flag is set to false by default since variable value was not provided."
                    }
                }
                
                $blueprintId = Get-BlueprintIdByName -SessionId $sessionId -BlueprintName $bpName -ShiftServerIp $shift_server_ip
                if ($null -ne $blueprintId) {
                    Log-Info "Blueprint Name: $bpName Blueprint ID: $blueprintId"
                    Remove-Blueprint -SessionId $sessionId -BlueprintName $bpName -BlueprintId $blueprintId -ExcludePrepareJob $ExcludePrepareJob -ShiftServerIp $shift_server_ip
                } else {
                    Log-Error "Blueprint ID not found for '$bpName'. Skipping deletion."
                }
            }
        }
        $endSession = End-DromSession -SessionId $sessionId -ShiftServerIP $shift_server_ip
        if (-not $endSession) {
            Log-Error "Could not properly end session."
        }
    }
}
catch {
    Log-Error "An error occurred in the process. Error: $_"
}