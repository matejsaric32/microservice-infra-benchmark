param(
    [string]$Framework = "quarkus-perf-jvm",
    [int]$Runs = 10
)

$NAMESPACE = "perf-test"
$FRAMEWORKS_DIR = Join-Path $PSScriptRoot "..\frameworks"

$DeploymentMap = @{
    "spring-perf"                            = "spring\spring-perf-empty.yaml"
    "spring-reactor-perf"                    = "spring-reactor\spring-reactor-perf-empty.yaml"
    "actix-perf"                             = "rust\actix-perf-empty.yaml"
    "ktor-perf"                              = "ktor\ktor-perf-empty.yaml"
    "quarkus-perf-jvm"                       = "quarkus\jvm\quarkus-perf-jvm-empty.yaml"
    "quarkus-perf-native"                    = "quarkus\native\quarkus-perf-native-empty.yaml"
    "quarkus-perf-native-micro"              = "quarkus\native\quarkus-perf-native-micro-empty.yaml"
    "quarkus-perf-native-micro-compressed"   = "quarkus\native\quarkus-perf-native-micro-compressed-empty.yaml"
    "quarkus-perf-distroless"                = "quarkus\native\quarkus-perf-distroless-empty.yaml"
}

$DeployFile = $DeploymentMap[$Framework]
if (-not $DeployFile) {
    Write-Host "Unknown framework: $Framework" -ForegroundColor Red
    Write-Host "Available: $($DeploymentMap.Keys -join ', ')"
    exit 1
}

$FullPath = Join-Path $FRAMEWORKS_DIR $DeployFile
if (-not (Test-Path $FullPath)) {
    Write-Host "Deployment file not found: $FullPath" -ForegroundColor Red
    exit 1
}

$Results = @()

for ($i = 1; $i -le $Runs; $i++) {
    Write-Host "Run $i/$Runs... " -NoNewline

    kubectl delete deployment $Framework -n $NAMESPACE --ignore-not-found --wait=true 2>$null | Out-Null
    Start-Sleep -Seconds 4

    kubectl apply -f $FullPath 2>$null | Out-Null
    kubectl wait --for=condition=ready pod -l "app=$Framework" -n $NAMESPACE --timeout=120s 2>$null | Out-Null

    $PodJson = kubectl get pods -l "app=$Framework" -n $NAMESPACE -o json | ConvertFrom-Json
    $Pod = $PodJson.items[0]

    $Scheduled = $Pod.status.conditions | Where-Object { $_.type -eq "PodScheduled" }
    $Ready     = $Pod.status.conditions | Where-Object { $_.type -eq "Ready" }

    $ScheduledTime = [DateTime]::ParseExact(
            $Scheduled.lastTransitionTime,
            "yyyy-MM-ddTHH:mm:ssZ",
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal
    )
    $ReadyTime = [DateTime]::ParseExact(
            $Ready.lastTransitionTime,
            "yyyy-MM-ddTHH:mm:ssZ",
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal
    )

    $Duration = [math]::Round(($ReadyTime - $ScheduledTime).TotalSeconds, 3)
    $Results += $Duration

    Write-Host "${Duration}s" -ForegroundColor Green
}

$Min = [math]::Round(($Results | Measure-Object -Minimum).Minimum, 3)
$Max = [math]::Round(($Results | Measure-Object -Maximum).Maximum, 3)
$Avg = [math]::Round(($Results | Measure-Object -Average).Average, 3)

Write-Host ""
Write-Host "=== Results: $Framework ===" -ForegroundColor Cyan
Write-Host "Runs:    $Runs"
Write-Host "Min:     ${Min}s"
Write-Host "Max:     ${Max}s"
Write-Host "Average: ${Avg}s" -ForegroundColor Green
Write-Host ""

$Header  = "{0,-45} {1,5} {2,8} {3,8} {4,8}" -f "Framework", "Runs", "Min", "Max", "Average"
$Row     = "{0,-45} {1,5} {2,8} {3,8} {4,8}" -f $Framework, $Runs, "${Min}s", "${Max}s", "${Avg}s"
Write-Host $Header
Write-Host $Row

[PSCustomObject]@{
    Framework = $Framework
    Runs      = $Runs
    Min       = $Min
    Max       = $Max
    Average   = $Avg
}