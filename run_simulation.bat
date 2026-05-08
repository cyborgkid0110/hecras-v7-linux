@echo off
REM =============================================================================
REM run_simulation.bat — HEC-RAS v7.0 Windows end-to-end runner
REM
REM Usage:
REM   run_simulation.bat  <input.zip>  [output.zip]
REM
REM The input zip must contain a single HEC-RAS project folder, e.g.:
REM
REM   BEC.zip
REM   └── BEC\
REM       ├── BEC.g01
REM       ├── BEC.g01.hdf          ← mesh topology (RASMapper output)
REM       ├── BEC.p01              ← plan text file
REM       ├── BEC.b01              ← boundary conditions
REM       ├── BEC.x01              ← runtime cross-section index
REM       ├── BEC.u01.hdf          ← unsteady event conditions (optional)
REM       ├── Terrain\
REM       │   └── *.tif            ← DEM GeoTIFF
REM       └── Land Classification\
REM           ├── LandCover.hdf
REM           ├── *.tif
REM           └── Infiltration.hdf ← optional
REM
REM Output zip contains:
REM   <name>.g01.hdf   — geometry HDF with hydraulic tables
REM   <name>.p01.hdf   — simulation results
REM   <name>.bco01     — computation log
REM
REM Requirements:
REM   • Python 3 with numpy / scipy / h5py / gdal installed
REM   • Docker Desktop with image hecras-v70-amd64 built (see README)
REM   • 7-Zip or PowerShell 5+ (for zip/unzip)
REM =============================================================================

setlocal EnableDelayedExpansion

REM ---------------------------------------------------------------------------
REM Arguments
REM ---------------------------------------------------------------------------
if "%~1"=="" (
    echo Usage: %~nx0 ^<input.zip^> [output.zip] >&2
    exit /b 1
)

set "INPUT_ZIP=%~f1"

if "%~2"=="" (
    set "OUTPUT_ZIP=%~n1_results.zip"
) else (
    set "OUTPUT_ZIP=%~f2"
)
REM Resolve OUTPUT_ZIP to absolute path if it was defaulted
if "%~2"=="" (
    set "OUTPUT_ZIP=%CD%\!OUTPUT_ZIP!"
)

set "SCRIPT_DIR=%~dp0"
set "DOCKER_IMAGE=hecras-v70-amd64"
set "RAS_BIN=/opt/hecras/bin"
set "RAS_LIBS=/opt/hecras/libs:/opt/hecras/libs/rhel_8:/opt/hecras/libs/mkl"

echo =============================================
echo  HEC-RAS v7.0 Windows Simulation Runner
echo =============================================
echo  Input  : %INPUT_ZIP%
echo  Output : %OUTPUT_ZIP%
echo.

REM ---------------------------------------------------------------------------
REM 1. Pre-flight checks
REM ---------------------------------------------------------------------------
where python >nul 2>&1
if errorlevel 1 (
    echo ERROR: 'python' not found in PATH >&2
    exit /b 1
)

where docker >nul 2>&1
if errorlevel 1 (
    echo ERROR: 'docker' not found in PATH >&2
    exit /b 1
)

docker image inspect %DOCKER_IMAGE% >nul 2>&1
if errorlevel 1 (
    echo ERROR: Docker image '%DOCKER_IMAGE%' not found. >&2
    echo   Build it first:  docker build --platform linux/amd64 -t %DOCKER_IMAGE% . >&2
    exit /b 1
)

REM ---------------------------------------------------------------------------
REM 2. Extract input zip to a temp working directory
REM ---------------------------------------------------------------------------
set "WORKDIR=%TEMP%\hecras_%RANDOM%"
mkdir "%WORKDIR%" 2>nul
mkdir "%WORKDIR%\input" 2>nul

echo [1/4] Extracting %INPUT_ZIP% ...
powershell -NoProfile -Command "Expand-Archive -LiteralPath '%INPUT_ZIP%' -DestinationPath '%WORKDIR%\input' -Force"
if errorlevel 1 (
    echo ERROR: Failed to extract input zip. >&2
    goto :cleanup
)

REM Find the project directory: look for *.g01.hdf or *.g01
set "PROJECT_DIR="
for /r "%WORKDIR%\input" %%F in (*.g01.hdf *.g01) do (
    set "CANDIDATE=%%~dpF"
    REM Skip __MACOSX sidecar directories
    echo !CANDIDATE! | findstr /i "__MACOSX" >nul && continue
    if not defined PROJECT_DIR (
        REM Remove trailing backslash
        set "PROJECT_DIR=!CANDIDATE:~0,-1!"
    )
)

if not defined PROJECT_DIR (
    set "PROJECT_DIR=%WORKDIR%\input"
    echo WARNING: Could not find a .g01 / .g01.hdf file; using zip root as project dir.
)

echo     Project dir : %PROJECT_DIR%

REM ---------------------------------------------------------------------------
REM 3. Python preprocessing (Workflows A / B / C auto-detected)
REM ---------------------------------------------------------------------------
set "RUN_DIR=%WORKDIR%\run"
mkdir "%RUN_DIR%" 2>nul

set "CONDA_PATH="
for /f "tokens=*" %%i in ('where conda') do (
    if not defined CONDA_PATH set "CONDA_PATH=%%i"
)

if not exist "!CONDA_PATH!" (
    set "CONDA_PATH=conda"
)

echo [2/4] Running Python preprocessor ...
call "!CONDA_PATH!" run -n hecras python "%SCRIPT_DIR%ras_preprocess.py" "%PROJECT_DIR%" --output-dir "%RUN_DIR%"
if errorlevel 1 (
    echo ERROR: Python preprocessor failed. >&2
    goto :cleanup
)

REM Detect project name from generated g01.hdf
set "G01_HDF="
for %%F in ("%RUN_DIR%\*.g01.hdf") do (
    if not defined G01_HDF set "G01_HDF=%%F"
)

if not defined G01_HDF (
    echo ERROR: No .g01.hdf found in output directory after preprocessing. >&2
    goto :cleanup
)

REM Extract project name from filename (remove .g01.hdf suffix)
for %%F in ("%G01_HDF%") do set "PROJECT_NAME=%%~nF"
REM %%~nF gives e.g. "BEC.g01" — strip the .g01 part
set "PROJECT_NAME=%PROJECT_NAME:.g01=%"

echo     Project name : %PROJECT_NAME%

REM Copy boundary-condition files the solver needs (.b01 .x01)
for %%F in ("%PROJECT_DIR%\*.b01" "%PROJECT_DIR%\*.x01") do (
    if exist "%%F" copy /Y "%%F" "%RUN_DIR%\" >nul
)

REM ---------------------------------------------------------------------------
REM 4. Docker: RasGeomPreprocess - RasUnsteady
REM ---------------------------------------------------------------------------
set "TMP_HDF=%PROJECT_NAME%.p01.tmp.hdf"
set "RESULT_HDF=%PROJECT_NAME%.p01.hdf"

echo [3/4] Running Docker simulation (RasGeomPreprocess + RasUnsteady) ...

REM Convert Windows path to Docker-compatible mount path
set "DOCKER_RUN_DIR=%RUN_DIR:\=/%"

docker run --rm --platform linux/amd64 ^
    -v "%RUN_DIR%:/work" ^
    %DOCKER_IMAGE% ^
    bash -c "export PATH=%RAS_BIN%:$PATH && export LD_LIBRARY_PATH=%RAS_LIBS%:$LD_LIBRARY_PATH && cd /work && echo '  -> RasGeomPreprocess ...' && RasGeomPreprocess '%TMP_HDF%' x01 && echo '  -> RasUnsteady ...' && RasUnsteady '%TMP_HDF%' x01 && mv '%TMP_HDF%' '%RESULT_HDF%' && echo '  -> Simulation complete.'"

if errorlevel 1 (
    echo ERROR: Docker simulation failed. >&2
    goto :cleanup
)

REM ---------------------------------------------------------------------------
REM 5. Package output
REM ---------------------------------------------------------------------------
echo [4/4] Packaging results into %OUTPUT_ZIP% ...

pushd "%RUN_DIR%"
set "FILE_COUNT=0"
set "OUTPUT_FILES="

REM Build a comma-separated list for PowerShell
for %%F in (*.g01.hdf *.p01.hdf *.bco01 *.ic.o01 *.hyd.o01) do (
    if exist "%%F" (
        set /a FILE_COUNT+=1
        if "!OUTPUT_FILES!"=="" (
            set "OUTPUT_FILES='%%F'"
        ) else (
            set "OUTPUT_FILES=!OUTPUT_FILES!,'%%F'"
        )
    )
)

if %FILE_COUNT% equ 0 (
    popd
    echo ERROR: No output files found to package. >&2
    goto :cleanup
)

REM Remove old output zip if it exists
if exist "%OUTPUT_ZIP%" del /f "%OUTPUT_ZIP%"

REM Create zip using PowerShell with the corrected comma-separated list
powershell -NoProfile -Command "Compress-Archive -Path !OUTPUT_FILES! -DestinationPath '%OUTPUT_ZIP%' -Force"
popd

if errorlevel 1 (
    echo ERROR: Failed to create output zip. >&2
    goto :cleanup
)

echo.
echo =============================================
echo  Done!
echo  Results : %OUTPUT_ZIP%
echo  Contents:
powershell -NoProfile -Command "Add-Type -AssemblyName System.IO.Compression.FileSystem; $z=[System.IO.Compression.ZipFile]::OpenRead('%OUTPUT_ZIP%'); $z.Entries | ForEach-Object { Write-Host ('   {0,-40} ({1} bytes)' -f $_.Name, $_.Length) }; $z.Dispose()"
echo =============================================

:cleanup
REM Clean up temp directory
if exist "%WORKDIR%" (
    rmdir /s /q "%WORKDIR%" 2>nul
)

endlocal
exit /b 0
