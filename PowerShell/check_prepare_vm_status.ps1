$Global:LogFolder = ".\logs\check_prepare_vm_status"
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

    $logFile = Join-Path $Global:LogFolder ("prepare_vm_" + (Get-Date -Format 'yyyyMMdd_HHmm') + ".log")
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
        "netapp-sie-sessionid"  = $SessionId
    }
    $body = @{ sessionId = "$SessionId" } | ConvertTo-Json

    try {
        Log-Info "Ending session $SessionId"
        Invoke-RestMethod -Method Post -Uri $url -Headers $headers -Body $body | Out-Null -SkipCertificateCheck
        return $true
    }
    catch {
        Log-Error "Failed to end session $SessionId. Error: $_"
        return $false
    }
}

function Get-BlueprintStatus {
    param (
        [string]$ShiftServerIP,
        [string]$SessionId
    )
    $baseUri = [Uri]$ShiftServerIP
    $builder = New-Object System.UriBuilder($baseUri)
    $builder.Port = 3704
    $builder.Path = "api/recovery/drplan/status"
    $url = $builder.Uri.AbsoluteUri
    $headers = @{
        "Content-Type" = "application/json"
        "netapp-sie-sessionid" = $SessionId
    }
    Write-Log "INFO" "Retrieving blueprint status using GET $url"

    try {
        $response = Invoke-RestMethod -Method GET -Uri $url -Headers $headers -ErrorAction Stop -SkipCertificateCheck
        Write-Log "INFO" "Response code for Blueprint status is 200"
        return $response
    }
    catch {
        Write-Log "WARNING" "Error occurred while retrieving blueprint status: $_"
        return $null
    }
}

function Wait-ForPrepareVMExecution {
    param (
        [string]$ShiftServerIP,
        [string]$SessionId,
        [string]$BlueprintId,
        [int]$Timeout = 1000
    )
    Write-Log "INFO" "Waiting for prepare VM to complete for blueprint id $BlueprintId"

    $expectedStatus = 4
    $failedStatus = 5

    for ($i = 0; $i -le $Timeout; $i++) {
        $blueprintList = Get-BlueprintStatus -ShiftServerIP $ShiftServerIP -SessionId $SessionId
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
        Start-Sleep -Seconds 1
    }

    Write-Log "ERROR" "Exceeded timeout of $Timeout seconds. Prepare VM is not completed."
    return $false
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
        [string]$ShiftServerIP
    )
    $prepareVmStatus = Wait-ForPrepareVMExecution -ShiftServerIP $ShiftServerIP -SessionId $SessionId -BlueprintId $BlueprintId
    Write-Log "INFO" "Status of Prepare VM is $prepareVmStatus for blueprint $BlueprintId"
    if (-not $prepareVmStatus) {
        Write-Log "ERROR" "Prepare VM for blueprint id $BlueprintId did not complete successfully."
    }
    else {
        Write-Log "INFO" "Prepare VM successfully completed for blueprint id $BlueprintId"
    }
    return $prepareVmStatus
}

$configFile = ".\check_prepare_vm_status.json"

try {
    Write-Log "INFO" "Reading configuration from $configFile"
    $configData = Get-Content $configFile -Raw | ConvertFrom-Json
    $executions = $configData.executions

    if (-not $executions) {
        Write-Log "ERROR" "No executions found in configuration file!"
        exit 1
    }

    $executionIndex = 1
    foreach ($prepareVMConfig in $executions) {
        Write-Log "INFO" "Starting prepare vm workflow $executionIndex"

        $shiftUsername = $prepareVMConfig.shift_username
        $shiftPassword = $prepareVMConfig.shift_password

        if (-not $shiftUsername -or -not $shiftPassword) {
            Log-Error "Missing credentials for prepare vm index $executionIndex. Skipping."
            $executionIndex++
            continue
        }

        $blueprint_name = $prepareVMConfig.blueprint_name

        $shiftServerIP = $prepareVMConfig.shift_server_ip
        if (-not $shiftServerIP) {
            Write-Log "ERROR" "Missing shift_server_ip for prepare vm index $executionIndex. Skipping."
            $executionIndex++
            continue
        }

        $securePassword = ConvertTo-SecureString $shiftPassword -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential ($shiftUsername, $securePassword)
        $sessionId = New-DromSession -Credential $credential -Config $prepareVMConfig
        if (-not $sessionId) {
            Write-Log "ERROR" "Failed to create session for prepare vm index $executionIndex. Skipping."
            $executionIndex++
            continue
        }

        $blueprintId = Get-BlueprintIdByName -SessionId $sessionId -BlueprintName $blueprint_name -Config $prepareVMConfig
        if (-not $blueprintId) {
            Write-Log "ERROR" "Missing blueprint id for prepare vm index $executionIndex. Skipping."
            $executionIndex++
            continue
        }

        $status = Prepare-VM -SessionId $sessionId -BlueprintId $blueprintId -ShiftServerIP $shiftServerIP

        End-DromSession -SessionId $sessionId -Config $prepareVMConfig

        $executionIndex++
    }
}
catch {
    Write-Log "ERROR" "An error occurred during prepare vms: $_"
}
finally {
    Write-Log "INFO" "Please find the logs of the execution in the console output or log file as configured."
}