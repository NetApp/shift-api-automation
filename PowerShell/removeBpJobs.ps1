Param(
    [string]$BPName,
	[string]$ShiftToolKitPath,
    [string]$ExcludePrepareJob
)

if (-not $BPName) {
    Write-Host "Parameter BP name is missing."
    exit 1
}

if (-not $ShiftToolKitPath) {
    Write-Host "Parameter ShiftToolKitPath is missing."
    exit 1
}

if ($BPName -match "'") {
    Write-Host "Please provide BP name with double quotes or no quotes."
    exit 1
}

switch ($ExcludePrepareJob) {
    "true" {
        Write-Host "Prepare job cleanup flag is set to true by user, preparevm jobs will be marked for cleanup."
    }
    "false" {
        Write-Host "Prepare job cleanup flag is set to false by user, preparevm jobs will not be marked for cleanup."
    }
    default {
        $ExcludePrepareJob = "false"
        Write-Host "Prepare job cleanup flag is set to false by default since variable value was not provided."
    }
}

$current_directory = "$ShiftToolKitPath"
$mongosh_path = Join-Path -Path $current_directory -ChildPath 'bin\mongosh-2.3.0-win32-x64\mongosh-2.3.0-win32-x64\bin\mongosh.exe'

if (-not (Get-Module -ListAvailable -Name CredentialManager)) {
    Install-Module -Name CredentialManager -Force -Scope CurrentUser
}
Import-Module CredentialManager

$credential = Get-StoredCredential -Target 'MongoDB_Creds'
if (-not $credential) {
    Write-Host "Could not find the stored credential 'MongoDB_Creds'."
    exit 1
}
$username = $credential.GetNetworkCredential().Username
$password = $credential.GetNetworkCredential().Password


$auth_db = 'admin'

$evalJs = @'
var ids = [];
db.getSiblingDB("draas_setup").drplan.find({ name: "<BPName>" }, { _id: 1 }).forEach(function(doc) {
    ids.push(doc._id);
});
if ("<ExcludeFlag>" === "true") {
    // Delete all matching 'drPlan._id' (including 'preparevm')
    db.getSiblingDB("draas_recovery").execution.deleteMany({ "drPlan._id": { "$in": ids } });
} else {
    // Delete all except 'preparevm'
    db.getSiblingDB("draas_recovery").execution.deleteMany({
        "drPlan._id": { "$in": ids },
        "type": { "$ne": "preparevm" }
    });
}
'@

$evalJs = $evalJs -replace '<BPName>', [Regex]::Escape($BPName)
$evalJs = $evalJs -replace '<ExcludeFlag>', [Regex]::Escape($ExcludePrepareJob)


& "$mongosh_path" --host "localhost" `
                  --username $username `
                  --password $password `
                  --authenticationDatabase $auth_db `
                  --eval $evalJs

Write-Host "Script completed"
