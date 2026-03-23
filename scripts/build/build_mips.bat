@echo off
REM build_mips.bat - Cross-compile for MIPS using Zig (Windows)
REM Target: Realtek RTL9607C-VB5 (MIPS 34Kc, big-endian, musl libc)

setlocal

set SCRIPT_DIR=%~dp0
set REPO_ROOT=%SCRIPT_DIR%..\..
set TARGET=mips-linux-musl
set CFLAGS=-Os -s -fno-unwind-tables -fno-asynchronous-unwind-tables

echo === Frankenrouter MIPS Build ===
echo Repository: %REPO_ROOT%
echo Target: %TARGET%
echo.

REM Check Zig
zig version >nul 2>&1
if errorlevel 1 (
    echo [!] Zig not found. Install from: https://ziglang.org/download/
    echo     Or: winget install zig.zig
    exit /b 1
)
for /f "tokens=*" %%i in ('zig version') do echo [+] Zig version: %%i

REM Create builds directory
if not exist "%REPO_ROOT%\builds" mkdir "%REPO_ROOT%\builds"

REM Build socks5proxy
echo [*] Building socks5proxy...
zig cc -target %TARGET% %CFLAGS% -o "%REPO_ROOT%\builds\socks5proxy" "%REPO_ROOT%\src\socks5proxy\socks5proxy.c"
if errorlevel 1 (
    echo [!] socks5proxy build failed
) else (
    echo [+] socks5proxy built successfully
)

REM Build protomux
echo [*] Building protomux...
zig cc -target %TARGET% %CFLAGS% -o "%REPO_ROOT%\builds\protomux" "%REPO_ROOT%\src\protomux\protomux.c"
if errorlevel 1 (
    echo [!] protomux build failed
) else (
    echo [+] protomux built successfully
)

REM Build smartqos
echo [*] Building smartqos...
zig cc -target %TARGET% %CFLAGS% -o "%REPO_ROOT%\builds\smartqos" "%REPO_ROOT%\src\smartqos\smartqos.c"
if errorlevel 1 (
    echo [!] smartqos build failed
) else (
    echo [+] smartqos built successfully
)

echo.
echo === Build Complete ===
dir "%REPO_ROOT%\builds\"

endlocal
