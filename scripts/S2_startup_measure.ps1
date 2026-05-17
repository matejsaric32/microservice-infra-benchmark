param(
    [string]$Framework = "quarkus-perf-jvm",

    [int]$Runs = 10
)

$NAMESPACE = "perf-test"

$DeploymentMap = @{
    "spring-perf" = "spring/spring-perf-empty.yaml"
    "spring-reactor-perf" = "spring-reactor/spring-reactor-perf-empty.yaml"
    "actix-perf" = "rust/actix-perf-empty.yaml"
    "ktor-perf" = "ktor/ktor-perf-empty.yaml"

    "quarkus-perf-jvm" = "quarkus/quarkus-perf-jvm-empty.yaml"
    "quarkus-perf-native" = "quarkus/quarkus-perf-native-empty.yaml"
    "quarkus-perf-native-micro" = "quarkus/quarkus-perf-native-micro-empty.yaml"
    "quarkus-perf-native-micro-compressed" = "quarkus/quarkus-perf-native-micro-compressed-empty.yaml"
    "quarkus-perf-distroless" = "quarkus/quarkus-perf-distroless-empty.yaml"
}

$deployFile = $DeploymentMap[$Framework]
if (-not $deployFile) {
    Write-Host "Unknown framework: $Framework" -ForegroundColor Red
    Write-Host "Available: $($DeploymentMap.Keys -join ', ')"
    exit 1
}

$results = @()

for ($i = 1; $i -le $Runs; $i++) {
    Write-Host "Run $i/$Runs... " -NoNewline

    kubectl delete deployment $Framework -n $NAMESPACE --ignore-not-found --wait=true 2>$null | Out-Null
    Start-Sleep -Seconds 4

    kubectl apply -f $deployFile 2>$null | Out-Null

    kubectl wait --for=condition=ready pod -l app=$Framework -n $NAMESPACE --timeout=120s 2>$null | Out-Null

    $podJson = kubectl get pods -l app=$Framework -n $NAMESPACE -o json | ConvertFrom-Json
    $pod = $podJson.items[0]

    $scheduled = $pod.status.conditions | Where-Object { $_.type -eq "PodScheduled" }
    $ready = $pod.status.conditions | Where-Object { $_.type -eq "Ready" }

    $scheduledTime = [DateTime]::ParseExact(
            $scheduled.lastTransitionTime,
            "yyyy-MM-ddTHH:mm:ssZ",
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal
    )
    $readyTime = [DateTime]::ParseExact(
            $ready.lastTransitionTime,
            "yyyy-MM-ddTHH:mm:ssZ",
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal
    )

    $duration = ($readyTime - $scheduledTime).TotalSeconds
    $results += $duration

    Write-Host "${duration}s" -ForegroundColor Green
}

$avg = [math]::Round(($results | Measure-Object -Average).Average, 3)
$min = [math]::Round(($results | Measure-Object -Minimum).Minimum, 3)
$max = [math]::Round(($results | Measure-Object -Maximum).Maximum, 3)

Write-Host ""
Write-Host "=== Results: $Framework ===" -ForegroundColor Cyan
Write-Host "Runs:    $Runs"
Write-Host "Min:     ${min}s"
Write-Host "Max:     ${max}s"
Write-Host "Average: ${avg}s" -ForegroundColor Green
Write-Host ""

[PSCustomObject]@{
    Framework = $Framework
    Runs = $Runs
    Min = $min
    Max = $max
    Average = $avg
}