<#
.SYNOPSIS
    Slideshow generator using FFmpeg + Intel QSV.

.DESCRIPTION
    - Scans images and videos.
    - Extracts date/time from filenames in YYYYMMDD_HHMMSS format.
    - Sorts media chronologically using the filename timestamp.
    - Supports Portrait, Landscape, or Both.
    - Automatically names the output according to orientation selection.
    - Uses blurred backgrounds for mismatched aspect ratios.
    - Images receive a slow Ken Burns zoom.
    - Videos retain their original orientation.
    - Original video audio is preserved.
    - Crossfades between clips.
    - Background music is mixed with original video audio.
    - Music is at 100% normally and 40% while original video audio plays.
    - Music switches directly between 100% and 40%.
    - No music fade-in or fade-out.
    - Creates date-based chapters.
    - Uses Intel Quick Sync HEVC encoding.
    - Processes media in batches.

    Filename format:
        YYYYMMDD_HHMMSS.extension

    Example:
        20260902_111213.jpg
        20260902_111530.mp4

.REQUIREMENTS
    FFmpeg
    FFprobe
    Intel QSV-capable FFmpeg build
#>

param (
    [string[]]$InputFiles,
    [string]$Path = ".",
    [string[]]$Filter = @(
        "IMG*.jpg",
        "IMG*.jpeg",
        "IMG*.png",
        "IMG*.mov",
        "IMG*.mp4",
        "*.jpg",
        "*.jpeg",
        "*.png",
        "*.mov",
        "*.mp4"
    ),
    [string]$OutputFile = "",
    [int]$Width = 1080,
    [int]$Height = 1440,
    [int]$DurationSeconds = 4,
    [int]$FadeSeconds = 1,
    [int]$Fps = 30,
    [int]$BatchSize = 30
)

$ErrorActionPreference = "Stop"

# ============================================================
# STARTUP
# ============================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "        FFmpeg / Intel QSV SLIDESHOW GENERATOR" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Get-Command "ffmpeg" -ErrorAction SilentlyContinue)) {
    Write-Error "FFmpeg was not found in PATH."
    exit 1
}

if (-not (Get-Command "ffprobe" -ErrorAction SilentlyContinue)) {
    Write-Error "FFprobe was not found in PATH."
    exit 1
}

$Path = (Resolve-Path $Path).Path

Write-Host "Working directory: $Path"
Write-Host ""

# ============================================================
# ORIENTATION SELECTION
# ============================================================

$choice = (
    Read-Host "Include media: [P]ortrait, [L]andscape, or [B]oth? (Default: B)"
).Trim().ToUpper()

if ([string]::IsNullOrWhiteSpace($choice)) {
    $choice = "B"
}

switch -Regex ($choice) {

    "^P" {
        $orientationMode = "Portrait"
        $Width = 1080
        $Height = 1440
    }

    "^L" {
        $orientationMode = "Landscape"
        $Width = 1440
        $Height = 1080
    }

    default {
        $orientationMode = "Both"
    }
}

Write-Host ""
Write-Host "Selected orientation: $orientationMode" -ForegroundColor Yellow
Write-Host "Output resolution: ${Width}x${Height}" -ForegroundColor Yellow
Write-Host ""

# ============================================================
# OUTPUT FILE
# ============================================================

if ([string]::IsNullOrWhiteSpace($OutputFile)) {

    $OutputFile = Join-Path `
        $Path `
        ("slideshow_{0}.mp4" -f $orientationMode)
}
else {

    $outputDirectory = Split-Path $OutputFile -Parent
    $outputName = Split-Path $OutputFile -Leaf

    if ([string]::IsNullOrWhiteSpace($outputDirectory)) {
        $outputDirectory = $Path
    }

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($outputName)
    $extension = [System.IO.Path]::GetExtension($outputName)

    if ([string]::IsNullOrWhiteSpace($extension)) {
        $extension = ".mp4"
    }

    $OutputFile = Join-Path `
        $outputDirectory `
        ("{0}_{1}{2}" -f $baseName, $orientationMode, $extension)
}

Write-Host "Output file: $OutputFile" -ForegroundColor Green
Write-Host ""

# ============================================================
# FIND INPUT FILES
# ============================================================

if ($InputFiles) {

    Write-Host "Using explicitly supplied input files..."

    $rawFiles = @()

    foreach ($pattern in $InputFiles) {

        $rawFiles += Get-Item `
            -Path $pattern `
            -ErrorAction SilentlyContinue
    }
}
else {

    Write-Host "Searching for media..."

    $rawFiles = @(
        Get-ChildItem `
            -Path $Path `
            -Include $Filter `
            -File `
            -Recurse
    )
}

if (-not $rawFiles -or $rawFiles.Count -eq 0) {

    Write-Error "No media files were found."
    exit 1
}

Write-Host "Found $($rawFiles.Count) candidate files."
Write-Host ""

# ============================================================
# IMAGE SUPPORT
# ============================================================

Add-Type -AssemblyName System.Drawing

# ============================================================
# READ MEDIA METADATA
# ============================================================

Write-Host "Scanning media and reading metadata..." -ForegroundColor Cyan

$files = @()

$totalCount = $rawFiles.Count
$currentIndex = 0

foreach ($file in $rawFiles) {

    $currentIndex++

    Write-Progress `
        -Activity "Reading Metadata" `
        -Status "Processing file $currentIndex of $totalCount" `
        -PercentComplete (($currentIndex / $totalCount) * 100)

    try {

        # ----------------------------------------------------
        # EXTRACT DATE/TIME FROM FILENAME
        # ----------------------------------------------------

        if ($file.BaseName -match '^(\d{8})_(\d{6})$') {

            $timestampString = "$($matches[1])_$($matches[2])"

            try {

                $fileDateTime = [datetime]::ParseExact(
                    $timestampString,
                    "yyyyMMdd_HHmmss",
                    [Globalization.CultureInfo]::InvariantCulture
                )

                $date = $fileDateTime.ToString("yyyy-MM-dd")
            }
            catch {

                Write-Warning (
                    "Invalid timestamp in filename: {0}" -f $file.Name
                )

                continue
            }
        }
        else {

            Write-Warning (
                "Skipping file - filename does not match YYYYMMDD_HHMMSS: {0}" `
                -f $file.Name
            )

            continue
        }

        # ----------------------------------------------------
        # BASIC FILE INFORMATION
        # ----------------------------------------------------

        $ext = $file.Extension.ToLower()

        $isVideo = (
            $ext -eq ".mov" -or
            $ext -eq ".mp4" -or
            $ext -eq ".m4v"
        )

        $w = 0
        $h = 0

        $duration = [double]$DurationSeconds
        $hasAudio = $false
        $rotation = 0

        # ====================================================
        # VIDEO
        # ====================================================

        if ($isVideo) {

            try {

                # ------------------------------------------------
                # VIDEO DIMENSIONS
                # ------------------------------------------------

                $dim = & ffprobe `
                    -v error `
                    -select_streams v:0 `
                    -show_entries stream=width,height `
                    -of csv=p=0 `
                    $file.FullName 2>$null |
                    Select-Object -First 1

                if ($dim -match "(\d+),(\d+)") {

                    $w = [int]$matches[1]
                    $h = [int]$matches[2]
                }

                # ------------------------------------------------
                # ROTATION
                # ------------------------------------------------

                $rotTag = & ffprobe `
                    -v error `
                    -select_streams v:0 `
                    -show_entries stream_tags=rotate `
                    -of default=nw=1:nk=1 `
                    $file.FullName 2>$null |
                    Select-Object -First 1

                if ($rotTag -match "^-?\d+$") {

                    $rotation = [int]$rotTag
                }

                if ($rotation -eq 0) {

                    $sideRotation = & ffprobe `
                        -v error `
                        -select_streams v:0 `
                        -show_entries side_data=rotation `
                        -of default=nw=1:nk=1 `
                        $file.FullName 2>$null |
                        Select-Object -First 1

                    if ($sideRotation -match "^-?\d+$") {

                        $rotation = [int]$sideRotation
                    }
                }

                # ------------------------------------------------
                # ACCOUNT FOR ROTATION WHEN CLASSIFYING
                # ------------------------------------------------

                if (
                    ($rotation -eq 90)  -or
                    ($rotation -eq -90) -or
                    ($rotation -eq 270) -or
                    ($rotation -eq -270)
                ) {

                    if ($w -gt 0 -and $h -gt 0) {

                        $tmp = $w
                        $w = $h
                        $h = $tmp
                    }
                }

                # ------------------------------------------------
                # VIDEO DURATION
                # ------------------------------------------------

                $durStr = & ffprobe `
                    -v error `
                    -show_entries format=duration `
                    -of default=nw=1:nk=1 `
                    $file.FullName 2>$null |
                    Select-Object -First 1

                $parsedDur = 0.0

                if (
                    [double]::TryParse(
                        $durStr,
                        [Globalization.NumberStyles]::Float,
                        [Globalization.CultureInfo]::InvariantCulture,
                        [ref]$parsedDur
                    ) -and
                    $parsedDur -gt 0
                ) {

                    $duration = $parsedDur
                }

                # ------------------------------------------------
                # CHECK FOR AUDIO
                # ------------------------------------------------

                $probeAudio = & ffprobe `
                    -v error `
                    -select_streams a `
                    -show_entries stream=index `
                    -of csv=p=0 `
                    $file.FullName 2>$null

                $hasAudio = -not [string]::IsNullOrWhiteSpace(
                    ($probeAudio -join "")
                )
            }
            catch {

                Write-Warning (
                    "FFprobe issue with {0}. Using fallback values." `
                    -f $file.Name
                )
            }

            if ($w -le 0 -or $h -le 0) {

                $w = $Width
                $h = $Height
            }
        }

        # ====================================================
        # IMAGE
        # ====================================================

        else {

            $img = $null

            try {

                $img = [System.Drawing.Image]::FromFile(
                    $file.FullName
                )

                $w = $img.Width
                $h = $img.Height

                # ------------------------------------------------
                # EXIF ORIENTATION
                # ------------------------------------------------

                $orientation = 1

                if ($img.PropertyIdList -contains 274) {

                    $prop = $img.GetPropertyItem(274)

                    $orientation = [BitConverter]::ToUInt16(
                        $prop.Value,
                        0
                    )
                }

                if ($orientation -in 5,6,7,8) {

                    $tmp = $w
                    $w = $h
                    $h = $tmp
                }
            }
            finally {

                if ($img) {
                    $img.Dispose()
                }
            }
        }

        # ====================================================
        # DETERMINE ORIENTATION
        # ====================================================

        $isLandscape = ($w -gt $h)

        $include = $false

        if ($orientationMode -eq "Portrait") {

            $include = -not $isLandscape
        }
        elseif ($orientationMode -eq "Landscape") {

            $include = $isLandscape
        }
        else {

            $include = $true
        }

        # ====================================================
        # ADD MEDIA TO COLLECTION
        # ====================================================

        if ($include) {

            $files += [PSCustomObject]@{

                FullName     = $file.FullName
                Name         = $file.Name

                Width        = $w
                Height       = $h

                Date         = $date
                FileDateTime = $fileDateTime

                IsVideo      = $isVideo
                Duration     = [double]$duration
                HasAudio     = $hasAudio
                Rotation     = $rotation
            }
        }
    }
    catch {

        Write-Warning (
            "Could not read media: {0}" -f $file.Name
        )

        Write-Warning $_
    }
}

Write-Progress `
    -Activity "Reading Metadata" `
    -Completed

# ============================================================
# VERIFY MEDIA
# ============================================================

if ($files.Count -eq 0) {

    Write-Error (
        "No media matched the selected orientation and filename format."
    )

    exit 1
}

# ============================================================
# SORT BY FILENAME TIMESTAMP
# ============================================================

$files = @(
    $files |
        Sort-Object FileDateTime
)

Write-Host ""
Write-Host "Media selected: $($files.Count)" -ForegroundColor Green
Write-Host "Sorted by filename timestamp (YYYYMMDD_HHMMSS)." -ForegroundColor Green
Write-Host ""

# ============================================================
# DISPLAY MEDIA LIST
# ============================================================

foreach ($item in $files) {

    $orientationText = if ($item.Width -gt $item.Height) {
        "LANDSCAPE"
    }
    else {
        "PORTRAIT"
    }

    $audioText = if ($item.HasAudio) {
        "Audio"
    }
    else {
        "No Audio"
    }

    Write-Host (
        "{0,-35} {1,-10} {2,8}x{3,-8} {4,-10} {5,8:N2}s {6}" -f `
        $item.Name,
        $orientationText,
        $item.Width,
        $item.Height,
        $audioText,
        $item.Duration,
        $item.FileDateTime.ToString("yyyy-MM-dd HH:mm:ss")
    )
}

Write-Host ""

# ============================================================
# UPSCALE SIZE FOR KEN BURNS
# ============================================================

$W_up = $Width * 4
$H_up = $Height * 4

# ============================================================
# BUILD TIMELINE
# ============================================================

$globalTime = 0.0
$prevDate = ""

$chapters = @()

$currentChapterTitle = $null
$chapterStart = 0.0

$duckIntervals = @()

for ($idx = 0; $idx -lt $files.Count; $idx++) {

    $item = $files[$idx]

    # --------------------------------------------------------
    # CHAPTER START
    # --------------------------------------------------------

    $isChapterStart = ($item.Date -ne $prevDate)

    $item | Add-Member `
        -MemberType NoteProperty `
        -Name "IsChapterStart" `
        -Value $isChapterStart `
        -Force

    if ($isChapterStart) {

        if ($null -ne $currentChapterTitle) {

            $chapters += [PSCustomObject]@{
                Title = $currentChapterTitle
                Start = $chapterStart
                End   = $globalTime
            }
        }

        $currentChapterTitle = $item.Date
        $chapterStart = $globalTime

        $prevDate = $item.Date
    }

    # --------------------------------------------------------
    # GLOBAL START
    # --------------------------------------------------------

    $item | Add-Member `
        -MemberType NoteProperty `
        -Name "GlobalStart" `
        -Value $globalTime `
        -Force

    # --------------------------------------------------------
    # MUSIC DUCKING INTERVAL
    # --------------------------------------------------------

    if ($item.IsVideo -and $item.HasAudio) {

        $vStart = $globalTime
        $vEnd = $globalTime + $item.Duration

        $duckIntervals += [PSCustomObject]@{
            Start = [double]$vStart
            End   = [double]$vEnd
        }
    }

    # --------------------------------------------------------
    # TIMELINE
    # --------------------------------------------------------

    if ($idx -lt ($files.Count - 1)) {

        $globalTime += [math]::Max(
            0.1,
            $item.Duration - $FadeSeconds
        )
    }
    else {

        $globalTime += $item.Duration
    }
}

# ============================================================
# CLOSE FINAL CHAPTER
# ============================================================

if ($null -ne $currentChapterTitle) {

    $chapters += [PSCustomObject]@{
        Title = $currentChapterTitle
        Start = $chapterStart
        End   = $globalTime
    }
}

$TotalDuration = $globalTime

Write-Host ""
Write-Host (
    "Calculated slideshow duration: {0:N2} seconds" -f $TotalDuration
) -ForegroundColor Cyan

Write-Host ""

# ============================================================
# MERGE MUSIC DUCKING INTERVALS
# ============================================================

$mergedDuckIntervals = @()

if ($duckIntervals.Count -gt 0) {

    $sortedIntervals = @(
        $duckIntervals |
            Sort-Object Start, End
    )

    $currentStart = [double]$sortedIntervals[0].Start
    $currentEnd   = [double]$sortedIntervals[0].End

    for ($i = 1; $i -lt $sortedIntervals.Count; $i++) {

        $nextStart = [double]$sortedIntervals[$i].Start
        $nextEnd   = [double]$sortedIntervals[$i].End

        if ($nextStart -le ($currentEnd + 0.001)) {

            if ($nextEnd -gt $currentEnd) {
                $currentEnd = $nextEnd
            }
        }
        else {

            $mergedDuckIntervals += [PSCustomObject]@{
                Start = $currentStart
                End   = $currentEnd
            }

            $currentStart = $nextStart
            $currentEnd   = $nextEnd
        }
    }

    $mergedDuckIntervals += [PSCustomObject]@{
        Start = $currentStart
        End   = $currentEnd
    }
}

Write-Host (
    "Music duck intervals: {0} original -> {1} merged" -f `
    $duckIntervals.Count,
    $mergedDuckIntervals.Count
) -ForegroundColor Cyan

# ============================================================
# MUSIC VOLUME EXPRESSION
# ============================================================

$volumeExpr = "1"

if ($mergedDuckIntervals.Count -gt 0) {

    $betweenExpressions = @()

    foreach ($interval in $mergedDuckIntervals) {

        $startText = $interval.Start.ToString(
            "0.######",
            [Globalization.CultureInfo]::InvariantCulture
        )

        $endText = $interval.End.ToString(
            "0.######",
            [Globalization.CultureInfo]::InvariantCulture
        )

        $betweenExpressions += (
            "between(t,$startText,$endText)"
        )
    }

    $duckCondition = $betweenExpressions -join "+"

    # Music is 90% volume while original video audio is active.
    $volumeExpr = "if($duckCondition,0.90,1)"
}

# ============================================================
# CREATE CHAPTER METADATA
# ============================================================

$metadataText = ";FFMETADATA1`n"

foreach ($chapter in $chapters) {

    $startRound = [math]::Round(
        $chapter.Start * 1000
    )

    $endRound = [math]::Round(
        $chapter.End * 1000
    )

    $title = $chapter.Title

    $title = $title.Replace("\", "\\")
    $title = $title.Replace("=", "\=")
    $title = $title.Replace(";", "\;")
    $title = $title.Replace("#", "\#")

    $metadataText += (
        "[CHAPTER]`n" +
        "TIMEBASE=1/1000`n" +
        "START=$startRound`n" +
        "END=$endRound`n" +
        "title=$title`n"
    )
}

# ============================================================
# CREATE BATCHES
# ============================================================

$batches = @()

for (
    $idx = 0;
    $idx -lt $files.Count;
    $idx += $BatchSize
) {

    $batchItems = @(
        $files |
            Select-Object -Skip $idx -First $BatchSize
    )

    $batches += ,$batchItems
}

$totalBatches = $batches.Count

Write-Host (
    "Number of batches: {0}" -f $totalBatches
) -ForegroundColor Cyan

Write-Host ""

# ============================================================
# PROCESS BATCHES
# ============================================================

$batchOutputs = @()

for ($b = 0; $b -lt $batches.Count; $b++) {

    $batch = @($batches[$b])

    $batchNum = $b + 1

    $tempOut = Join-Path `
        $Path `
        ("temp_batch_{0}.mp4" -f $b)

    $batchOutputs += $tempOut

    Write-Host "============================================================" -ForegroundColor DarkCyan

    Write-Host (
        "Processing Batch {0} of {1} ({2} items)" -f `
        $batchNum,
        $totalBatches,
        $batch.Count
    ) -ForegroundColor Cyan

    Write-Host "============================================================" -ForegroundColor DarkCyan

    # --------------------------------------------------------
    # FFMPEG ARGUMENTS
    # --------------------------------------------------------

    $ffmpegArgs = @(
        "-hide_banner",
        "-loglevel", "error",
        "-stats"
    )

    $filters = @()
    $audioFilters = @()

    $mixInputs = @("[bg_silence]")
    $audioInputCount = 1

    $localTime = 0.0

    # ========================================================
    # PROCESS EACH ITEM
    # ========================================================

    for ($i = 0; $i -lt $batch.Count; $i++) {

        $item = $batch[$i]

        # ----------------------------------------------------
        # LOCAL TIMELINE
        # ----------------------------------------------------

        $item | Add-Member `
            -MemberType NoteProperty `
            -Name "LocalStart" `
            -Value $localTime `
            -Force

        # ----------------------------------------------------
        # INPUT
        # ----------------------------------------------------

        $ffmpegArgs += "-i"
        $ffmpegArgs += $item.FullName

        # ====================================================
        # AUDIO
        # ====================================================

        if ($item.IsVideo -and $item.HasAudio) {

            $delayMs = [math]::Round(
                $item.LocalStart * 1000
            )

            $audioLabel = "a$i"

            $audioFilters += (
                "[${i}:a]" +
                "aresample=48000," +
                "aformat=sample_fmts=fltp:channel_layouts=stereo," +
                "adelay=${delayMs}|${delayMs}" +
                "[${audioLabel}]"
            )

            $mixInputs += "[${audioLabel}]"

            $audioInputCount++
        }

        # ====================================================
        # SCALE SETTINGS
        # ====================================================

        $scaleIncrease =
            "scale=${Width}:${Height}:force_original_aspect_ratio=increase"

        $scaleDecrease =
            "scale=${Width}:${Height}:force_original_aspect_ratio=decrease"

        $sourceLandscape = (
            $item.Width -gt $item.Height
        )

        $outputLandscape = (
            $Width -gt $Height
        )

        $isMismatched = (
            $sourceLandscape -ne $outputLandscape
        )

        # ====================================================
        # MISMATCHED ORIENTATION
        # ====================================================

        if ($isMismatched) {

            $filters += (
                "[${i}:v]" +
                "fps=${Fps}," +
                "split=2" +
                "[orig${i}][blur${i}]"
            )

            # ------------------------------------------------
            # BLURRED BACKGROUND
            # ------------------------------------------------

            $filters += (
                "[blur${i}]" +
                $scaleIncrease +
                "," +
                "crop=${Width}:${Height}," +
                "boxblur=40," +
                "format=yuv420p" +
                "[bg${i}]"
            )

            # ------------------------------------------------
            # FOREGROUND
            # ------------------------------------------------

            $filters += (
                "[orig${i}]" +
                $scaleDecrease +
                "," +
                "format=yuv420p" +
                "[fg${i}]"
            )

            # ------------------------------------------------
            # COMBINE
            # ------------------------------------------------

            $filters += (
                "[bg${i}]" +
                "[fg${i}]" +
                "overlay=(W-w)/2:(H-h)/2" +
                "[base${i}]"
            )
        }

        # ====================================================
        # MATCHED ORIENTATION
        # ====================================================

        else {

            $filters += (
                "[${i}:v]" +
                "fps=${Fps}," +
                $scaleIncrease +
                "," +
                "crop=${Width}:${Height}," +
                "format=yuv420p" +
                "[base${i}]"
            )
        }

        # ====================================================
        # IMAGE
        # ====================================================

        if (-not $item.IsVideo) {

            $frames = [math]::Max(
                1,
                [math]::Round(
                    $item.Duration * $Fps
                )
            )

            $zMath = "1.05-(0.05*(on/${frames}))"

            # ------------------------------------------------
            # UPSCALE
            # ------------------------------------------------

            $filters += (
                "[base${i}]" +
                "scale=${W_up}:${H_up}" +
                "[up${i}]"
            )

            # ------------------------------------------------
            # KEN BURNS
            # ------------------------------------------------

            $filters += (
                "[up${i}]" +
                "zoompan=" +
                "z='${zMath}':" +
                "x='iw/2-(iw/zoom/2)':" +
                "y='ih/2-(ih/zoom/2)':" +
                "d=${frames}:" +
                "s=${W_up}x${H_up}:" +
                "fps=${Fps}" +
                "[zp${i}]"
            )

            # ------------------------------------------------
            # FINAL IMAGE FORMAT
            # ------------------------------------------------

            $filters += (
                "[zp${i}]" +
                "scale=${Width}:${Height}:flags=bicubic," +
                "setsar=1," +
                "format=nv12" +
                "[v${i}]"
            )
        }

        # ====================================================
        # VIDEO
        # ====================================================

        else {

            $filters += (
                "[base${i}]" +
                "format=nv12" +
                "[v${i}]"
            )
        }

        # ====================================================
        # DATE LABEL
        # ====================================================

        if ($item.IsChapterStart) {

            $dateText = $item.Date

            $dateText = $dateText.Replace("\", "\\")
            $dateText = $dateText.Replace("'", "\'")

            $dateLabel = "vd${i}"

            $filters += (
                "[v${i}]" +
                "drawtext=" +
                "fontfile='C\:/Windows/Fonts/arial.ttf':" +
                "text='${dateText}':" +
                "fontcolor=white:" +
                "fontsize=48:" +
                "x=40:" +
                "y=h-th-40:" +
                "box=1:" +
                "boxcolor=black@0.5:" +
                "boxborderw=10:" +
                "enable='between(t,0,2)'" +
                "[${dateLabel}]"
            )

            $item | Add-Member `
                -MemberType NoteProperty `
                -Name "VideoLabel" `
                -Value $dateLabel `
                -Force
        }
        else {

            $item | Add-Member `
                -MemberType NoteProperty `
                -Name "VideoLabel" `
                -Value "v${i}" `
                -Force
        }

        # ====================================================
        # UPDATE LOCAL TIMELINE
        # ====================================================

        if ($i -lt ($batch.Count - 1)) {

            $localTime += [math]::Max(
                0.1,
                $item.Duration - $FadeSeconds
            )
        }
        else {

            $localTime += $item.Duration
        }
    }

    # ========================================================
    # DEBUG VIDEO LABELS
    # ========================================================

    Write-Host ""
    Write-Host "Video labels for batch ${batchNum}:" -ForegroundColor DarkYellow

    for (
        $debugIndex = 0;
        $debugIndex -lt $batch.Count;
        $debugIndex++
    ) {

        $debugItem = $batch[$debugIndex]

        Write-Host (
            "  [{0}] {1} -> [{2}]" -f `
            $debugIndex,
            $debugItem.Name,
            $debugItem.VideoLabel
        )
    }

    Write-Host ""

    # ========================================================
    # SILENT AUDIO TRACK
    # ========================================================

    $localTimeText = $localTime.ToString(
        "0.######",
        [Globalization.CultureInfo]::InvariantCulture
    )

    $audioFilters = @(
        (
            "anullsrc=r=48000:cl=stereo," +
            "atrim=0:${localTimeText}," +
            "asetpts=N/SR/TB" +
            "[bg_silence]"
        )
    ) + $audioFilters

    # ========================================================
    # MIX ORIGINAL AUDIO
    # ========================================================

    if ($audioInputCount -gt 1) {

        $mixInputString = $mixInputs -join ""

        $audioFilters += (
            $mixInputString +
            "amix=" +
            "inputs=${audioInputCount}:" +
            "duration=first:" +
            "dropout_transition=0:" +
            "normalize=0" +
            "[out_a]"
        )
    }
    else {

        $audioFilters += (
            "[bg_silence]" +
            "anull" +
            "[out_a]"
        )
    }

    # ========================================================
    # FILTER GRAPH STATUS
    # ========================================================

    Write-Host (
        "Generating FFmpeg filter graph for batch ${batchNum}/${totalBatches}..."
    )

    # ========================================================
    # SINGLE ITEM
    # ========================================================

    if ($batch.Count -eq 1) {

        $singleLabel = $batch[0].VideoLabel

        if ([string]::IsNullOrWhiteSpace($singleLabel)) {

            throw (
                "ERROR: Single video item has no VideoLabel: " +
                $batch[0].Name
            )
        }

        $filters += (
            "[${singleLabel}]" +
            "null" +
            "[out_v]"
        )
    }

    # ========================================================
    # MULTIPLE ITEMS - XFADES
    # ========================================================

    else {

        $currentVideoLabel = $batch[0].VideoLabel

        if ([string]::IsNullOrWhiteSpace($currentVideoLabel)) {

            throw (
                "ERROR: First video item has no VideoLabel: " +
                $batch[0].Name
            )
        }

        $cumulativeStart = $batch[0].Duration

        for (
            $idx = 1;
            $idx -lt $batch.Count;
            $idx++
        ) {

            $currentItem = $batch[$idx]

            $nextVideoLabel = $currentItem.VideoLabel

            if ([string]::IsNullOrWhiteSpace($nextVideoLabel)) {

                throw (
                    "ERROR: Video item $idx has no VideoLabel: " +
                    $currentItem.Name
                )
            }

            # ------------------------------------------------
            # XFADES
            # ------------------------------------------------

            $xfadeOffset = (
                $cumulativeStart - $FadeSeconds
            )

            if ($xfadeOffset -lt 0) {
                $xfadeOffset = 0
            }

            $offsetText = $xfadeOffset.ToString(
                "0.######",
                [Globalization.CultureInfo]::InvariantCulture
            )

            $xfadeOutput = "xf${idx}"

            if ($idx -eq ($batch.Count - 1)) {
                $xfadeOutput = "out_v"
            }

            $filters += (
                "[${currentVideoLabel}]" +
                "[${nextVideoLabel}]" +
                "xfade=" +
                "transition=fade:" +
                "duration=${FadeSeconds}:" +
                "offset=${offsetText}" +
                "[${xfadeOutput}]"
            )

            $currentVideoLabel = $xfadeOutput

            # ------------------------------------------------
            # UPDATE TIMELINE
            # ------------------------------------------------

            if ($idx -lt ($batch.Count - 1)) {

                $cumulativeStart += [math]::Max(
                    0.1,
                    $currentItem.Duration - $FadeSeconds
                )
            }
            else {

                $cumulativeStart += $currentItem.Duration
            }
        }
    }

    # ========================================================
    # COMBINE FILTER GRAPH
    # ========================================================

    $filterComplex = (
        $filters + $audioFilters
    ) -join ";"

    # ========================================================
    # SAVE DEBUG FILTER GRAPH
    # ========================================================

    $debugFilterFile = Join-Path `
        $Path `
        ("filter_batch_{0}.txt" -f $b)

    $filterComplex |
        Out-File `
            -FilePath $debugFilterFile `
            -Encoding utf8

    # ========================================================
    # FFMPEG FILTER GRAPH
    # ========================================================

    $ffmpegArgs += "-filter_complex"
    $ffmpegArgs += $filterComplex

    # ========================================================
    # VIDEO MAP
    # ========================================================

    $ffmpegArgs += "-map"
    $ffmpegArgs += "[out_v]"

    # ========================================================
    # AUDIO MAP
    # ========================================================

    $ffmpegArgs += "-map"
    $ffmpegArgs += "[out_a]"

    # ========================================================
    # VIDEO ENCODER
    # ========================================================

    $ffmpegArgs += "-c:v"
    $ffmpegArgs += "hevc_qsv"

    $ffmpegArgs += "-global_quality"
    $ffmpegArgs += "25"

    # ========================================================
    # AUDIO ENCODER
    # ========================================================

    $ffmpegArgs += "-c:a"
    $ffmpegArgs += "aac"

    $ffmpegArgs += "-b:a"
    $ffmpegArgs += "192k"

    # ========================================================
    # FRAME RATE
    # ========================================================

    $ffmpegArgs += "-r"
    $ffmpegArgs += $Fps

    # ========================================================
    # PIXEL FORMAT
    # ========================================================

    $ffmpegArgs += "-pix_fmt"
    $ffmpegArgs += "nv12"

    # ========================================================
    # OUTPUT
    # ========================================================

    $ffmpegArgs += "-y"
    $ffmpegArgs += $tempOut

    Write-Host ""

    # ========================================================
    # RUN FFMPEG
    # ========================================================

    & ffmpeg @ffmpegArgs

    if ($LASTEXITCODE -ne 0) {

        Write-Error (
            "FFmpeg failed while processing batch ${batchNum}."
        )

        Write-Host ""
        Write-Host "Filter graph saved to:" -ForegroundColor Yellow
        Write-Host $debugFilterFile -ForegroundColor Yellow
        Write-Host ""

        exit 1
    }

    # ========================================================
    # VERIFY BATCH
    # ========================================================

    if (-not (Test-Path $tempOut)) {

        Write-Error (
            "FFmpeg completed but did not create: $tempOut"
        )

        exit 1
    }

    Write-Host ""

    Write-Host (
        "Batch {0} completed successfully." -f $batchNum
    ) -ForegroundColor Green

    Write-Host ""
}

# ============================================================
# FINALIZATION
# ============================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "Joining batches and finalizing..." -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================
# CONCAT FILE
# ============================================================

$concatFile = Join-Path $Path "concat.txt"

$concatLines = @()

foreach ($batchOutput in $batchOutputs) {

    $escapedPath = $batchOutput.Replace(
        "'",
        "'\''"
    )

    $concatLines += (
        "file '$escapedPath'"
    )
}

$concatLines |
    Out-File `
        -FilePath $concatFile `
        -Encoding ascii

# ============================================================
# METADATA FILE
# ============================================================

$metadataFile = Join-Path $Path "metadata.txt"

$metadataText |
    Out-File `
        -FilePath $metadataFile `
        -Encoding ascii

# ============================================================
# FIND BACKGROUND MUSIC
# ============================================================

$audioPath = ""

foreach ($name in @(
    "music2.mp3",
    "music.mp3",
    "music2b.mp3"
)) {

    $p = Join-Path $Path $name

    if (Test-Path $p) {

        $audioPath = $p
        break
    }
}

# ============================================================
# MUSIC STATUS
# ============================================================

if ($audioPath -ne "") {

    Write-Host (
        "Background music found: {0}" -f $audioPath
    ) -ForegroundColor Green

    Write-Host "Normal music volume: 100%"
    Write-Host "Ducked music volume: 40%"
    Write-Host "Music fade-in/out: NONE"
}
else {

    Write-Host "No background music found." -ForegroundColor Yellow
}

# ============================================================
# FINAL FFMPEG ARGUMENTS
# ============================================================

$finalArgs = @(
    "-hide_banner",
    "-loglevel", "error",
    "-stats",

    "-f", "concat",
    "-safe", "0",
    "-i", $concatFile,

    "-i", $metadataFile
)

# ============================================================
# BACKGROUND MUSIC
# ============================================================

if ($audioPath -ne "") {

    $finalArgs += "-i"
    $finalArgs += $audioPath

    $durationText = $TotalDuration.ToString(
        "0.######",
        [Globalization.CultureInfo]::InvariantCulture
    )

    # --------------------------------------------------------
    # MUSIC DUCKING
    # --------------------------------------------------------

    $musicFilter =
        "[2:a]" +
        "atrim=0:${durationText}," +
        "asetpts=N/SR/TB," +
        "volume='${volumeExpr}':eval=frame" +
        "[music_ducked]"

    # --------------------------------------------------------
    # MIX ORIGINAL AUDIO + MUSIC
    # --------------------------------------------------------

    $finalAudioFilter =
        "[0:a]" +
        "[music_ducked]" +
        "amix=" +
        "inputs=2:" +
        "duration=first:" +
        "dropout_transition=0:" +
        "normalize=0" +
        "[final_a]"

    $finalFilterComplex =
        $musicFilter +
        ";" +
        $finalAudioFilter

    # --------------------------------------------------------
    # VIDEO
    # --------------------------------------------------------

    $finalArgs += "-map"
    $finalArgs += "0:v"

    # --------------------------------------------------------
    # AUDIO
    # --------------------------------------------------------

    $finalArgs += "-map"
    $finalArgs += "[final_a]"

    # --------------------------------------------------------
    # VIDEO COPY
    # --------------------------------------------------------

    $finalArgs += "-c:v"
    $finalArgs += "copy"

    # --------------------------------------------------------
    # AUDIO ENCODE
    # --------------------------------------------------------

    $finalArgs += "-c:a"
    $finalArgs += "aac"

    $finalArgs += "-b:a"
    $finalArgs += "192k"

    # --------------------------------------------------------
    # FILTER
    # --------------------------------------------------------

    $finalArgs += "-filter_complex"
    $finalArgs += $finalFilterComplex
}
else {

    Write-Warning `
        "No background music file found. Proceeding with video audio only."

    $finalArgs += "-map"
    $finalArgs += "0:v"

    $finalArgs += "-map"
    $finalArgs += "0:a?"

    $finalArgs += "-c"
    $finalArgs += "copy"
}

# ============================================================
# METADATA
# ============================================================

$finalArgs += "-map_metadata"
$finalArgs += "1"

# ============================================================
# OUTPUT
# ============================================================

$finalArgs += "-y"
$finalArgs += $OutputFile

# ============================================================
# FINALIZE
# ============================================================

Write-Host ""
Write-Host "Finalizing output..." -ForegroundColor Cyan
Write-Host ""

& ffmpeg @finalArgs

if ($LASTEXITCODE -ne 0) {

    Write-Error "Final FFmpeg operation failed."

    Write-Host ""
    Write-Host "Temporary batch files have NOT been deleted." -ForegroundColor Yellow
    Write-Host ""

    exit 1
}

# ============================================================
# VERIFY FINAL OUTPUT
# ============================================================

if (-not (Test-Path $OutputFile)) {

    Write-Error "Final output file was not created."
    exit 1
}

# ============================================================
# CLEANUP
# ============================================================

Write-Host ""
Write-Host "Cleaning up temporary files..." -ForegroundColor Cyan

Remove-Item `
    -Path $concatFile `
    -ErrorAction SilentlyContinue

Remove-Item `
    -Path $metadataFile `
    -ErrorAction SilentlyContinue

foreach ($batchOutput in $batchOutputs) {

    Remove-Item `
        -Path $batchOutput `
        -ErrorAction SilentlyContinue
}

for ($b = 0; $b -lt $batches.Count; $b++) {

    $debugFilterFile = Join-Path `
        $Path `
        ("filter_batch_{0}.txt" -f $b)

    Remove-Item `
        -Path $debugFilterFile `
        -ErrorAction SilentlyContinue
}

# ============================================================
# COMPLETE
# ============================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "                    COMPLETE" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""

Write-Host "Created: $OutputFile" -ForegroundColor Green

Write-Host (
    "Duration: {0:N2} seconds" -f $TotalDuration
)

Write-Host (
    "Resolution: {0}x{1}" -f $Width, $Height
)

Write-Host "Orientation: $orientationMode"
Write-Host "Input sorting: Filename timestamp ascending"
Write-Host "Filename timestamp format: YYYYMMDD_HHMMSS"
Write-Host "Video codec: Intel QSV HEVC"
Write-Host "Audio codec: AAC 192 kbps"

if ($audioPath -ne "") {

    Write-Host "Background music: $audioPath"
    Write-Host "Music volume: 100%"
    Write-Host "Music ducking: 40%"
    Write-Host "Music fades: None"
}

Write-Host "Chapters: $($chapters.Count)"
Write-Host ""
