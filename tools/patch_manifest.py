"""Добавляет в android/app/src/main/AndroidManifest.xml разрешения и название приложения.
Запускать после `flutter create` из корня проекта: python tools/patch_manifest.py"""
import pathlib
import re
import sys

p = pathlib.Path("android/app/src/main/AndroidManifest.xml")
if not p.exists():
    sys.exit("Не найден %s - сначала выполни flutter create (см. README)" % p)
s = p.read_text(encoding="utf-8")

PERMS = """    <uses-permission android:name="android.permission.INTERNET"/>
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
"""
INTENTS = """        <intent><action android:name="android.intent.action.VIEW"/><data android:scheme="https"/></intent>
        <intent><action android:name="android.intent.action.VIEW"/><data android:scheme="geo"/></intent>
"""

if "ACCESS_FINE_LOCATION" not in s:
    if "<queries>" in s:
        s = s.replace("<queries>", "<queries>\n" + INTENTS, 1)
        s = s.replace("<application", PERMS + "    <application", 1)
    else:
        s = s.replace("<application", PERMS + "    <queries>\n" + INTENTS + "    </queries>\n    <application", 1)
s = re.sub(r'android:label="[^"]*"', 'android:label="История рядом"', s, count=1)
p.write_text(s, encoding="utf-8")
print("AndroidManifest.xml обновлён")
