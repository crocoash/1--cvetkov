@echo off
title Конфигурация 1С
set PS=%~dp0apply-config.ps1
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
if "%OPT%"=="0" exit /b
goto menu

:run
cls
echo Запуск. Шаг загрузки из файлов идёт молча несколько минут - это нормально,
echo окно не закрывать и не прерывать.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS%" %ARGS%
echo.
echo ------------------------------------------
echo Нажмите любую клавишу, чтобы вернуться в меню.
pause >nul
goto menu