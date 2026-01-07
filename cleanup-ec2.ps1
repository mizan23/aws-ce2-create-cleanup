Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Log {
    param($Level, $Message)
    Write-Host "[$Level] $Message"
}

# =========================
# CONFIGURATION
# =========================
$AWS_PROFILE = "mizan"
$AWS_REGION  = "ap-southeast-1"

# =========================
# GET ALL NON-TERMINATED INSTANCES
# =========================
function Get-AllInstances {
    aws ec2 describe-instances `
        --profile $AWS_PROFILE `
        --region $AWS_REGION `
        --filters `
            "Name=instance-state-name,Values=pending,running,stopping,stopped" `
        --query "Reservations[].Instances[].{
            InstanceId: InstanceId,
            Name: Tags[?Key=='Name'] | [0].Value,
            State: State.Name,
            PublicIp: PublicIpAddress
        }" `
        --output json | ConvertFrom-Json
}

# =========================
# DELETE INSTANCE
# =========================
function Delete-Instance {
    param($InstanceId)

    aws ec2 terminate-instances `
        --profile $AWS_PROFILE `
        --region $AWS_REGION `
        --instance-ids $InstanceId | Out-Null

    Log INFO "Waiting for instance $InstanceId to terminate..."
    aws ec2 wait instance-terminated `
        --profile $AWS_PROFILE `
        --region $AWS_REGION `
        --instance-ids $InstanceId
}

# =========================
# MAIN
# =========================
$instances = Get-AllInstances

if (-not $instances -or $instances.Count -eq 0) {
    Log INFO "No active EC2 instances found."
    exit 0
}

Log INFO "Found $($instances.Count) EC2 instance(s)."
Write-Host ""

foreach ($inst in $instances) {
    Write-Host "----------------------------------------"
    Write-Host "Name       : $($inst.Name)"
    Write-Host "InstanceId : $($inst.InstanceId)"
    Write-Host "State      : $($inst.State)"
    Write-Host "Public IP  : $($inst.PublicIp)"
    Write-Host "----------------------------------------"

    $choice = Read-Host "Do you want to DELETE this instance? (y/N)"

    if ($choice -match '^(y|yes)$') {
        Log WARNING "Deleting instance $($inst.InstanceId)..."
        Delete-Instance $inst.InstanceId
        Log SUCCESS "Instance deleted successfully."
    }
    else {
        Log INFO "Skipped instance $($inst.InstanceId)."
    }

    Write-Host ""
}

Log INFO "EC2 cleanup script finished."
