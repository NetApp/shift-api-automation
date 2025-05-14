param(
    [Parameter(Mandatory=$true)]
    [string]$InputJson
)
$Global:LogFolder = ".\logs\run_compliance_check"
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
    $logFile = Join-Path $Global:LogFolder ("run_compliance_check_" + (Get-Date -Format 'yyyyMMdd_HHmm') + ".log")
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

try {
    $configData = $InputJson | ConvertFrom-Json
    $executions = $configData.executions
    if (-not $executions) { exit 1 }
    for ($idx = 0; $idx -lt $executions.Count; $idx++) {
        $currentConfig = $executions[$idx]
        Log-Info "Starting complaince check workflow $($idx + 1)"

        $shift_username = $currentConfig.shift_username
        $shift_password = $currentConfig.shift_password
        $blueprint_name = $currentConfig.blueprint_name

        $securePassword = ConvertTo-SecureString $shift_password -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential ($shift_username, $securePassword)
        $sessionId = New-DromSession -Credential $credential -Config $currentConfig

        if (-not $sessionId) {
            Log-Error "Failed to create session for run_compliance_check index $($idx + 1). Skipping this run_compliance_check."
            continue
        }

        $blueprint_id = Get-BlueprintIdByName -SessionId $sessionId -BlueprintName $blueprint_name -Config $currentConfig
        if (-not $shift_username -or -not $shift_password -or -not $blueprint_id) {
            Log-Error "Missing credentials or blueprint_id for run_compliance_check index $($idx + 1). Skipping this run_compliance_check."
            continue
        }

        $complianceTaskId = Run-ComplianceCheck -SessionId $sessionId -ShiftServerIp $currentConfig.shift_server_ip -BlueprintId $blueprint_id
        if ($complianceTaskId) {
            Log-Info "Compliance check completed for blueprint $blueprint_id with task id $complianceTaskId"
        }
        else {
            Log-Error "Compliance check failed for blueprint $blueprint_id"
        }
        End-DromSession -SessionId $sessionId -Config $currentConfig
    }
}
catch {
    Log-Error "An error occurred during run_compliance_check workflows: $_"
}
finally {
    Log-Info "Please find the logs of the execution in the latest file of the logs folder"
}