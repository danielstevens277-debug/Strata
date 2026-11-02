@echo off
setlocal
for %%I in ("%~dp0..\..") do set "ROOT=%%~fI"
rem llama.cpp checkout used by the image encoder (override with STRATA_LLAMA_DIR)
if not defined STRATA_LLAMA_DIR set "STRATA_LLAMA_DIR=C:\llama.cpp"
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" (
    echo Visual Studio C++ build tools are required.
    exit /b 1
)
for /f "usebackq tokens=*" %%I in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VS=%%I"
if not defined VS (
    echo Install the Visual Studio Desktop development with C++ workload.
    exit /b 1
)
call "%VS%\VC\Auxiliary\Build\vcvars64.bat"
if errorlevel 1 exit /b 1
if not defined STRATA_ONEAPI_ROOT if exist "%LOCALAPPDATA%\Strata-tools\oneapi\Library\bin\icx.exe" set "STRATA_ONEAPI_ROOT=%LOCALAPPDATA%\Strata-tools\oneapi\Library"
if defined STRATA_ONEAPI_ROOT (
    set "PATH=%STRATA_ONEAPI_ROOT%\bin;%PATH%"
    set "INCLUDE=%STRATA_ONEAPI_ROOT%\include;%INCLUDE%"
    set "LIB=%STRATA_ONEAPI_ROOT%\lib;%LIB%"
    set "MKLROOT=%STRATA_ONEAPI_ROOT%"
) else (
    where icx >nul 2>nul
    if errorlevel 1 (
        if not defined ONEAPI_ROOT set "ONEAPI_ROOT=%ProgramFiles(x86)%\Intel\oneAPI"
        call "%%ONEAPI_ROOT%%\setvars.bat" intel64 vs2022
        if errorlevel 1 exit /b 1
    )
)
where icx >nul 2>nul
if errorlevel 1 (
    echo Intel oneAPI DPC++ and oneMKL are required. See docs\INTEL_ARC.md.
    exit /b 1
)

set "BUILD=%ROOT%\build-sycl-win"
set "LLAMA_FWD=%STRATA_LLAMA_DIR:\=/%"

echo.
echo ===== [1/3] strata.exe (SYCL engine) =====
cmake -S "%ROOT%\sycl" -B "%BUILD%" -G Ninja -DCMAKE_C_COMPILER=icx -DCMAKE_CXX_COMPILER=icx -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 %*
if errorlevel 1 exit /b 1
cmake --build "%BUILD%" --parallel 4
if errorlevel 1 exit /b 1

echo.
echo ===== [2/3] strata-vision.exe (CPU image encoder) =====
if not exist "%STRATA_LLAMA_DIR%\ggml\CMakeLists.txt" goto no_llama
rem MSVC (cl), as setup.py builds it; native for this CPU (STRATA_PORTABLE=OFF)
cmake -S "%ROOT%\tools\vision" -B "%ROOT%\build-vision" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=cl -DCMAKE_CXX_COMPILER=cl -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DLLAMA_DIR="%LLAMA_FWD%" -DSTRATA_VISION_CUDA=OFF -DSTRATA_PORTABLE=OFF
if errorlevel 1 exit /b 1
cmake --build "%ROOT%\build-vision" --target strata-vision --parallel 4
if errorlevel 1 exit /b 1
copy /y "%ROOT%\build-vision\bin\strata-vision.exe" "%BUILD%\" >nul
if errorlevel 1 exit /b 1

echo.
echo ===== [3/3] strata-vision-sycl.exe (Intel GPU image encoder, optional) =====
if /i not "%STRATA_VISION_SYCL%"=="1" (
    echo skipped: set STRATA_VISION_SYCL=1 to build it ^(untested on Windows^)
    goto done
)
cmake -S "%ROOT%\tools\vision" -B "%ROOT%\build-vision-sycl" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=icx -DCMAKE_CXX_COMPILER=icx -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DLLAMA_DIR="%LLAMA_FWD%" -DSTRATA_VISION_SYCL=ON -DSTRATA_PORTABLE=OFF
if errorlevel 1 exit /b 1
cmake --build "%ROOT%\build-vision-sycl" --target strata-vision --parallel 4
if errorlevel 1 exit /b 1
copy /y "%ROOT%\build-vision-sycl\bin\strata-vision-sycl.exe" "%BUILD%\" >nul
if errorlevel 1 exit /b 1
goto done

:no_llama
echo llama.cpp was not found at %STRATA_LLAMA_DIR% ^(no ggml\CMakeLists.txt^).
echo Set STRATA_LLAMA_DIR to the llama.cpp checkout and run this again.
exit /b 1

:done
echo.
echo Built in %BUILD%:
dir /b "%BUILD%\strata.exe" "%BUILD%\strata-vision*.exe"
exit /b 0
