<#
.SYNOPSIS
    PowerShell equivalent of "make clean" and "make lions" for lions-book project.
    Works on Windows even if "make" or "uv" are not in PATH.

.USAGE
    .\build.ps1 clean
    .\build.ps1 lions
    .\build.ps1          # same as lions
#>

param(
    [Parameter(Position=0)]
    [ValidateSet("clean", "lions")]
    [string]$Target = "lions"
)

# Force some output immediately so we never have a completely silent run
Write-Host "[lions-book] build.ps1 starting..." -ForegroundColor DarkGray

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
if (-not $root) { $root = (Get-Location).Path }

$lionsDir = Join-Path $root "lionc"
$lionstexDir = Join-Path $root "lionstex"
$scriptDir = Join-Path $root "scripts"
$postProcessScript = Join-Path $scriptDir "fix-line-refs.py"

# --- Locate best Python ---
$python = $null
$pyCandidates = @("python", "python3", "py")
foreach ($cand in $pyCandidates) {
    $cmd = Get-Command $cand -ErrorAction SilentlyContinue
    if ($cmd) {
        $python = $cmd.Source
        break
    }
}
if (-not $python) {
    # Try common Windows install locations (wildcard)
    $patterns = @(
        "$env:LOCALAPPDATA\Programs\Python\Python*\python.exe",
        "$env:ProgramFiles\Python*\python.exe",
        "$env:ProgramFiles(x86)\Python*\python.exe"
    )
    foreach ($pat in $patterns) {
        $hit = Get-Item $pat -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { $python = $hit.FullName; break }
    }
}
if (-not $python -or -not (Test-Path $python)) {
    Write-Host ""
    Write-Host ">>> BRAK PYTHONA <<<" -ForegroundColor Red
    Write-Host "Nie znaleziono python / py / python3 w PATH ani w standardowych lokalizacjach." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Zainstaluj Python 3.9+ ze strony https://www.python.org/downloads/" -ForegroundColor Cyan
    Write-Host "Podczas instalacji zaznacz 'Add python.exe to PATH'." -ForegroundColor White
    Write-Host "Po instalacji zamknij calkowicie ten terminal i otworz go ponownie." -ForegroundColor White
    Write-Host ""
    Write-Error "Python not found."
    exit 1
}
try {
    $pythonVersion = & $python --version 2>&1
    Write-Host "Using Python: $pythonVersion" -ForegroundColor DarkGray
} catch {
    Write-Error "Failed to query Python version at: $python"
    exit 1
}

# --- Locate uv (preferred) ---
$uv = $null

# 1. Standard "uv" in PATH (official installer, cargo, etc.)
$cmd = Get-Command uv -ErrorAction SilentlyContinue
if ($cmd) { $uv = $cmd.Source }

# 2. Common standalone installer and cargo locations
if (-not $uv) {
    $uvCandidates = @(
        "$env:LOCALAPPDATA\Programs\uv\uv.exe",
        "$env:USERPROFILE\.cargo\bin\uv.exe",
        "$env:USERPROFILE\.local\bin\uv.exe",
        "$env:APPDATA\uv\uv.exe",
        "$env:LOCALAPPDATA\uv\uv.exe"
    )
    foreach ($cand in $uvCandidates) {
        if (Test-Path $cand) {
            $uv = $cand
            break
        }
    }
}

# 3. uv.exe installed via pip in the same Python we selected for the project (very common)
if (-not $uv -and $python) {
    try {
        $scriptsDir = & $python -c "import sysconfig; print(sysconfig.get_path('scripts'))" 2>&1
        if ($LASTEXITCODE -eq 0 -and $scriptsDir) {
            $scriptsDir = ($scriptsDir | Out-String).Trim()
            $cand = Join-Path $scriptsDir "uv.exe"
            if (Test-Path $cand) { $uv = $cand }
        }
    } catch {}
}

# 4. Broad search in all common Python installations (mirrors the plastex search)
if (-not $uv) {
    $searchRoots = @(
        "$env:APPDATA\Python",
        "$env:LOCALAPPDATA\Programs\Python",
        "$env:APPDATA\Roaming\Python",
        "$env:USERPROFILE\AppData\Roaming\Python",
        "$env:USERPROFILE\AppData\Local\Programs\Python"
    )
    foreach ($root in $searchRoots) {
        if (Test-Path $root) {
            $found = Get-ChildItem $root -Recurse -Filter "uv.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) {
                $uv = $found.FullName
                break
            }
        }
    }
}

# Validate that the found uv actually works
if ($uv) {
    try {
        $ver = & $uv --version 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Found uv at: $uv  ($ver)" -ForegroundColor DarkGray
        } else {
            Write-Host "Found candidate uv at $uv but it did not respond to --version. Ignoring." -ForegroundColor Yellow
            $uv = $null
        }
    } catch {
        Write-Host "Found candidate uv at $uv but failed to execute it. Ignoring." -ForegroundColor Yellow
        $uv = $null
    }
}

# 5. Ultimate fallback: uv installed as a module for our chosen Python (python -m uv)
#    This works even if uv.exe is not on PATH or not discovered above.
if (-not $uv -and $python) {
    try {
        $null = & $python -m uv --version 2>&1
        if ($LASTEXITCODE -eq 0) {
            $uv = "__python_m_uv__"   # special sentinel value
            Write-Host "Found uv as Python module for $python (will use 'python -m uv run')" -ForegroundColor DarkGray
        }
    } catch {}
}

# --- Locate plastex (for no-uv fallback). Derive from the chosen Python when possible. ---
$plastexExe = $null
try {
    $scriptsDir = & $python -c "import sysconfig; print(sysconfig.get_path('scripts'))" 2>&1
    if ($LASTEXITCODE -eq 0 -and $scriptsDir) {
        $scriptsDir = ($scriptsDir | Out-String).Trim()
        $cand = Join-Path $scriptsDir "plastex.exe"
        if (Test-Path $cand) { $plastexExe = $cand }
    }
} catch {}
if (-not $plastexExe) {
    # fallback 1: plastex in PATH
    $cmd = Get-Command plastex -ErrorAction SilentlyContinue
    if ($cmd) { $plastexExe = $cmd.Source }
}
if (-not $plastexExe) {
    # fallback 2: search common alternative Python "Scripts" locations
    $searchRoots = @(
        "$env:APPDATA\Python",
        "$env:LOCALAPPDATA\Programs\Python",
        "$env:APPDATA\Roaming\Python",
        "$env:USERPROFILE\AppData\Roaming\Python",
        "$env:USERPROFILE\AppData\Local\Programs\Python"
    )
    foreach ($r in $searchRoots) {
        if (Test-Path $r) {
            $found = Get-ChildItem $r -Recurse -Filter "plastex.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { $plastexExe = $found.FullName; break }
        }
    }
}

function Invoke-Clean {
    Write-Host "==> Cleaning (lionc/)" -ForegroundColor Cyan
    & $python -c "import shutil; shutil.rmtree(r'$lionsDir', ignore_errors=True)"
    Write-Host "lionc/ removed." -ForegroundColor Green
}

function Invoke-Lions {
    Invoke-Clean

    # Early check: plastex requires kpsewhich from a TeX distribution.
    $kpseCmd = Get-Command kpsewhich -ErrorAction SilentlyContinue
    if (-not $kpseCmd) {
        Write-Host ""
        Write-Host ">>> BRAK NARZEDZI TeX (kpsewhich) <<<" -ForegroundColor Red
        Write-Host "plastex potrzebuje dystrybucji TeX-a do znajdowania plikow (lionc.tex + \include)." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Rozwiazanie na Windows (najlatwiejsze):" -ForegroundColor Cyan
        Write-Host "  1. Pobierz MiKTeX: https://miktex.org/download" -ForegroundColor White
        Write-Host "  2. Zainstaluj (Basic Installer lub Full)." -ForegroundColor White
        Write-Host "  3. Podczas instalacji ZAZNACZ opcje dodania do PATH." -ForegroundColor White
        Write-Host "  4. **Zamknij calkowicie PowerShell** i otworz go ponownie." -ForegroundColor White
        Write-Host "  5. Sprawdź: kpsewhich --version" -ForegroundColor White
        Write-Host "  6. Uruchom ponownie:  .\\build.ps1" -ForegroundColor White
        Write-Host ""
        Write-Host "Alternatywa: TeX Live (wiekszy, ale standardowy): https://tug.org/texlive/" -ForegroundColor DarkGray
        Write-Host ""
        exit 1
    }

    # Check for image rasterization tools (pdftoppm + Ghostscript).
    # These are needed for \begin{picture} (figures in ch23) and some \begin{tabbing}.
    $imgTools = @()
    $pdftoppm = Get-Command pdftoppm -ErrorAction SilentlyContinue
    if ($pdftoppm) { $imgTools += "pdftoppm" }
    $gs = Get-Command gswin64c -ErrorAction SilentlyContinue
    if (-not $gs) { $gs = Get-Command gswin32c -ErrorAction SilentlyContinue }
    if (-not $gs) { $gs = Get-Command gs -ErrorAction SilentlyContinue }
    if ($gs) { $imgTools += "ghostscript" }

    $hasImageTools = ($imgTools.Count -ge 1)

    if (-not $hasImageTools) {
        Write-Host ""
        Write-Host ">>> BRAK NARZEDZI DO OBRAZOW (pdftoppm / Ghostscript) <<<" -ForegroundColor Red
        Write-Host "plastex potrzebuje pdftoppm (z MiKTeX) i/lub Ghostscript, zeby wygenerowac PNG/SVG." -ForegroundColor Yellow
        Write-Host "Bez nich w lionc/images/ beda puste obrazki dla rysunkow (figury 23.1-23.4 itd.)." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Na Windows z MiKTeX:" -ForegroundColor Cyan
        Write-Host "  - pdftoppm jest zwykle dostepny razem z MiKTeX." -ForegroundColor White
        Write-Host "  - Zainstaluj Ghostscript z https://ghostscript.com/releases/gsdnld.html" -ForegroundColor White
        Write-Host "  - Po instalacji **zamknij calkowicie wszystkie okna PowerShell** i otworz nowe." -ForegroundColor White
        Write-Host "  - Sprawdź w nowym oknie: pdftoppm -v   oraz   gswin64c -v" -ForegroundColor White
        Write-Host ""
    } else {
        Write-Host "Image tools found: $($imgTools -join ', ')" -ForegroundColor DarkGray
    }

    # --- Prepare a robust PATH for the plastex child process (critical for images on Windows) ---
    $oldPath = $env:PATH
    $extraPath = @()
    $gsShimDir = $null

    # Ghostscript (gswin64c). Also synthesize gswin32c.exe shim because plastex / dvisvgm / internal GS calls often look for the 32-bit name first.
    $gsCmd = Get-Command gswin64c -ErrorAction SilentlyContinue
    if (-not $gsCmd) { $gsCmd = Get-Command gswin32c -ErrorAction SilentlyContinue }
    if (-not $gsCmd) { $gsCmd = Get-Command gs -ErrorAction SilentlyContinue }
    if ($gsCmd) {
        $gsBin = Split-Path $gsCmd.Source -Parent
        $extraPath += $gsBin
        try {
            $gsShimDir = Join-Path $env:TEMP ("lionsbook-gs-shim-" + [IO.Path]::GetRandomFileName())
            New-Item -ItemType Directory -Path $gsShimDir -Force | Out-Null | Out-Null
            $shim32 = Join-Path $gsShimDir "gswin32c.exe"
            $ok = $false
            try {
                cmd /c "mklink /H `"$shim32`" `"$($gsCmd.Source)`"" 2>$null | Out-Null
                if (Test-Path $shim32) { $ok = $true }
            } catch {}
            if (-not $ok) {
                Copy-Item $gsCmd.Source $shim32 -Force -ErrorAction SilentlyContinue
                if (Test-Path $shim32) { $ok = $true }
            }
            if ($ok) { $extraPath += $gsShimDir }
        } catch {}
    }

    # MiKTeX bin (pdftoppm + kpsewhich live here)
    if ($kpseCmd -and $kpseCmd.Source) {
        $mbin = Split-Path $kpseCmd.Source -Parent
        $extraPath += $mbin
        # Poppler that sometimes lives next to MiKTeX or in WinGet
        $pop = Join-Path (Split-Path $mbin -Parent) "poppler\bin"
        if (Test-Path $pop) { $extraPath += $pop }
    }

    # The Scripts dir of the plastex.exe we will invoke (helps finding related tools)
    if ($plastexExe) {
        $extraPath += (Split-Path $plastexExe -Parent)
    }

    if ($extraPath.Count -gt 0) {
        $extraPath = $extraPath | Select-Object -Unique
        $env:PATH = ($extraPath -join ';') + ';' + $oldPath
        Write-Host ("Augmented PATH for imagers: " + ($extraPath -join '; ')) -ForegroundColor DarkGray
    }

    # Optional: quiet MiKTeX fndb update
    try {
        $kpseWhichPath = $kpseCmd.Source
        if ($kpseWhichPath) {
            $miktexBin = Split-Path $kpseWhichPath
            $initex = Join-Path $miktexBin "initexmf.exe"
            if (Test-Path $initex) {
                & $initex --update-fndb --quiet 2>$null | Out-Null
            }
        }
    } catch {}

    Write-Host "==> Building HTML with plastex..." -ForegroundColor Cyan

    $plastexSuccess = $false
    $buildOutput = $null

    if ($uv) {
        if ($uv -eq "__python_m_uv__") {
            Write-Host "Using uv via: $python -m uv" -ForegroundColor DarkGray
            $uvExe = $python
            $uvPrefix = @("-m", "uv")
        } else {
            Write-Host "Using uv at: $uv" -ForegroundColor DarkGray
            $uvExe = $uv
            $uvPrefix = @()
        }

        # Run from the project root with explicit --project so uv always finds pyproject.toml + uv.lock
        $oldEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            # Direct call (no cmd.exe /c wrapper)
            $buildOutput = & $uvExe @uvPrefix run --project $root -- plastex -c "$lionstexDir\plastex.ini" --imager=dvisvgm --vector-imager=dvisvgm --image-resolution=120 -d "$lionsDir" "$lionstexDir\lionc.tex" 2>&1
            if ($LASTEXITCODE -eq 0) { $plastexSuccess = $true }
            if ($buildOutput) { $buildOutput | Out-String | Write-Host }
        } finally {
            $ErrorActionPreference = $oldEap
        }
    }

    if (-not $plastexSuccess -and $plastexExe) {
        if ($uv) {
            Write-Host "uv was located but the 'uv run plastex' command did not succeed (non-zero exit). Falling back to direct plastex.exe..." -ForegroundColor Yellow
        } else {
            Write-Host "uv not found (not in PATH and not in common install locations). Falling back to direct plastex.exe..." -ForegroundColor Yellow
            Write-Host "Tip: Install uv from https://docs.astral.sh/uv/ (recommended) or with 'pip install uv' using the Python shown above." -ForegroundColor DarkGray
        }
        Write-Host "Using: $plastexExe" -ForegroundColor DarkGray

        Push-Location $lionstexDir
        try {
            $oldEap = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                # Direct call — avoids extra cmd.exe layer that was causing temp PDF path mangling for pdftoppm inside plastex.
                # Force dvisvgm/pdftoppm imagers + resolution.
                $buildOutput = & $plastexExe -c plastex.ini --imager=dvisvgm --vector-imager=dvisvgm --image-resolution=120 -d ../lionc lionc.tex 2>&1
                if ($LASTEXITCODE -eq 0) { $plastexSuccess = $true }
                if ($buildOutput) { $buildOutput | Out-String | Write-Host }
            } finally {
                $ErrorActionPreference = $oldEap
            }
        } finally {
            Pop-Location
        }
    }

    # Always restore the original PATH and clean up any gswin32c shim we created
    if ($gsShimDir -and (Test-Path $gsShimDir)) {
        Remove-Item $gsShimDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    $env:PATH = $oldPath

    $producedHtml = $false
    if (Test-Path $lionsDir -PathType Container) {
        $htmlFiles = Get-ChildItem $lionsDir -Filter "*.html" -ErrorAction SilentlyContinue
        if ($htmlFiles) { $producedHtml = $true }
    }

    # Post-build verification for images/
    $imagesDir = Join-Path $lionsDir "images"
    $expectedImages = 0
    $actualImages = 0
    $hasImageRefs = $false

    if ($producedHtml) {
        $allHtmlContent = Get-ChildItem $lionsDir -Filter "*.html" -ErrorAction SilentlyContinue |
            Get-Content -Raw -ErrorAction SilentlyContinue | Out-String
        $expectedImages = ([regex]::Matches($allHtmlContent, 'images/img-\d+\.(png|svg)')).Count
        if ($expectedImages -gt 0) { $hasImageRefs = $true }

        if (Test-Path $imagesDir -PathType Container) {
            $actualPng = @(Get-ChildItem $imagesDir -Filter "*.png" -ErrorAction SilentlyContinue).Count
            $actualSvg = @(Get-ChildItem $imagesDir -Filter "*.svg" -ErrorAction SilentlyContinue).Count
            $actualImages = $actualPng + $actualSvg
        }
    }

    if (-not $plastexSuccess) {
        Write-Host ""
        Write-Host "plastex generation reported failure (exit code != 0)." -ForegroundColor Yellow

        $fullOutput = if ($buildOutput) { ($buildOutput | Out-String) } else { "" }
        $looksLikeMissingKpse = $fullOutput -match 'kpsewhich.*(not recognized|not found|is not recognized|command not found)'

        if ($looksLikeMissingKpse) {
            Write-Host "It looks like kpsewhich could not be found. See installation instructions above." -ForegroundColor Red
            exit 1
        }

        if ($producedHtml) {
            Write-Host "However, HTML output was produced (image conversion or other non-fatal issues may have occurred)." -ForegroundColor Green
        } else {
            Write-Host "Possible reasons for failure:"
            Write-Host "  - Problems during image conversion (missing pdftoppm / Ghostscript)."
            Write-Host "  - Other LaTeX / plastex errors (see output above)."
            Write-Host "  - uv not installed (the uv path was attempted first)."
            Write-Host ""
            Write-Host "You can still try running the post-processor manually if any HTML exists:"
            Write-Host "  & $python $postProcessScript --input-dir $lionsDir"
            exit 1
        }
    }

    if ($producedHtml) {
        Write-Host "==> Post-processing line references..." -ForegroundColor Cyan
        & $python $postProcessScript --input-dir $lionsDir

        Write-Host ""
        if ($hasImageRefs) {
            if ($actualImages -gt 0) {
                Write-Host "Build complete! ($actualImages image file(s) generated)" -ForegroundColor Green
            } else {
                Write-Host "Build complete, ALE BRAKUJE OBRAZOW!" -ForegroundColor Yellow
                Write-Host ""
                Write-Host "  Oczekiwano obrazow: $expectedImages" -ForegroundColor Yellow
                Write-Host "  Znaleziono w lionc/images/: $actualImages" -ForegroundColor Red
                Write-Host ""
                Write-Host "  Komenda 'ls lionc/images' (lub 'dir lionc\images') zwraca nic." -ForegroundColor DarkGray
                Write-Host ""
                Write-Host "  Najczestsza przyczyna: brak pdftoppm / Ghostscript widocznych dla plastex." -ForegroundColor Cyan
                Write-Host "  (Nawet jesli kpsewhich dziala, konwertery obrazow sa potrzebne osobno.)" -ForegroundColor Cyan
                Write-Host ""
                Write-Host "  Co zrobic:" -ForegroundColor White
                Write-Host "    1. Zainstaluj/uzupelnij Ghostscript (gswin64c)." -ForegroundColor White
                Write-Host "    2. Zamknij WSZYSTKIE okna PowerShell / terminale." -ForegroundColor White
                Write-Host "    3. Otworz nowe okno i uruchom ponownie:  .\\build.ps1" -ForegroundColor White
                Write-Host ""
                Write-Host "  Bez obrazow rysunki (szczegolnie figury z rozdz. 23) beda puste lub zepsute." -ForegroundColor DarkGray
            }
        } else {
            Write-Host "Build complete!" -ForegroundColor Green
        }
        Write-Host "Open viewer.html or index.html (or lionc/index.html) in your browser." -ForegroundColor Green
    } else {
        Write-Host "No HTML output was generated." -ForegroundColor Red
        exit 1
    }
}

switch ($Target) {
    "clean" { Invoke-Clean }
    "lions" { Invoke-Lions }
    default { Invoke-Lions }
}
