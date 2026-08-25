@echo off
setlocal
title DHT11 Monitor v1.5 Pro
cd /d "%~dp0"

echo.
echo =============================================
echo DHT11 Monitor v1.5 Pro
echo =============================================
echo.

echo [1/6] Eski geocoding paketi varsa kaldiriliyor...
call flutter pub remove geocoding >nul 2>&1

echo [2/6] Geolocator kontrol...
call flutter pub add geolocator:13.0.2
if errorlevel 1 goto error

echo [3/6] Flutter temizleniyor...
call flutter clean
if errorlevel 1 goto error

if exist .dart_tool rmdir /s /q .dart_tool
if exist pubspec.lock del /q pubspec.lock

echo [4/6] Paketler yukleniyor...
call flutter pub get
if errorlevel 1 goto error

echo [5/6] geocoding_android kontrol...
call flutter pub deps | findstr /I "geocoding"
if not errorlevel 1 (
  echo HATA: geocoding dependency agacinda halen var.
  pause
  exit /b 1
)

echo [6/6] Flutter run...
call flutter run
goto end

:error
echo.
echo HATA OLUSTU. Son satirlarin ekran goruntusunu at.
pause
exit /b 1

:end
echo.
pause
endlocal
