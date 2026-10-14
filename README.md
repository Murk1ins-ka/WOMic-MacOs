# WO Mic for macOS (Native Studio Port & GUI)

[![Release](https://img.shields.io/badge/Release-v1.0.0-green.svg?style=flat-square)](https://github.com/Murk1ins-ka/WOMic-MacOs/releases)
[![Platform](https://img.shields.io/badge/Platform-macOS%2011%2B-blue.svg?style=flat-square&logo=apple)](https://github.com/Murk1ins-ka/WOMic-MacOs)
[![Swift](https://img.shields.io/badge/Swift-Native-orange.svg?style=flat-square&logo=swift)](https://github.com/Murk1ins-ka/WOMic-MacOs)
[![Driver](https://img.shields.io/badge/Audio%20Driver-Pre--bundled-purple.svg?style=flat-square)](https://github.com/Murk1ins-ka/WOMic-MacOs)

> **Хэштеги / Topics:** `#womic` `#womic-macos` `#virtual-microphone` `#audio` `#coreaudio` `#opus` `#vb-cable` `#microphone` `#swift` `#gui`

---

### 💾 Быстрая загрузка:
Скачайте готовый установщик: **[WOMic-macOS.dmg](WOMic-macOS.dmg)** (1.4 МБ). Перетащите `WOMic.app` в папку `Applications`.

---

Нативный порт клиента **WO Mic** для macOS со встроенным виртуальным аудиодрайвером, графическим интерфейсом (GUI) и командным скриптом.

Расположение: `~/Documents/womic-macos` (`/Users/---/Documents/womic-macos`).

---

## ⚡️ Встроенный аудиодрайвер (Установка без интернета и без Homebrew)

Виртуальный аудиодрайвер **уже встроен прямо в приложение**:
- `~/Documents/womic-macos/driver/VBCable.driver`
- Внутри бандла `WOMic.app/Contents/Resources/Driver/`

Вам **не нужно ничего скачивать, не нужен Homebrew и не нужен интернет**:

### Активация драйвера в GUI (Графический интерфейс):
1. Запустите **`WOMic.app`** (или `./womic.sh -g`).
2. Нажмите кнопку **`⚡️ Активировать встроенный драйвер микрофона (1 клик)`**.
3. Подтвердите установку через **Touch ID** или пароль администратора.
4. Система моментально подключит виртуальный микрофон!

### Активация драйвера в CLI (Терминал):
При первом запуске:
```bash
cd ~/Documents/womic-macos
./womic.sh -w
```
Скрипт сам обнаружит, что драйвер еще не активирован, и скопирует встроенный драйвер в `/Library/Audio/Plug-Ins/HAL` (потребуется ввести пароль `sudo`).

---

## 🚀 Настройка микрофона для Discord / Telegram / Zoom / OBS

1. Запустите **WO Mic** на телефоне и нажмите **Start**.
2. Запустите **WO Mic** на Mac (**`WOMic.app`** или `./womic.sh -w`).
3. В окне WO Mic в списке **Audio Output** будет автоматически выбран:
   - ⭐ **`VB-Cable`** (или `BlackHole`).
4. В ваших приложениях (Discord, Zoom, Telegram, OBS и т.д.):
   - Зайдите в Настройки звука -> **Микрофон (Устройство ввода)**.
   - Выберите **`VB-Cable`**.

Готово! Звук с телефона поступает в любые программы как настоящий микрофон.

---

## 💻 Использование

### 1. Графический интерфейс (GUI)
- Откройте **`WOMic.app`** в Finder (папка `Documents/womic-macos`).
- Или выполните в терминале:
  ```bash
  cd ~/Documents/womic-macos
  ./womic.sh -g
  ```

В окне приложения:
- Введите IP-адрес телефона (отображается в приложении WO Mic на смартфоне).
- Нажмите **Connect**.
- Шкала громкости (VU-метр) сразу отобразит уровень звука вашего голоса.

---

### 2. Через Bash-скрипт (`womic.sh`)

Скрипт полностью повторяет логику вашего оригинального скрипта:
```bash
cd ~/Documents/womic-macos

# Подключение по Wi-Fi (запросит IP или можно передать аргументом)
./womic.sh -w

# Сразу с IP-адресом:
./womic -w 192.168.1.100

# Подключение по Bluetooth
./womic.sh -b

# Отключение
./womic.sh -k

# Список аудиоустройств
./womic.sh -l

# Открыть GUI
./womic.sh -g

# Справка
./womic.sh -h
```

---

## 📁 Структура папки

```
~/Documents/womic-macos/
├── WOMic.app/             # Готовое приложение macOS с иконкой и встроенным драйвером
├── driver/                # Встроенный универсальный драйвер (Intel + Apple Silicon)
│   └── VBCable.driver
├── womic                  # Нативный бинарник (CLI + GUI)
├── womic.sh               # Bash-скрипт
├── README.md              # Документация
└── src/                   # Исходный код Swift
    ├── AudioEngine.swift
    ├── WOMicClient.swift
    ├── DriverInstaller.swift # Активатор драйвера в 1 клик
    ├── MainWindowController.swift
    ├── AppDelegate.swift
    └── main.swift
```
