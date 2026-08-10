@echo off
rem Zapusk apply-config.ps1 dvoynym klikom. Tekst tolko latinicey: .cmd chitaetsya v CP866,
rem i kirillica v ishodnike prevrashchaetsya v krakozyabry.
rem Put' vychislyaetsya ot mestopolozheniya etogo fayla, tak chto papku mozhno perenosit'.
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0apply-config.ps1" %*
echo.
echo ---------------------------------------------
echo Gotovo. Okno mozhno zakryt.
pause
