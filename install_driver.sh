#!/bin/bash

# ==============================================================================
# Helper to install a Virtual Audio Device on macOS (No Homebrew required)
# ==============================================================================

echo "=========================================================="
echo "  Установка виртуального микрофона для WO Mic на macOS   "
echo "=========================================================="
echo ""
echo "Выберите способ установки:"
echo "1) Скачать и установить VB-Cable (Без Homebrew, прямая загрузка .pkg)"
echo "2) Установить Homebrew (brew) и затем BlackHole"
echo "3) Открыть официальный сайт BlackHole в браузере"
echo "4) Выход"
echo ""
printf "Ваш выбор (1/2/3/4): "
read -r CHOICE

case $CHOICE in
    1)
        echo ""
        echo "Скачивание установщика VB-Cable для Mac (~4.5 МБ)..."
        TEMP_DIR="/tmp/vbcable_install"
        mkdir -p "$TEMP_DIR"
        curl -sSL -o "$TEMP_DIR/vbcable.zip" "https://download.vb-audio.com/Download_MAC/VBCable_MACDriver_Pack108.zip"
        
        if [ $? -eq 0 ]; then
            echo "Распаковка..."
            unzip -q -o "$TEMP_DIR/vbcable.zip" -d "$TEMP_DIR"
            if [ -f "$TEMP_DIR/VBCable_MACDriver_Pack108.dmg" ]; then
                echo "Монтирование диска и запуск установщика..."
                hdiutil attach "$TEMP_DIR/VBCable_MACDriver_Pack108.dmg" -nobrowse -quiet
                # Find mounted volume
                MOUNT_VOL=$(ls -d /Volumes/VBCable* 2>/dev/null | head -n 1)
                if [ -n "$MOUNT_VOL" ]; then
                    PKG=$(find "$MOUNT_VOL" -name "*.pkg" | head -n 1)
                    if [ -n "$PKG" ]; then
                        echo "Запуск стандартного установщика macOS..."
                        open "$PKG"
                        echo "Следуйте подсказкам установщика на экране."
                    fi
                fi
            fi
        else
            echo "Ошибка скачивания. Проверьте подключение к интернету."
        fi
        ;;
    2)
        echo ""
        echo "Установка Homebrew (потребуется подтверждение и пароль)..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        
        # Check standard brew path
        if [ -x "/opt/homebrew/bin/brew" ]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
            brew install blackhole-2ch
        elif [ -x "/usr/local/bin/brew" ]; then
            eval "$(/usr/local/bin/brew shellenv)"
            brew install blackhole-2ch
        fi
        ;;
    3)
        echo "Открытие сайта https://existential.audio/blackhole/ ..."
        open "https://existential.audio/blackhole/"
        ;;
    *)
        echo "Отменено."
        exit 0
        ;;
esac
