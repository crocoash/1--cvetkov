@echo off
title Конфигурация 1С

rem Скрипт ищем сначала рядом с этим файлом, затем по обычному пути репозитория -
rem чтобы .cmd работал и как ярлык, и просто скопированным на рабочий стол.
set PS=%~dp0apply-config.ps1
if not exist "%PS%" set PS=%USERPROFILE%\Documents\fork\1--cvetkov\_tools\apply-config.ps1
if not exist "%PS%" (
  echo Не найден apply-config.ps1 ни рядом с этим файлом, ни в
  echo %USERPROFILE%\Documents\fork\1--cvetkov\_tools
  echo Проверьте, что репозиторий на месте, и сделайте git pull.
  pause
  exit /b 1
)

:menu
cls
echo ==========================================
echo   Обновление конфигурации 1С из GitHub
echo ==========================================
echo.
echo   1  - Обновить базу (монопольно, все выходят)
echo   2  - Обновить динамически (людей не выгонять)
echo   3  - Только загрузить из файлов (можно при людях)
echo   4  - Только обновить конфигурацию БД
echo   5  - То же, динамически
echo   6  - Выгрузить конфигурацию из базы в файлы + снимок
echo   7  - Настроить базу и пользователя
echo   8  - Обновить БД, завершив чужие сеансы (людей выгоняем)
echo.
echo   0  - Выход
echo.
set OPT=
set /p OPT=Введите номер и нажмите Enter: 
if "%OPT%"=="1" set ARGS=& goto run
if "%OPT%"=="2" set ARGS=-dyn& goto run
if "%OPT%"=="3" set ARGS=-loadonly& goto run
if "%OPT%"=="4" set ARGS=-updateonly& goto run
if "%OPT%"=="5" set ARGS=-updateonly -dyn& goto run
if "%OPT%"=="6" set ARGS=-dump& goto run
if "%OPT%"=="7" set ARGS=-setup& goto run
if "%OPT%"=="8" set ARGS=-updateonly -kickall& goto run
if "%OPT%"=="0" exit /b
goto menu

:run
cls
echo Запуск. Шаг загрузки из файлов идёт молча несколько минут - это нормально,
echo окно не закрывать и не прерывать.
echo Открытая на этом компьютере 1С закроется сама и запустится обратно
echo после обновления - сохраните незаписанные документы.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS%" %ARGS%
echo.
echo ------------------------------------------
echo Нажмите любую клавишу, чтобы вернуться в меню.
pause >nul
goto menu