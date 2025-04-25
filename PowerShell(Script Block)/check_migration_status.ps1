param(
    [Parameter(Mandatory=$true)]
    [string]$InputJson
)
$Global:LogFolder = ".\logs\check_migration_status"
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

    $logFile = Join-Path $Global:LogFolder ("check_migration_status_" + (Get-Date -Format 'yyyyMMdd_HHmm') + ".log")
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
        $response = Invoke-RestMethod -Method GET -Uri $url -Headers $headers
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
        $response = Invoke-RestMethod -Method GET -Uri $url -Headers $headers
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
        $response = Invoke-RestMethod -Method Get -Uri $url -Headers $headers -ErrorAction Stop
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

try {
    $configData = $InputJson | ConvertFrom-Json
    $executions = $configData.executions

    if (-not $executions) {
        Log-Error "No executions found in configuration file."
        exit 1
    }

    $executionIndex = 1
    foreach ($checkMigrationConfig in $executions) {
        Log-Info "Starting migration status check workflow $executionIndex"

        $shiftUsername = $checkMigrationConfig.shift_username
        $shiftPassword = $checkMigrationConfig.shift_password
        if (-not $shiftUsername -or -not $shiftPassword) {
            Log-Error "Missing credentials for migration status check index $executionIndex. Skipping."
            $executionIndex++
            continue
        }

        $blueprint_name = $checkMigrationConfig.blueprint_name
        $executionId = $checkMigrationConfig.execution_id

        $sessionId = New-DromSession -Username $shiftUsername -Password $shiftPassword -Config $checkMigrationConfig
        if (-not $sessionId) {
            Log-Error "Failed to create session for migration status check index $executionIndex. Skipping."
            $executionIndex++
            continue
        }

        $blueprintId = Get-BlueprintIdByName -SessionId $sessionId -BlueprintName $blueprint_name -Config $checkMigrationConfig
        if (-not $blueprintId -or -not $executionId) {
            Log-Error "Missing blueprint or execution id for migration status check index $executionIndex. Skipping."
            $executionIndex++
            continue
        }

        $status = Check-MigrationStatus -SessionId $sessionId -BlueprintId $blueprintId -ExecutionId $executionId -Config $checkMigrationConfig
        Log-Info "Final migration status for index $executionIndex : $status"

        End-DromSession -SessionId $sessionId -Config $checkMigrationConfig

        $executionIndex++
    }
}
catch {
    Log-Error "An error occurred during migration status checks: $_"
}
finally {
    Log-Info "Please find the logs of the execution in the latest file of the logs folder."
}