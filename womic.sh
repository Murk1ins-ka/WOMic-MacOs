#!/bin/bash

# ==============================================================================
# WO Mic Client for macOS (CLI & GUI Wrapper)
# Ported from Linux to macOS with native CoreAudio & AppKit GUI
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$SCRIPT_DIR/womic"
APP="$SCRIPT_DIR/WOMic.app"

if [ $# -eq 0 ]; then
    echo "Usage: womic [OPTIONS]"
    echo "Options:"
    echo "   -w   - to connect via WiFi"
    echo "   -b   - to connect via Bluetooth"
    echo "   -g   - to open macOS GUI window"
    echo "   -k   - to disconnect"
    echo "   -h   - help (this message)"
    echo ""
    echo "No options specified. Launching GUI interface..."
    if [ -d "$APP" ]; then
        open "$APP"
    elif [ -x "$BIN" ]; then
        "$BIN" -g &
    fi
    exit 0
fi

# Check for macOS native womic binary
function executable_check() {
    if [ ! -x "$BIN" ]; then
        if [ -f "$SCRIPT_DIR/src/main.swift" ]; then
            printf "WO Mic macOS binary not found! Compiling from Swift sources now...\n"
            swiftc -O -framework Cocoa -framework AudioToolbox -framework CoreAudio \
                "$SCRIPT_DIR/src/AudioEngine.swift" \
                "$SCRIPT_DIR/src/OpusDecoder.swift" \
                "$SCRIPT_DIR/src/WOMicClient.swift" \
                "$SCRIPT_DIR/src/DriverInstaller.swift" \
                "$SCRIPT_DIR/src/MainWindowController.swift" \
                "$SCRIPT_DIR/src/AppDelegate.swift" \
                "$SCRIPT_DIR/src/main.swift" \
                -o "$BIN"
            codesign -s - -f --deep --entitlements "$SCRIPT_DIR/entitlements.plist" "$BIN" 2>/dev/null
            chmod +x "$BIN"
            printf "Compilation completed successfully!\n\n"
        else
            printf "Error: WO Mic binary '$BIN' not found!\n"
            exit 1
        fi
    fi
}

# Check for virtual audio driver on macOS (BlackHole / VB-Cable)
# (Replaces Linux ALSA snd-aloop module check)
function audio_driver_check() {
    if ! system_profiler SPAudioDataType 2>/dev/null | grep -iE "BlackHole|Cable|Loopback|Soundflower" > /dev/null 2>&1; then
        printf "\n[Активация драйвера] Встроенный виртуальный драйвер VB-Cable еще не активирован.\n"
        printf "Для того чтобы звук с телефона шел в Discord/Zoom как микрофон, требуется активировать его.\n"
        printf "Активировать встроенный драйвер сейчас? (y/n): "
        read -r INPUT
        if [ "$INPUT" == "y" ]; then
            DRIVER_SRC="$SCRIPT_DIR/driver/VBCable.driver"
            if [ ! -d "$DRIVER_SRC" ]; then
                DRIVER_SRC="$APP/Contents/Resources/Driver/VBCable.driver"
            fi
            
            if [ -d "$DRIVER_SRC" ]; then
                echo "Копирование драйвера в /Library/Audio/Plug-Ins/HAL (потребуется ввод sudo пароля)..."
                sudo mkdir -p /Library/Audio/Plug-Ins/HAL
                sudo cp -R "$DRIVER_SRC" /Library/Audio/Plug-Ins/HAL/
                sudo killall -9 coreaudiod 2>/dev/null
                sleep 2
                printf "✅ Встроенный драйвер успешно активирован и готов к работе!\n\n"
            else
                "$SCRIPT_DIR/install_driver.sh"
            fi
        else
            printf "Продолжаем с выводом на текущие системные динамики/наушники.\n\n"
        fi
    fi
}

while getopts "hbwkgl" OPTION; do
    case $OPTION in
        h)
            echo "Usage: womic [OPTIONS]"
            echo "Options:"
            echo "   -w   - to connect via WiFi"
            echo "   -b   - to connect via Bluetooth"
            echo "   -g   - to open macOS GUI window"
            echo "   -l   - list available audio devices"
            echo "   -k   - to disconnect"
            echo "   -h   - help (this message)"
            exit 0
            ;;
        l)
            executable_check
            "$BIN" -l
            exit 0
            ;;
        g)
            executable_check
            if [ -d "$APP" ]; then
                open "$APP"
            else
                "$BIN" -g &
            fi
            exit 0
            ;;
        b)
            if [ -n "$(ps aux | grep '[w]omic -b' | awk '{print $2}')" ]; then
                printf "WO Mic is already running!\n"
                exit 1
            else
                executable_check
                audio_driver_check
                printf "(Format: xx:xx:xx:xx:xx:xx)\n"
                printf "Enter device address: "
                read -r ADDRESS
                echo ""
                printf "Run 'womic -k' to disconnect\n\n"
                "$BIN" -b "$ADDRESS" &
                sleep 3
            fi
            ;;
        w)
            if [ -n "$(ps aux | grep '[w]omic -w' | awk '{print $2}')" ]; then
                printf "WO Mic is already running!\n"
                exit 1
            else
                executable_check
                audio_driver_check
                printf "(Example: 192.168.1.102)\n"
                printf "Enter device IP: "
                read -r IP
                echo ""
                printf "Run 'womic -k' to disconnect\n\n"
                "$BIN" -w "$IP" &
                sleep 3
            fi
            ;;
        k)
            CURRENT_PID=$$
            PIDS=$(ps aux | grep -E '([w]omic -[wbg]|[W]OMic.app/Contents/MacOS/WOMic)' | awk '{print $2}' | grep -v "^$CURRENT_PID$")
            if [ -z "$PIDS" ]; then
                printf "WO Mic is not running!\n"
                exit 1
            else
                kill -2 $PIDS > /dev/null 2>&1
                sleep 1
                printf "WO Mic disconnected.\n"
                exit 0
            fi
            ;;
        *)
            echo ""
            echo "Run 'womic -h' for help"
            exit 0
            ;;
    esac
done
