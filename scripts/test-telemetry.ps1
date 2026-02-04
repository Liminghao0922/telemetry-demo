param(
    [Parameter(Mandatory = $true)]
    [string]$BaseUrl,

    [Parameter(Mandatory = $false)]
    [string]$FunctionKey,

    [Parameter(Mandatory = $false)]
    [string]$ApimSubscriptionKey
)

$body = @{
    deviceId = "device-000123"
    timestamp = (Get-Date).ToString("o")
    type = "environment"
    source = "edge-gateway"
    tags = @{
        site = "tokyo"
        line = "L1"
    }
    metrics = @{
        temperatureC = 33.2
        humidityPct = 41.7
        vibration = 0.021
    }
}

$headers = @{
    "Content-Type" = "application/json"
}

if ($ApimSubscriptionKey) {
    $headers["Ocp-Apim-Subscription-Key"] = $ApimSubscriptionKey
}

$uri = "$BaseUrl/telemetry"
if ($FunctionKey) {
    $uri = "$uri?code=$FunctionKey"
}

Write-Host "POST $uri"

Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body ($body | ConvertTo-Json -Depth 5)
