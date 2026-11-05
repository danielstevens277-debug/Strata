@echo off
rem Level Zero SDK for the Windows port: headers (ze_api.h) and the ze_loader import library, neither of which
rem ships with the GPU driver - C:\Windows\System32\ze_loader.dll is the runtime only, and oneAPI's Base Toolkit has
rem no level-zero component (STRATA_ZE_LOADER-NOTFOUND in CMakeCache.txt).  Without this, sycl_queue.hpp resolves
rem zeMemAllocHost/zeMemFree from the loader at run time instead (STRATA_ZE_DYNAMIC); with it, CMake defines
rem STRATA_HAVE_ZE and links the import library.
rem
rem Installs into %STRATA_LEVEL_ZERO_PREFIX% (default C:\Strata-tools\level-zero-install), then pass to CMake:
rem   -DSTRATA_ZE_INCLUDE_DIR=<prefix>/include -DSTRATA_ZE_LOADER=<prefix>/lib/ze_loader.lib
setlocal
set "TAG=%STRATA_LEVEL_ZERO_TAG%"
if not defined TAG set "TAG=v1.35.0"
if not defined STRATA_LEVEL_ZERO_PREFIX set "STRATA_LEVEL_ZERO_PREFIX=C:\Strata-tools\level-zero-install"
if not defined STRATA_LEVEL_ZERO_SRC set "STRATA_LEVEL_ZERO_SRC=C:\Strata-tools\level-zero"

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

if not exist "%STRATA_LEVEL_ZERO_SRC%\CMakeLists.txt" (
    echo Fetching Level Zero %TAG% into %STRATA_LEVEL_ZERO_SRC%
    git clone --depth 1 --branch %TAG% https://github.com/oneapi-src/level-zero "%STRATA_LEVEL_ZERO_SRC%"
    if errorlevel 1 exit /b 1
)

set "PREFIX_FWD=%STRATA_LEVEL_ZERO_PREFIX:\=/%"
cmake -S "%STRATA_LEVEL_ZERO_SRC%" -B "%STRATA_LEVEL_ZERO_SRC%\build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="%PREFIX_FWD%"
if errorlevel 1 exit /b 1
cmake --build "%STRATA_LEVEL_ZERO_SRC%\build"
if errorlevel 1 exit /b 1
cmake --install "%STRATA_LEVEL_ZERO_SRC%\build"
if errorlevel 1 exit /b 1

echo.
echo Level Zero SDK installed in %STRATA_LEVEL_ZERO_PREFIX%
if not exist "%STRATA_LEVEL_ZERO_PREFIX%\include\level_zero\ze_api.h" (
    echo Missing include\level_zero\ze_api.h - the tree was built but not installed.
    exit /b 1
)
echo   include: %STRATA_LEVEL_ZERO_PREFIX%\include\level_zero
for %%F in ("%STRATA_LEVEL_ZERO_PREFIX%\lib\ze_loader.lib") do echo   library: %%~fF (%%~zF bytes)
exit /b 0
