@echo off
title DHT11 Monitor v1.4
cd /d "%~dp0"

echo =============================================
echo DHT11 Monitor v1.4 - Flutter Baslatiliyor
echo =============================================
echo.

call flutter clean
if errorlevel 1 goto error

call flutter pub get
if errorlevel 1 goto error

call flutter analyze
if errorlevel 1 (
  echo.
  echo Analyze uyari/hata verdi. Yine de flutter run deneniyor...
)

call flutter run
goto end

:error
echo.
echo Islem basarisiz oldu.
pause
exit /b 1

:end
echo.
pause
