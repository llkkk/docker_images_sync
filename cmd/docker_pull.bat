@echo off
setlocal enabledelayedexpansion

:: 查找配置文件路径
set "CONFIG_FILE=%~dp0conf.yaml"
if not exist "%CONFIG_FILE%" (
    echo Error: Configuration file conf.yaml not found in %~dp0
    exit /b 1
)

:: 读取配置
set REGISTRY_URL=
set REGISTRY_NS=
set IMAGES_DIR=
set MAX_RETRIES=
set RETRY_DELAY=
set FIRST_DELAY=

for /f "tokens=1* delims=:" %%a in ('type "%CONFIG_FILE%" ^| findstr /v "^#"') do (
    set "LINE=%%a:%%b"
    set "KEY=%%a"
    set "KEY=!KEY: =!"
    set "VALUE=%%b"
    set "VALUE=!VALUE: =!"
    set "VALUE=!VALUE:"=!"
    
    if "!KEY!"=="registry" (
        set REGISTRY_URL=!VALUE!
    )
    if "%%a"=="namespace" (
        set REGISTRY_NS=!VALUE!
    )
    if "!KEY!"=="images_dir" (
        set IMAGES_DIR=!VALUE!
    )
    if "!KEY!"=="max_retries" (
        set MAX_RETRIES=!VALUE!
    )
    if "!KEY!"=="retry_delay" (
        set RETRY_DELAY=!VALUE!
    )
    if "!KEY!"=="first_delay" (
        set FIRST_DELAY=!VALUE!
    )
)

:: 设置默认值
if "!MAX_RETRIES!"=="" set MAX_RETRIES=60
if "!RETRY_DELAY!"=="" set RETRY_DELAY=1
if "!FIRST_DELAY!"=="" set FIRST_DELAY=20


:: 检查必要配置
if "!REGISTRY_URL!"=="" (
    echo [Error] registry not configured in conf.yaml
    exit /b 1
)
if "!REGISTRY_NS!"=="" (
    echo [Error] namespace not configured in conf.yaml
    exit /b 1
)

if "!IMAGES_DIR!"=="" (
    echo [Error] images_dir not configured in conf.yaml
    exit /b 1
)

:: 检查是否有参数
if "%~1"=="" (
    echo Usage: %~n0 tag1 [tag2 ...]
    exit /b 1
)

:: 执行git pull操作
echo [refresh git repo] Start git pull: 
pushd "!IMAGES_DIR!"
git pull
popd

:: 写入images.txt文件
echo [record images] Writing tags to !IMAGES_DIR!\images.txt
(
    for %%a in (%*) do (
        echo %%a
    )
) > "!IMAGES_DIR!\images.txt"

:: 执行git commit操作
echo [commit images] Start git commit: 
pushd "!IMAGES_DIR!"
git add images.txt
git commit -m "refactor: add docker tags: %*"
git push
popd

echo [pull images] wait !FIRST_DELAY!s for docker pull in github
timeout /t !FIRST_DELAY! /nobreak >nul

:: 执行docker pull带重试功能
set FAILED_TAGS=
for %%t in (%*) do (
    set TAG=%%t
    echo [pull images] Processing tag: !TAG!
    
    :: 提取最后一部分并处理名称转换
    for /f "delims=" %%p in ("!TAG!") do set "ORIGINAL_LAST_PART=%%~nxp"
    
    :: 将下划线替换为斜杠，恢复原始路径结构
    set "RESTORED_PART=!ORIGINAL_LAST_PART!"
    set "RESTORED_PART=!RESTORED_PART:_=/!"
    
    set FULL_TAG=!REGISTRY_URL!/!REGISTRY_NS!/!RESTORED_PART!
    set SUCCESS=0
    
    for /l %%a in (1,1,!MAX_RETRIES!) do (
        if !SUCCESS! equ 0 (
            call echo [Attempt %%a/!MAX_RETRIES!] Pulling !FULL_TAG!
            docker pull !FULL_TAG!
            
            if !errorlevel! equ 0 (
                set SUCCESS=1
                echo [pull images] Successfully pulled !FULL_TAG!, now delete origin image !FULL_TAG!:
                docker tag !FULL_TAG! !TAG!
                docker rmi !FULL_TAG!
            ) else (
                if %%a lss !MAX_RETRIES! (
                    timeout /t !RETRY_DELAY! /nobreak >nul
                )
            )
        )
    )
    
    if !SUCCESS! equ 0 (
        echo [pull images] Failed to pull !FULL_TAG! after !MAX_RETRIES! attempts
        set FAILED_TAGS=!FAILED_TAGS! !TAG!
    )
)

:: 显示失败结果
if not "!FAILED_TAGS!"=="" (
    echo.
    echo ====== Summary of failed pulls ======
    for %%t in (!FAILED_TAGS!) do (
        echo  - !REGISTRY_URL!/%%t
    )
    exit /b 1
)

echo ====== All images pulled successfully ======
exit /b 0