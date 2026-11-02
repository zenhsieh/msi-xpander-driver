"""Catalog completeness, format arguments and locale-independent error storage."""
import ast
import json
import os
from pathlib import Path
import re
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).parent
sys.path.insert(0, str(ROOT))
from controller_messages import MESSAGES, PREFIXES, interface_language, localize


def strings(language):
    text = (ROOT / (language + ".lproj") / "Localizable.strings").read_text()
    pairs = re.findall(r'("(?:[^"\\]|\\.)*")\s*=\s*("(?:[^"\\]|\\.)*")\s*;', text)
    decoded = [(json.loads(key), json.loads(value)) for key, value in pairs]
    if len(decoded) != len(dict(decoded)):
        raise AssertionError("Duplicate localization key")
    return dict(decoded)


class LocalizationTests(unittest.TestCase):
    def test_all_ui_keys_exist_in_both_languages_and_preserve_format_arguments(self):
        en, zh = strings("en"), strings("zh-Hant")
        self.assertEqual(set(en), set(zh))
        code = (ROOT / "MenuBarApp.m").read_text()
        keys = {json.loads('"' + value + '"') for value in re.findall(r'L\(@"((?:[^"\\]|\\.)*)"\)', code)}
        self.assertFalse(keys - set(en), keys - set(en))
        for key in keys:
            self.assertTrue(en[key]); self.assertTrue(zh[key])
            self.assertEqual(re.findall(r'%[@dfius]', en[key]), re.findall(r'%[@dfius]', zh[key]), key)
            self.assertFalse(re.search('[\u4e00-\u9fff]', en[key]), key)

    def test_runtime_errors_have_english_translations(self):
        for filename in ("menu_bar_controller.py", "install_menu_bar.py"):
            tree = ast.parse((ROOT / filename).read_text())
            for node in ast.walk(tree):
                if (isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
                        and node.func.id == "RuntimeError" and node.args
                        and isinstance(node.args[0], ast.Constant)):
                    message = node.args[0].value
                    if isinstance(message, str) and re.search('[\u4e00-\u9fff]', message):
                        self.assertIn(message, MESSAGES)

    def test_english_and_traditional_chinese_errors_and_prefixes(self):
        with patch.dict(os.environ, {"MSI_UI_LANGUAGE": "en"}):
            self.assertEqual(localize("正在切換模式，請稍候。"), "A mode change is in progress. Please wait.")
            self.assertEqual(localize("App 元件不完整：/Applications/Test.app"), "Missing app component: /Applications/Test.app")
            self.assertEqual(localize(""), "")
        with patch.dict(os.environ, {"MSI_UI_LANGUAGE": "zh-Hant"}):
            self.assertEqual(localize("A mode change is in progress. Please wait."), "正在切換模式，請稍候。")
            self.assertEqual(localize("Missing app component: /tmp/test"), "App 元件不完整：/tmp/test")

    def test_unsupported_language_falls_back_to_english(self):
        with patch.dict(os.environ, {"MSI_UI_LANGUAGE": "ja"}):
            self.assertEqual(interface_language(), "en")
        with patch.dict(os.environ, {"MSI_UI_LANGUAGE": "zh_TW.UTF-8"}):
            self.assertEqual(interface_language(), "zh-Hant")


if __name__ == "__main__":
    unittest.main()
