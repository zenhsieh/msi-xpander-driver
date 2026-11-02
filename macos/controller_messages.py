"""Localize API-facing errors; persisted messages remain language independent."""
import os


MESSAGES = {
    "Kiosk 啟動失敗，請查看日誌。": "Kiosk failed to start. Check the logs.",
    "Kiosk 尚未停止，請稍後再試。": "Kiosk has not stopped yet. Try again shortly.",
    "Kiosk 未能啟動，請查看日誌。": "Kiosk did not start. Check the logs.",
    "Mac 顯示狀態格式無效。": "Invalid Mac display state.",
    "不支援的操作。": "Unsupported action.",
    "不支援的設定。": "Unsupported setting.",
    "不支援的顯示模式。": "Unsupported display mode.",
    "來源指令的引號不完整。": "The source command has unmatched quotes.",
    "尚未設定 Kiosk 畫面來源。": "No Kiosk frame source is configured.",
    "尚未設定 Kiosk 畫面來源，請開啟設定檔。": "No Kiosk frame source is configured. Choose Configure Kiosk Source.",
    "延伸桌面啟動失敗；請確認螢幕錄製權限並查看日誌。": "Extended Desktop failed to start. Check Screen Recording permission and the logs.",
    "延伸桌面尚未停止，未啟動另一個輸出程序。": "Extended Desktop has not stopped. Another output was not started.",
    "延伸桌面程序已結束，請查看日誌或重新啟動輸出。": "The desktop process ended. Check the logs or restart output.",
    "操作失敗，請查看日誌。": "The action failed. Check the logs.",
    "桌面元件不完整，請重新安裝 App。": "Desktop components are missing. Reinstall the app.",
    "桌面程序尚未停止，未啟動 Kiosk，請重新開啟 App。": "The desktop process has not stopped. Kiosk was not started. Reopen the app.",
    "正在切換模式，請稍候。": "A mode change is in progress. Please wait.",
    "測試視窗設定無效。": "Invalid test window setting.",
    "無法停止 Kiosk，未啟動另一個輸出程序。": "Unable to stop Kiosk. Another output was not started.",
    "無法確認延伸桌面程序的擁有者，已停止切換。": "Unable to verify the desktop process owner. The mode change was stopped.",
    "登入啟動設定無效。": "Invalid login setting.",
    "設定值不在支援範圍。": "The setting is outside the supported range.",
    "設定值無效。": "Invalid setting value.",
    "請先將 MSI Xpander 拖到應用程式資料夾，再開啟。": "Drag MSI Xpander to Applications before opening it.",
    "請輸入有效的 Kiosk 來源指令。": "Enter a valid Kiosk source command.",
    "輸出已停止，但未能送出黑畫面，請查看日誌。": "Output stopped, but the black frame could not be sent. Check the logs.",
    "目前 Python 缺少 Pillow，請先安裝後再執行安裝程式。": "This Python environment is missing Pillow. Install it before running the installer.",
    "目前輸出程序尚未停止，未替換 App。": "The current output has not stopped. The app was not replaced.",
    "既有 Kiosk 尚未停止。": "The existing Kiosk has not stopped.",
    "新版 App 執行環境無法啟動，已保留目前輸出。請重新打包。": "The new app runtime could not start. Current output was preserved. Rebuild the package.",
}
PREFIXES = {"App 元件不完整：": "Missing app component: "}


def interface_language():
    value = os.environ.get("MSI_UI_LANGUAGE") or os.environ.get("LC_ALL") or os.environ.get("LANG", "en")
    value = value.lower().replace("_", "-")
    return "zh-Hant" if value.startswith(("zh-hant", "zh-tw", "zh-hk")) else "en"


def localize(message):
    if not message:
        return message
    table = MESSAGES if interface_language() == "en" else {value: key for key, value in MESSAGES.items()}
    prefixes = PREFIXES if interface_language() == "en" else {value: key for key, value in PREFIXES.items()}
    if message in table:
        return table[message]
    for source, translated in prefixes.items():
        if message.startswith(source):
            return translated + message[len(source):]
    return message
