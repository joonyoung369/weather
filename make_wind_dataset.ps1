$ErrorActionPreference = "Stop"

$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$inputPath = Join-Path $scriptDirectory "asos_108_2023_2024.csv"
$outputPath = Join-Path $scriptDirectory "wind_dataset.csv"
$datetimeFormat = "yyyy-MM-dd HH:mm:ss"
$culture = [Globalization.CultureInfo]::InvariantCulture

$sourceRows = @(Import-Csv -LiteralPath $inputPath)
if ($sourceRows.Count -eq 0) {
    throw "입력 CSV에 관측 행이 없습니다."
}

$requiredColumns = @("datetime", "temperature_C", "humidity_pct", "wind_speed_ms")
$missingColumns = @(
    $requiredColumns | Where-Object { $_ -notin $sourceRows[0].PSObject.Properties.Name }
)
if ($missingColumns.Count -gt 0) {
    throw "입력 CSV에 필요한 열이 없습니다: $($missingColumns -join ', ')"
}

$observations = [Collections.Generic.Dictionary[long, object]]::new()
$timestamps = [Collections.Generic.List[datetime]]::new()
foreach ($row in $sourceRows) {
    $timestamp = [datetime]::ParseExact(
        $row.datetime,
        $datetimeFormat,
        $culture,
        [Globalization.DateTimeStyles]::None
    )
    if ($observations.ContainsKey($timestamp.Ticks)) {
        throw "중복 관측 시각이 있습니다: $($row.datetime)"
    }

    $observations.Add($timestamp.Ticks, $row)
    $timestamps.Add($timestamp)
}

$timestamps.Sort()
$firstTime = $timestamps[0]
$lastTime = $timestamps[$timestamps.Count - 1]
$hourlyRowCount = [int](($lastTime - $firstTime).TotalHours) + 1
$dataset = [Collections.Generic.List[object]]::new()

for ($hour = 2; $hour -lt $hourlyRowCount - 1; $hour++) {
    $predictionTime = $firstTime.AddHours($hour)
    $oneHourBefore = $predictionTime.AddHours(-1)
    $twoHoursBefore = $predictionTime.AddHours(-2)
    $targetTime = $predictionTime.AddHours(1)

    $currentTicks = $predictionTime.Ticks
    $oneHourTicks = $oneHourBefore.Ticks
    $twoHourTicks = $twoHoursBefore.Ticks
    $targetTicks = $targetTime.Ticks
    if (
        -not $observations.ContainsKey($currentTicks) -or
        -not $observations.ContainsKey($oneHourTicks) -or
        -not $observations.ContainsKey($twoHourTicks) -or
        -not $observations.ContainsKey($targetTicks)
    ) {
        continue
    }

    $current = $observations[$currentTicks]
    $oneHour = $observations[$oneHourTicks]
    $twoHours = $observations[$twoHourTicks]
    $target = $observations[$targetTicks]
    $requiredValues = @(
        $current.wind_speed_ms,
        $current.temperature_C,
        $current.humidity_pct,
        $oneHour.wind_speed_ms,
        $twoHours.wind_speed_ms,
        $target.wind_speed_ms
    )
    if (@($requiredValues | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
        continue
    }

    $dataset.Add([pscustomobject]@{
        prediction_time = $predictionTime.ToString($datetimeFormat, $culture)
        target_time = $targetTime.ToString($datetimeFormat, $culture)
        wind_speed_ms = $current.wind_speed_ms
        temperature_C = $current.temperature_C
        humidity_pct = $current.humidity_pct
        wind_speed_ms_lag_1h = $oneHour.wind_speed_ms
        wind_speed_ms_lag_2h = $twoHours.wind_speed_ms
        target_wind_speed_ms = $target.wind_speed_ms
    })
}

$dataset | Export-Csv -LiteralPath $outputPath -NoTypeInformation -Encoding UTF8

Write-Output "시간 간격 보정 후 행 수: $hourlyRowCount"
Write-Output "저장된 학습 행 수: $($dataset.Count)"
Write-Output "저장 위치: $outputPath"
Write-Output "첫 4행:"
Import-Csv -LiteralPath $outputPath | Select-Object -First 4 | Format-Table -AutoSize
