param(
    [Parameter(Mandatory=$true)]
    [string]$InputJson
)
$Global:LogFolder = ".\logs\initiate_prepare_vm"
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
    $logFile = Join-Path $Global:LogFolder ("initiate_prepare_vm_" + (Get-Date -Format 'yyyyMMdd_HHmm') + ".log")
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

function Initiate-PrepareVM {
    param(
        [string]$SessionId,
        [string]$BlueprintId,
        [object]$Config
    )
    $baseUri = [Uri]$Config.shift_server_ip
    $builder = New-Object System.UriBuilder($baseUri)
    $builder.Port = 3704
    $builder.Path = "api/recovery/drPlan/$BlueprintId/preparevm/execution"
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
         Log-Info "Executing Prepare VM for blueprint id $BlueprintId using URL $url"
         $response = Invoke-RestMethod -Method Post -Uri $url -Headers $headers -Body $body -ErrorAction Stop -SkipCertificateCheck
         if ($response._id) { 
              Log-Info "Prepare VM for Blueprint $BlueprintId executed with successfully with id $($response._id)."
              return $response._id
         }
         else {
              Log-Error "Blueprint execution did not return an execution id."
              return $false
         }
    }
    catch {
         Log-Error "Failed to execute Prepare VM for Blueprint $BlueprintId. Error: $_"
         return $false
    }
}

function Initiate-PrepareVM-Workflow {
    param (
        [object]$InitiatePrepareVMConfig,
        [int]$Index
    )

    Log-Info "Starting Prepare VM for workflow $($Index + 1)"
    $shift_username = $InitiatePrepareVMConfig.shift_username
    $shift_password = $InitiatePrepareVMConfig.shift_password
    $blueprint_name = $InitiatePrepareVMConfig.blueprint_name

    if (-not $shift_username -or -not $shift_password -or -not $blueprint_name) {
        Log-Error "Missing required details for Prepare VM index $($Index + 1). Skipping this Initiation of Prepare VM."
        return
    }

    $securePassword = ConvertTo-SecureString $shift_password -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential ($shift_username, $securePassword)
    $sessionId = New-DromSession -Credential $credential -Config $InitiatePrepareVMConfig
    if (-not $sessionId) {
        Log-Error "Failed to create session for Prepare VM index $($Index + 1). Skipping this Initiation of Prepare VM."
        return
    }

    $blueprint_id = Get-BlueprintIdByName -SessionId $sessionId -BlueprintName $blueprint_name -Config $InitiatePrepareVMConfig
    $executionId = Initiate-PrepareVM -SessionId $sessionId -BlueprintId $blueprint_id -Config $InitiatePrepareVMConfig
    if ($executionId) {
        Log-Info "Prepare VM index $($Index + 1) executed successfully; Execution ID: $executionId"
    }
    else {
        Log-Error "Prepare VM index $($Index + 1) execution failed."
    }

    $status = Prepare-VM -SessionId $sessionId -BlueprintId $blueprint_id -ShiftServerIP $InitiatePrepareVMConfig.shift_server_ip
    
    $endSession = End-DromSession -SessionId $sessionId -Config $InitiatePrepareVMConfig
    if (-not $endSession) {
         Log-Error "Could not properly end session for Prepare VM index $($Index + 1)."
    }
}

try {
    $configData = $InputJson | ConvertFrom-Json
    $executions = $configData.executions

    if (-not $executions) { 
        Log-Error "No executions found in configuration."
        exit 1 
    }

    for ($idx = 0; $idx -lt $executions.Count; $idx++) {
        $InitiatePrepareVMConfig = $executions[$idx]
        Initiate-PrepareVM-Workflow -InitiatePrepareVMConfig $InitiatePrepareVMConfig -Index $idx
    }
}
catch {
    Log-Error "An error occurred in the Initiation of Prepare VM process. Error: $_"
}