Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# =========================
# LOGGING
# =========================
function Log {
    param($Level, $Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$ts] [$Level] $Message"
}

# =========================
# CONFIGURATION
# =========================
$AWS_PROFILE = "mizan"
$AWS_REGION  = "ap-southeast-1"

$BASE_INSTANCE_NAME = "ubuntu"
$START_INDEX = 1

$AMI_ID = "ami-00d8fc944fb171e29"
$INSTANCE_TYPE = "t2.medium"
$KEY_NAME = "mizan-aws"

$SUBNET_ID = "subnet-04544189f0b5babef"
$SECURITY_GROUP_ID = "sg-0f2fe8e0274ff4e0f"

# =========================
# GET ALL ubuntu-* INSTANCES
# =========================
function Get-UbuntuInstances {
    Log DEBUG "Fetching all ubuntu-* instances in one API call"

    aws ec2 describe-instances `
        --profile $AWS_PROFILE `
        --region $AWS_REGION `
        --filters `
            "Name=tag:Name,Values=${BASE_INSTANCE_NAME}-*" `
            "Name=instance-state-name,Values=pending,running,stopping,stopped" `
        --query "Reservations[].Instances[].{
            Id: InstanceId,
            Name: Tags[?Key=='Name'] | [0].Value,
            State: State.Name
        }" `
        --output json | ConvertFrom-Json
}

# =========================
# SHOW SCAN RESULTS
# =========================
function Show-InstanceScanResults {
    param($Instances)

    Log INFO "===== EC2 SCAN RESULTS ====="

    foreach ($inst in $Instances) {

        $ip = "N/A"

        if ($inst.State -eq "running") {
            $tmp = aws ec2 describe-instances `
                --profile $AWS_PROFILE `
                --region $AWS_REGION `
                --instance-ids $inst.Id `
                --query "Reservations[0].Instances[0].PublicIpAddress" `
                --output text

            if ($tmp -and $tmp -ne "None") {
                $ip = $tmp
            }
        }

        Log INFO "--------------------------------"
        Log INFO "Name : $($inst.Name)"
        Log INFO "ID   : $($inst.Id)"
        Log INFO "State: $($inst.State)"
        Log INFO "Public IP: $ip"

        if ($ip -ne "N/A") {
            Log INFO "SSH: ssh -i $KEY_NAME.pem ubuntu@$ip"
        }
    }

    Log INFO "===== END SCAN ====="
}

# =========================
# CHECK IF ANY RUNNING EXISTS
# =========================
function UbuntuRunningInstancesExist {
    param($Instances)
    return @($Instances | Where-Object { $_.State -eq "running" }).Count -gt 0
}

# =========================
# FIND NEXT AVAILABLE NAME
# =========================
function Get-NextInstanceName {
    param($Instances)

    $usedNumbers = $Instances |
        Where-Object { $_.Name -match "^$BASE_INSTANCE_NAME-(\d+)$" } |
        ForEach-Object { [int]$matches[1] }

    $i = $START_INDEX
    while ($usedNumbers -contains $i) { $i++ }

    return "{0}-{1:D2}" -f $BASE_INSTANCE_NAME, $i
}

# =========================
# CREATE INSTANCE
# =========================
function Create-Instance {
    param($Name)

    Log INFO "Launching EC2 instance: $Name"

    # ---- USER DATA (Ubuntu) ----
    $userData = @"
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -y
sudo apt-get upgrade -y
"@

    $userDataBase64 = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes($userData)
    )

    aws ec2 run-instances `
        --profile $AWS_PROFILE `
        --region $AWS_REGION `
        --image-id $AMI_ID `
        --instance-type $INSTANCE_TYPE `
        --key-name $KEY_NAME `
        --network-interfaces "DeviceIndex=0,SubnetId=$SUBNET_ID,Groups=$SECURITY_GROUP_ID,AssociatePublicIpAddress=true" `
        --user-data $userDataBase64 `
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$Name}]" `
        --query "Instances[0].InstanceId" `
        --output text
}

# =========================
# WAIT FOR RUNNING
# =========================
function Wait-ForRunning {
    param($InstanceId)

    $timeout = 300
    $interval = 10
    $elapsed = 0

    Log INFO "Waiting for instance to reach RUNNING..."

    while ($elapsed -lt $timeout) {
        $state = aws ec2 describe-instances `
            --profile $AWS_PROFILE `
            --region $AWS_REGION `
            --instance-ids $InstanceId `
            --query "Reservations[0].Instances[0].State.Name" `
            --output text

        if ($state -eq "running") {
            Log SUCCESS "Instance is RUNNING"
            return
        }

        Start-Sleep -Seconds $interval
        $elapsed += $interval
    }

    Log ERROR "Timeout waiting for RUNNING"
    exit 1
}

# =========================
# WAIT FOR PUBLIC IP
# =========================
function Wait-ForPublicIp {
    param($InstanceId)

    $timeout = 120
    $interval = 5
    $elapsed = 0

    Log INFO "Waiting for Public IP..."

    while ($elapsed -lt $timeout) {
        $ip = aws ec2 describe-instances `
            --profile $AWS_PROFILE `
            --region $AWS_REGION `
            --instance-ids $InstanceId `
            --query "Reservations[0].Instances[0].PublicIpAddress" `
            --output text

        if ($ip -and $ip -ne "None") {
            Log SUCCESS "Public IP: $ip"
            return $ip
        }

        Start-Sleep -Seconds $interval
        $elapsed += $interval
    }

    Log ERROR "Timeout waiting for Public IP"
    exit 1
}

# =========================
# MAIN
# =========================
Log INFO "===== EC2 CREATION DEBUG START ====="

$instances = Get-UbuntuInstances
Show-InstanceScanResults $instances

if (UbuntuRunningInstancesExist $instances) {
    $choice = Read-Host "RUNNING ubuntu instance exists. Create NEW one? (y/N)"
    if ($choice -notmatch '^(y|yes)$') {
        Log INFO "User aborted creation"
        exit 0
    }
}

$name = Get-NextInstanceName $instances
Log INFO "Using instance name: $name"

$instanceId = Create-Instance $name
Log SUCCESS "Instance launched: $instanceId"

Wait-ForRunning $instanceId
$publicIp = Wait-ForPublicIp $instanceId

Log INFO "SSH command:"
Log INFO "ssh -i $KEY_NAME.pem ubuntu@$publicIp"

Log INFO "===== SCRIPT COMPLETED SUCCESSFULLY ====="
