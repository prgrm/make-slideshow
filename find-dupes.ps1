# Step 1: Scan current directory and list discovery stats
Write-Host "Scanning current directory for files..." -ForegroundColor Cyan
$allFiles = Get-ChildItem -File
$totalFiles = $allFiles.Count

if ($totalFiles -eq 0) {
    Write-Host "No files found in the current directory." -ForegroundColor Yellow
    exit
}

Write-Host "Found $totalFiles file(s) in total.`n" -ForegroundColor Green

# Step 2: Pre-filter by file size
Write-Host "Grouping files by size to identify potential duplicates..." -ForegroundColor Cyan
$sizeGroups = $allFiles | Group-Object Length | Where-Object { $_.Count -gt 1 }

if (-not $sizeGroups) {
    Write-Host "No files with matching sizes found. All file sizes are unique." -ForegroundColor Green
    exit
}

$candidateFiles = $sizeGroups | Select-Object -ExpandProperty Group
Write-Host "Found $($sizeGroups.Count) size group(s) containing $($candidateFiles.Count) candidate files:`n" -ForegroundColor Yellow

# Detailed breakdown of size collisions before hashing
foreach ($sGroup in $sizeGroups) {
    $sizeFormatted = "$([math]::Round($sGroup.Name / 1KB, 2)) KB ($($sGroup.Name) bytes)"
    Write-Host "  Size Match: $sizeFormatted ($($sGroup.Count) files)" -ForegroundColor Gray
    foreach ($f in $sGroup.Group) {
        Write-Host "    - $($f.Name)" -ForegroundColor DarkGray
    }
}
Write-Host ""

# Step 3: Compute MD5 Hashes with live, file-by-file feedback
Write-Host "Computing MD5 hashes for candidate files..." -ForegroundColor Cyan
$hashedFiles = @()
$counter = 0

foreach ($file in $candidateFiles) {
    $counter++
    $sizeKB = [math]::Round($file.Length / 1KB, 2)
    Write-Host "[$counter/$($candidateFiles.Count)] Hashing MD5: $($file.Name) ($sizeKB KB)... " -ForegroundColor DarkGray -NoNewline
    
    $hashResult = Get-FileHash -LiteralPath $file.FullName -Algorithm MD5
    $hashedFiles += [PSCustomObject]@{
        Path = $file.FullName
        Hash = $hashResult.Hash
    }
    
    Write-Host "[DONE]" -ForegroundColor Green
}
Write-Host ""

# Step 4: Group by Hash
$duplicateGroups = $hashedFiles | 
    Group-Object Hash | 
    Where-Object { $_.Count -gt 1 }

if (-not $duplicateGroups) {
    Write-Host "No exact MD5 content duplicates found after hashing." -ForegroundColor Green
    exit
}

Write-Host "Analysis complete! Found $($duplicateGroups.Count) group(s) of exact MD5 duplicates.`n" -ForegroundColor Yellow

# Step 5: Process duplicate groups interactively
foreach ($group in $duplicateGroups) {
    $hash = $group.Name
    # Retrieve FileInfo objects and sort by modification date descending (newest first)
    $files = $group.Group | 
        ForEach-Object { Get-Item -LiteralPath $_.Path } | 
        Sort-Object LastWriteTime -Descending
    
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "MD5 Hash : $hash" -ForegroundColor Cyan
    Write-Host "Duplicates: $($files.Count) files" -ForegroundColor Cyan
    Write-Host "==================================================" -ForegroundColor Cyan
    
    for ($i = 0; $i -lt $files.Count; $i++) {
        $tag = if ($i -eq 0) { " (NEWEST - DEFAULT)" } else { "" }
        Write-Host "[$($i + 1)]$tag $($files[$i].Name)"
        Write-Host "    Size: $([math]::Round($files[$i].Length / 1KB, 2)) KB | Modified: $($files[$i].LastWriteTime)" -ForegroundColor Gray
    }
    Write-Host "[0] Keep ALL files (Skip this group)" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------"
    
    # User input validation loop with Enter-key default support
    $choice = $null
    while ($null -eq $choice) {
        $inputVal = Read-Host "Enter file number to KEEP [Press Enter for 1 (Newest)]"
        
        if ([string]::IsNullOrWhiteSpace($inputVal)) {
            $choice = 1  # Default to newest
        } elseif ($inputVal -match '^\d+$') {
            $parsed = [int]$inputVal
            if ($parsed -ge 0 -and $parsed -le $files.Count) {
                $choice = $parsed
            } else {
                Write-Host "Invalid entry. Enter a number between 0 and $($files.Count)." -ForegroundColor Red
            }
        } else {
            Write-Host "Invalid entry. Please enter a valid number." -ForegroundColor Red
        }
    }

    if ($choice -eq 0) {
        Write-Host "Skipped group $hash. No files deleted.`n" -ForegroundColor Yellow
        continue
    }

    $fileToKeep = $files[$choice - 1]
    Write-Host "Keeping: $($fileToKeep.Name)" -ForegroundColor Green

    # Delete unselected duplicates with real-time feedback
    foreach ($file in $files) {
        if ($file.FullName -ne $fileToKeep.FullName) {
            Write-Host "Deleting: $($file.Name)... " -ForegroundColor Red -NoNewline
            Remove-Item -LiteralPath $file.FullName -Force
            Write-Host "[DELETED]" -ForegroundColor Red
        }
    }
    Write-Host ""
}

Write-Host "Duplicate cleanup complete!" -ForegroundColor Green
