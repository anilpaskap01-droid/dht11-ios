@echo off
setlocal
title DHT11 Monitor - iOS Hazirla
cd /d "%~dp0"

echo.
echo ===============================================
echo DHT11 Monitor v1.5 Pro - iOS Hazirlama
echo ===============================================
echo.

echo [1/5] iOS platform dosyalari uretiliyor...
call flutter create --platforms=ios --org com.dht11monitor .
if errorlevel 1 goto error

echo.
echo [2/5] iOS Bluetooth ve konum izinleri ekleniyor...
call dart run tool\prepare_ios.dart
if errorlevel 1 goto error

echo.
echo [3/5] Flutter paketleri aliniyor...
call flutter pub get
if errorlevel 1 goto error

echo.
echo [4/5] Flutter analyze...
call flutter analyze
if errorlevel 1 (
  echo.
  echo Analyze uyari/hata verdi. Yukaridaki ciktiyi kontrol et.
)

echo.
echo [5/5] Tamamlandi.
echo.
echo Windows'ta iOS build veya iPhone'a flutter run yapilamaz.
echo Bu klasoru GitHub'a yukleyip Codemagic macOS build ile IPA/TestFlight uretebilirsin.
echo.
pause
exit /b 0

:error
echo.
echo HATA: iOS hazirlama tamamlanamadi.
pause
exit /b 1
