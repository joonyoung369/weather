$ErrorActionPreference = "Stop"

$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$inputPath = Join-Path $scriptDirectory "wind_dataset.csv"
$outputPath = Join-Path $scriptDirectory "predictions.csv"
$datetimeFormat = "yyyy-MM-dd HH:mm:ss"
$culture = [Globalization.CultureInfo]::InvariantCulture
$numberStyles = [Globalization.NumberStyles]::Float
$features = @(
    "wind_speed_ms",
    "wind_speed_ms_lag_1h",
    "wind_speed_ms_lag_2h",
    "temperature_C",
    "humidity_pct"
)
$requiredColumns = @(
    "prediction_time",
    "target_time",
    "target_wind_speed_ms"
) + $features

$sourceRows = @(Import-Csv -LiteralPath $inputPath)
if ($sourceRows.Count -eq 0) {
    throw "wind_dataset.csv contains no rows."
}

$missingColumns = @(
    $requiredColumns | Where-Object { $_ -notin $sourceRows[0].PSObject.Properties.Name }
)
if ($missingColumns.Count -gt 0) {
    throw "wind_dataset.csv is missing required columns: $($missingColumns -join ', ')"
}

$records = [Collections.Generic.List[object]]::new()
$rowNumber = 1
foreach ($row in $sourceRows) {
    $rowNumber++
    $predictionTime = [datetime]::ParseExact(
        $row.prediction_time, $datetimeFormat, $culture,
        [Globalization.DateTimeStyles]::None
    )
    $targetTime = [datetime]::ParseExact(
        $row.target_time, $datetimeFormat, $culture,
        [Globalization.DateTimeStyles]::None
    )
    if ($targetTime -ne $predictionTime.AddHours(1)) {
        throw "Row $rowNumber does not have a target exactly one hour after prediction_time."
    }

    $values = [double[]]::new($features.Count)
    for ($column = 0; $column -lt $features.Count; $column++) {
        $value = $row.($features[$column])
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "Row $rowNumber has an empty feature: $($features[$column])."
        }
        $values[$column] = [double]::Parse($value, $numberStyles, $culture)
    }
    if ([string]::IsNullOrWhiteSpace($row.target_wind_speed_ms)) {
        throw "Row $rowNumber has an empty target."
    }
    $targetValue = [double]::Parse($row.target_wind_speed_ms, $numberStyles, $culture)

    $records.Add([pscustomobject]@{
        PredictionTime = $predictionTime
        TargetTime = $targetTime
        Features = $values
        Target = $targetValue
    })
}

$records = @($records | Sort-Object TargetTime, PredictionTime)
$trainingStart = [datetime]::new(2023, 1, 1)
$evaluationStart = [datetime]::new(2024, 12, 1)
$evaluationEnd = [datetime]::new(2025, 1, 1)
$trainingRows = @(
    $records | Where-Object {
        $_.TargetTime -ge $trainingStart -and $_.TargetTime -lt $evaluationStart
    }
)
$evaluationRows = @(
    $records | Where-Object {
        $_.TargetTime -ge $evaluationStart -and $_.TargetTime -lt $evaluationEnd
    }
)
if ($trainingRows.Count -eq 0 -or $evaluationRows.Count -eq 0) {
    throw "Training or December 2024 evaluation data is empty."
}

$featureMeans = [double[]]::new($features.Count)
$featureScales = [double[]]::new($features.Count)
foreach ($row in $trainingRows) {
    for ($column = 0; $column -lt $features.Count; $column++) {
        $featureMeans[$column] += $row.Features[$column]
    }
}
for ($column = 0; $column -lt $features.Count; $column++) {
    $featureMeans[$column] /= $trainingRows.Count
}
foreach ($row in $trainingRows) {
    for ($column = 0; $column -lt $features.Count; $column++) {
        $difference = $row.Features[$column] - $featureMeans[$column]
        $featureScales[$column] += $difference * $difference
    }
}
for ($column = 0; $column -lt $features.Count; $column++) {
    $featureScales[$column] = [math]::Sqrt($featureScales[$column] / $trainingRows.Count)
    if ($featureScales[$column] -eq 0) {
        $featureScales[$column] = 1
    }
}

$parameterCount = $features.Count + 1
$augmented = [double[][]]::new($parameterCount)
for ($i = 0; $i -lt $parameterCount; $i++) {
    $augmented[$i] = [double[]]::new($parameterCount + 1)
}
foreach ($row in $trainingRows) {
    $design = [double[]]::new($parameterCount)
    $design[0] = 1
    for ($column = 0; $column -lt $features.Count; $column++) {
        $design[$column + 1] = ($row.Features[$column] - $featureMeans[$column]) / $featureScales[$column]
    }
    for ($i = 0; $i -lt $parameterCount; $i++) {
        for ($j = 0; $j -lt $parameterCount; $j++) {
            $augmented[$i][$j] += $design[$i] * $design[$j]
        }
        $augmented[$i][$parameterCount] += $design[$i] * $row.Target
    }
}

for ($pivotColumn = 0; $pivotColumn -lt $parameterCount; $pivotColumn++) {
    $pivotRow = $pivotColumn
    for ($candidate = $pivotColumn + 1; $candidate -lt $parameterCount; $candidate++) {
        if ([math]::Abs($augmented[$candidate][$pivotColumn]) -gt [math]::Abs($augmented[$pivotRow][$pivotColumn])) {
            $pivotRow = $candidate
        }
    }
    if ([math]::Abs($augmented[$pivotRow][$pivotColumn]) -lt 1e-10) {
        throw "The training features do not yield a numerically solvable linear regression."
    }
    if ($pivotRow -ne $pivotColumn) {
        $temporary = $augmented[$pivotColumn]
        $augmented[$pivotColumn] = $augmented[$pivotRow]
        $augmented[$pivotRow] = $temporary
    }
    for ($rowIndex = $pivotColumn + 1; $rowIndex -lt $parameterCount; $rowIndex++) {
        $factor = $augmented[$rowIndex][$pivotColumn] / $augmented[$pivotColumn][$pivotColumn]
        for ($j = $pivotColumn; $j -le $parameterCount; $j++) {
            $augmented[$rowIndex][$j] -= $factor * $augmented[$pivotColumn][$j]
        }
    }
}

$coefficients = [double[]]::new($parameterCount)
for ($i = $parameterCount - 1; $i -ge 0; $i--) {
    $remainder = $augmented[$i][$parameterCount]
    for ($j = $i + 1; $j -lt $parameterCount; $j++) {
        $remainder -= $augmented[$i][$j] * $coefficients[$j]
    }
    $coefficients[$i] = $remainder / $augmented[$i][$i]
}

$predictions = [Collections.Generic.List[object]]::new()
$persistenceAbsoluteError = 0.0
$regressionAbsoluteError = 0.0
foreach ($row in $evaluationRows) {
    $regressionPrediction = $coefficients[0]
    for ($column = 0; $column -lt $features.Count; $column++) {
        $standardized = ($row.Features[$column] - $featureMeans[$column]) / $featureScales[$column]
        $regressionPrediction += $coefficients[$column + 1] * $standardized
    }
    if ($regressionPrediction -lt 0) {
        $regressionPrediction = 0
    }
    $persistencePrediction = $row.Features[0]
    $persistenceAbsoluteError += [math]::Abs($persistencePrediction - $row.Target)
    $regressionAbsoluteError += [math]::Abs($regressionPrediction - $row.Target)
    $predictions.Add([pscustomobject]@{
        prediction_time = $row.PredictionTime.ToString($datetimeFormat, $culture)
        target_time = $row.TargetTime.ToString($datetimeFormat, $culture)
        actual_wind_speed_ms = $row.Target
        persistence_prediction_ms = $persistencePrediction
        linear_regression_prediction_ms = $regressionPrediction
    })
}

$predictions | Export-Csv -LiteralPath $outputPath -NoTypeInformation -Encoding UTF8
$persistenceMae = $persistenceAbsoluteError / $evaluationRows.Count
$regressionMae = $regressionAbsoluteError / $evaluationRows.Count

Write-Output "Training rows (target_time 2023-01 through 2024-11): $($trainingRows.Count)"
Write-Output "Evaluation rows (target_time 2024-12): $($evaluationRows.Count)"
Write-Output ("Persistence MAE: {0:F6} m/s" -f $persistenceMae)
Write-Output ("Linear regression MAE (negative predictions clipped at 0): {0:F6} m/s" -f $regressionMae)
Write-Output "Predictions saved to: $outputPath"
Write-Output "First evaluation result:"
$predictions[0] | Format-List
