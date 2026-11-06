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
echo ===== [0/4] Level Zero SDK (level_zero/ze_api.h + ze_loader.lib) =====
rem The driver ships C:\Windows\System32\ze_loader.dll - the runtime only.  The headers and the import library come
rem from sycl\tools\build_level_zero.bat (the 2026 Base Toolkit has no Level Zero component).  Without them CMake
rem leaves STRATA_HAVE_ZE undefined and host_malloc_polled falls back to sycl::malloc_host, so the build still
rem works - this step warns instead of failing, unlike the compiler checks above.  It is a subroutine because the
rem path has to be resolved before the `set` that uses it: inside one ( ) block everything is expanded on entry.
call :level_zero

echo.
echo ===== [1/4] strata.exe (SYCL engine) =====
cmake -S "%ROOT%\sycl" -B "%BUILD%" -G Ninja -DCMAKE_C_COMPILER=icx -DCMAKE_CXX_COMPILER=icx -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 %_ZE_ARGS% %*
if errorlevel 1 exit /b 1
cmake --build "%BUILD%" --parallel 4
if errorlevel 1 exit /b 1

echo.
echo ===== [2/4] strata-vision.exe (CPU image encoder) =====
if not exist "%STRATA_LLAMA_DIR%\ggml\CMakeLists.txt" goto no_llama
rem MSVC (cl), as setup.py builds it; native for this CPU (STRATA_PORTABLE=OFF)
cmake -S "%ROOT%\tools\vision" -B "%ROOT%\build-vision" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=cl -DCMAKE_CXX_COMPILER=cl -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DLLAMA_DIR="%LLAMA_FWD%" -DSTRATA_VISION_CUDA=OFF -DSTRATA_PORTABLE=OFF
if errorlevel 1 exit /b 1
cmake --build "%ROOT%\build-vision" --target strata-vision --parallel 4
if errorlevel 1 exit /b 1
copy /y "%ROOT%\build-vision\bin\strata-vision.exe" "%BUILD%\" >nul
if errorlevel 1 exit /b 1

echo.
echo ===== [3/4] strata-vision-sycl.exe (Intel GPU image encoder, optional) =====
if /i not "%STRATA_VISION_SYCL%"=="1" (
    echo skipped: set STRATA_VISION_SYCL=1 to build it ^(untested on Windows^)
    goto after_vision_sycl
)
cmake -S "%ROOT%\tools\vision" -B "%ROOT%\build-vision-sycl" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=icx -DCMAKE_CXX_COMPILER=icx -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DLLAMA_DIR="%LLAMA_FWD%" -DSTRATA_VISION_SYCL=ON -DSTRATA_PORTABLE=OFF
if errorlevel 1 exit /b 1
cmake --build "%ROOT%\build-vision-sycl" --target strata-vision --parallel 4
if errorlevel 1 exit /b 1
copy /y "%ROOT%\build-vision-sycl\bin\strata-vision-sycl.exe" "%BUILD%\" >nul
if errorlevel 1 exit /b 1
goto after_vision_sycl

:after_vision_sycl
echo.
echo ===== [4/4] ctest =====
echo   -DIQ_FIXTURE_PYTHON=<python>   interpreter that generates the iq_parity fixtures ^(needs numpy and PyYAML^)
echo   -DSTRATA_PLE_GGUF=<folder^|shard> any GGUF holding the PLE table for ple_parity ^(found by tensor name^)
echo   the same two are read at configure time; ple_parity is not registered without pack\full and bench\micro
echo   set STRATA_RUN_TESTS=1 to run the suite here ^(needs the configured fixtures; ~4 min^)
if /i not "%STRATA_RUN_TESTS%"=="1" (
    echo skipped
    goto done
)
pushd "%BUILD%"
ctest --output-on-failure
set "_CT=%errorlevel%"
popd
if not "%_CT%"=="0" exit /b %_CT%
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

:level_zero
set "_ZE_ARGS="
set "_ZE_CACHED="
if exist "%BUILD%\CMakeCache.txt" (
    findstr /c:"STRATA_ZE_LOADER:FILEPATH=" "%BUILD%\CMakeCache.txt" | findstr /v /c:"NOTFOUND" >nul
    if not errorlevel 1 set "_ZE_CACHED=1"
)
if defined _ZE_CACHED (
    echo cached: %BUILD% already has STRATA_ZE_LOADER
    exit /b 0
)
if not defined STRATA_LEVEL_ZERO_PREFIX set "STRATA_LEVEL_ZERO_PREFIX=C:\Strata-tools\level-zero-install"
if not exist "%STRATA_LEVEL_ZERO_PREFIX%\include\level_zero\ze_api.h" (
    echo no SDK in %STRATA_LEVEL_ZERO_PREFIX% - building it once ^(needs Visual Studio and network^)
    call "%ROOT%\sycl\tools\build_level_zero.bat"
)
if not exist "%STRATA_LEVEL_ZERO_PREFIX%\include\level_zero\ze_api.h" (
    echo WARNING: no Level Zero SDK - the engine gets the sycl::malloc_host host-buffer path only.
    echo          Run sycl\tools\build_level_zero.bat, then configure again to enable the uncached one.
    exit /b 0
)
set "_ZE_ARGS=-DSTRATA_ZE_INCLUDE_DIR:PATH=^"%STRATA_LEVEL_ZERO_PREFIX%\include^" -DSTRATA_ZE_LOADER:FILEPATH=^"%STRATA_LEVEL_ZERO_PREFIX%\lib\ze_loader.lib^""
echo using %STRATA_LEVEL_ZERO_PREFIX%
exit /b 0
