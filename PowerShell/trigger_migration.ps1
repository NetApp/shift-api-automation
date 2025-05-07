$Global:LogFolder = ".\logs\trigger_migration"
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
    $logFile = Join-Path $Global:LogFolder ("trigger_migration_" + (Get-Date -Format 'yyyyMMdd_HHmm') + ".log")
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
        [int]$Index
    )

    Log-Info "Starting trigger migration workflow $($Index + 1)"
    $shift_username = $MigrationConfig.shift_username
    $shift_password = $MigrationConfig.shift_password
    $blueprint_name = $MigrationConfig.blueprint_name
    $migration_mode = $MigrationConfig.migration_mode

    if (-not $shift_username -or -not $shift_password -or -not $blueprint_name) {
        Log-Error "Missing required details for migration index $($Index + 1). Skipping this migration."
        return
    }

    $securePassword = ConvertTo-SecureString $shift_password -AsPlainText -Force
    $sessionId = New-DromSession -Username $shift_username -Password $securePassword -Config $MigrationConfig
    if (-not $sessionId) {
        Log-Error "Failed to create session for migration index $($Index + 1). Skipping this migration."
        return
    }

    $blueprint_id = Get-BlueprintIdByName -SessionId $sessionId -BlueprintName $blueprint_name -Config $MigrationConfig
    $executionId = Trigger-Migration -SessionId $sessionId -BlueprintId $blueprint_id -MigrationMode $migration_mode -Config $MigrationConfig
    if ($executionId) {
        Log-Info "Migration index $($Index + 1) executed successfully; Execution ID: $executionId"
    }
    else {
        Log-Error "Migration index $($Index + 1) execution failed."
    }

    $endSession = End-DromSession -SessionId $sessionId -Config $MigrationConfig
    if (-not $endSession) {
         Log-Error "Could not properly end session for migration index $($Index + 1)."
    }
}

try {
    $configPath = ".\trigger_migration.json"
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
    for ($idx = 0; $idx -lt $executions.Count; $idx++) {
        $migrationConfig = $executions[$idx]
        Trigger-Migration-Workflow -MigrationConfig $migrationConfig -Index $idx
    }
}
catch {
    Log-Error "An error occurred in the migration process. Error: $_"
}