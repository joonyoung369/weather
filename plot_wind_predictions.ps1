$ErrorActionPreference = "Stop"

$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$inputPath = Join-Path $scriptDirectory "predictions.csv"
$outputPath = Join-Path $scriptDirectory "prediction_week.png"
$datetimeFormat = "yyyy-MM-dd HH:mm:ss"
$culture = [Globalization.CultureInfo]::InvariantCulture
$numberStyles = [Globalization.NumberStyles]::Float

$allRows = @(Import-Csv -LiteralPath $inputPath)
if ($allRows.Count -eq 0) {
    throw "predictions.csv contains no rows."
}

$requiredColumns = @(
    "target_time",
    "actual_wind_speed_ms",
    "persistence_prediction_ms",
    "linear_regression_prediction_ms"
)
$missingColumns = @(
    $requiredColumns | Where-Object { $_ -notin $allRows[0].PSObject.Properties.Name }
)
if ($missingColumns.Count -gt 0) {
    throw "predictions.csv is missing required columns: $($missingColumns -join ', ')"
}

$evaluationRows = [Collections.Generic.List[object]]::new()
$persistenceAbsoluteError = 0.0
$regressionAbsoluteError = 0.0
foreach ($row in $allRows) {
    $targetTime = [datetime]::ParseExact(
        $row.target_time,
        $datetimeFormat,
        $culture,
        [Globalization.DateTimeStyles]::None
    )
    $actual = [double]::Parse($row.actual_wind_speed_ms, $numberStyles, $culture)
    $persistence = [double]::Parse($row.persistence_prediction_ms, $numberStyles, $culture)
    $regression = [double]::Parse($row.linear_regression_prediction_ms, $numberStyles, $culture)
    $persistenceAbsoluteError += [math]::Abs($persistence - $actual)
    $regressionAbsoluteError += [math]::Abs($regression - $actual)

    if ($targetTime -ge [datetime]::new(2024, 12, 1) -and $targetTime -lt [datetime]::new(2024, 12, 8)) {
        $evaluationRows.Add([pscustomobject]@{
            TargetTime = $targetTime
            Actual = $actual
            Persistence = $persistence
            Regression = $regression
        })
    }
}

$evaluationRows = @($evaluationRows | Sort-Object TargetTime)
if ($evaluationRows.Count -lt 2) {
    throw "Not enough prediction rows found for 2024-12-01 through 2024-12-07."
}
$forbiddenRows = @(
    $evaluationRows | Where-Object {
        $_.TargetTime -lt [datetime]::new(2024, 12, 1) -or
        $_.TargetTime -gt [datetime]::new(2024, 12, 7, 23, 0, 0)
    }
)
if ($forbiddenRows.Count -gt 0) {
    throw "The selected evaluation interval contains an out-of-range timestamp."
}

$weekStart = [datetime]::new(2024, 12, 1)
$weekEnd = [datetime]::new(2024, 12, 7, 23, 0, 0)
$minimumValue = 0.0
$maximumValue = [math]::Max(
    [math]::Max(($evaluationRows | Measure-Object Actual -Maximum).Maximum, ($evaluationRows | Measure-Object Persistence -Maximum).Maximum),
    ($evaluationRows | Measure-Object Regression -Maximum).Maximum
)
$yStep = if ($maximumValue -le 3) { 0.5 } else { 1.0 }
$yMaximum = [math]::Ceiling($maximumValue / $yStep) * $yStep
if ($yMaximum -le 0) {
    $yMaximum = 1.0
}

$imageWidth = 1500
$imageHeight = 850
$plotLeft = 130
$plotTop = 90
$plotWidth = 1280
$plotHeight = 610
$plotBottom = $plotTop + $plotHeight
$bitmap = [System.Drawing.Bitmap]::new($imageWidth, $imageHeight)
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias

$backgroundBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::White)
$textBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(35, 35, 35))
$gridPen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(225, 228, 232), 1)
$axisPen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(90, 90, 90), 1.5)
$actualPen = [System.Drawing.Pen]::new([System.Drawing.Color]::Black, 2.7)
$baselinePen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(135, 135, 135), 2.4)
$baselinePen.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dash
$regressionPen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(35, 100, 210), 2.7)
$font = [System.Drawing.Font]::new("Segoe UI", 12)
$smallFont = [System.Drawing.Font]::new("Segoe UI", 10)
$titleFont = [System.Drawing.Font]::new("Segoe UI", 19, [System.Drawing.FontStyle]::Bold)
$legendFont = [System.Drawing.Font]::new("Segoe UI", 12)
$graphics.FillRectangle($backgroundBrush, 0, 0, $imageWidth, $imageHeight)
$graphics.DrawString("Wind speed prediction: December 1-7, 2024", $titleFont, $textBrush, 130, 25)

for ($value = $minimumValue; $value -le $yMaximum + 1e-8; $value += $yStep) {
    $y = $plotBottom - (($value - $minimumValue) / ($yMaximum - $minimumValue) * $plotHeight)
    $graphics.DrawLine($gridPen, $plotLeft, [single]$y, $plotLeft + $plotWidth, [single]$y)
    $label = $value.ToString("0.#", $culture)
    $graphics.DrawString($label, $font, $textBrush, 72, [single]($y - 11))
}

for ($day = 0; $day -lt 7; $day++) {
    $tickTime = $weekStart.AddDays($day)
    $x = $plotLeft + (($tickTime - $weekStart).TotalHours / ($weekEnd - $weekStart).TotalHours * $plotWidth)
    $graphics.DrawLine($gridPen, [single]$x, $plotTop, [single]$x, $plotBottom)
    $graphics.DrawString($tickTime.ToString("MM-dd", $culture), $font, $textBrush, [single]($x - 26), $plotBottom + 12)
}

$graphics.DrawLine($axisPen, $plotLeft, $plotTop, $plotLeft, $plotBottom)
$graphics.DrawLine($axisPen, $plotLeft, $plotBottom, $plotLeft + $plotWidth, $plotBottom)

$actualPoints = [Collections.Generic.List[System.Drawing.PointF]]::new()
$persistencePoints = [Collections.Generic.List[System.Drawing.PointF]]::new()
$regressionPoints = [Collections.Generic.List[System.Drawing.PointF]]::new()
foreach ($row in $evaluationRows) {
    $x = $plotLeft + (($row.TargetTime - $weekStart).TotalHours / ($weekEnd - $weekStart).TotalHours * $plotWidth)
    $actualY = $plotBottom - (($row.Actual - $minimumValue) / ($yMaximum - $minimumValue) * $plotHeight)
    $persistenceY = $plotBottom - (($row.Persistence - $minimumValue) / ($yMaximum - $minimumValue) * $plotHeight)
    $regressionY = $plotBottom - (($row.Regression - $minimumValue) / ($yMaximum - $minimumValue) * $plotHeight)
    $actualPoints.Add([System.Drawing.PointF]::new([single]$x, [single]$actualY))
    $persistencePoints.Add([System.Drawing.PointF]::new([single]$x, [single]$persistenceY))
    $regressionPoints.Add([System.Drawing.PointF]::new([single]$x, [single]$regressionY))
}
$graphics.DrawLines($actualPen, $actualPoints.ToArray())
$graphics.DrawLines($baselinePen, $persistencePoints.ToArray())
$graphics.DrawLines($regressionPen, $regressionPoints.ToArray())

$axisLabelState = $graphics.Save()
$graphics.TranslateTransform(32, [single]($plotTop + $plotHeight / 2))
$graphics.RotateTransform(-90)
$graphics.DrawString("Wind speed (m/s)", $font, $textBrush, -72, -12)
$graphics.Restore($axisLabelState)
$graphics.DrawString("Target time (KST)", $font, $textBrush, [single]($plotLeft + $plotWidth / 2 - 75), $plotBottom + 45)

$legendY = 790
$graphics.DrawLine($actualPen, 365, $legendY, 405, $legendY)
$graphics.DrawString("Actual", $legendFont, $textBrush, 415, $legendY - 11)
$graphics.DrawLine($baselinePen, 550, $legendY, 590, $legendY)
$graphics.DrawString("Persistence baseline", $legendFont, $textBrush, 600, $legendY - 11)
$graphics.DrawLine($regressionPen, 850, $legendY, 890, $legendY)
$graphics.DrawString("Linear regression", $legendFont, $textBrush, 900, $legendY - 11)

try {
    $bitmap.Save($outputPath, [System.Drawing.Imaging.ImageFormat]::Png)
}
finally {
    $graphics.Dispose()
    $bitmap.Dispose()
    $backgroundBrush.Dispose()
    $textBrush.Dispose()
    $gridPen.Dispose()
    $axisPen.Dispose()
    $actualPen.Dispose()
    $baselinePen.Dispose()
    $regressionPen.Dispose()
    $font.Dispose()
    $smallFont.Dispose()
    $titleFont.Dispose()
    $legendFont.Dispose()
}

$persistenceMae = $persistenceAbsoluteError / $allRows.Count
$regressionMae = $regressionAbsoluteError / $allRows.Count
Write-Output "Chart rows (target_time 2024-12-01 00:00 through 2024-12-07 23:00 KST): $($evaluationRows.Count)"
Write-Output "Full December evaluation rows: $($allRows.Count)"
Write-Output ("December persistence MAE: {0:F6} m/s" -f $persistenceMae)
Write-Output ("December linear regression MAE: {0:F6} m/s" -f $regressionMae)
Write-Output "Chart saved to: $outputPath"
