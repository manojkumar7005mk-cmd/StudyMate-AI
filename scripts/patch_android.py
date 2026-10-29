"""Adds NDK/CMake settings and permissions to the flutter-generated Android project.
Works with build.gradle (Groovy) or build.gradle.kts (Kotlin DSL)."""
import pathlib
import re
import sys

NDK_VERSION = "28.2.13676358"
CMAKE_VERSION = "3.22.1"
ABI = "arm64-v8a"

app = pathlib.Path("android/app")
gradle = next((p for p in [app / "build.gradle.kts", app / "build.gradle"] if p.exists()), None)
if gradle is None:
    sys.exit("No android/app/build.gradle(.kts) found. Run flutter create --platforms=android . first.")

kts = gradle.suffix == ".kts"
text = gradle.read_text()

# Remove the ndkVersion line flutter generated, so there is only one.
text = re.sub(r"^\s*ndkVersion.*\n", "", text, flags=re.M)

if kts:
    android_block = (
        f'    ndkVersion = "{NDK_VERSION}"\n'
        "    externalNativeBuild {\n"
        "        cmake {\n"
        '            path = file("src/main/cpp/CMakeLists.txt")\n'
        f'            version = "{CMAKE_VERSION}"\n'
        "        }\n"
        "    }\n"
    )
else:
    android_block = (
        f'    ndkVersion "{NDK_VERSION}"\n'
        "    externalNativeBuild {\n"
        "        cmake {\n"
        '            path "src/main/cpp/CMakeLists.txt"\n'
        f'            version "{CMAKE_VERSION}"\n'
        "        }\n"
        "    }\n"
    )

# Only arm64 is built, so the llama.cpp compile runs once instead of for every chip type.
ndk_filter = (
    "        ndk {\n"
    "            abiFilters.clear()\n"
    f'            abiFilters.add("{ABI}")\n'
    "        }\n"
)

if "externalNativeBuild" not in text:
    text, n1 = re.subn(
        r"(^android\s*\{\s*\n)",
        lambda m: m.group(1) + android_block,
        text,
        count=1,
        flags=re.M,
    )
    text, n2 = re.subn(
        r"(defaultConfig\s*\{\s*\n)",
        lambda m: m.group(1) + ndk_filter,
        text,
        count=1,
    )
    if n1 != 1 or n2 != 1:
        sys.exit(f"Could not find the android {{}} or defaultConfig {{}} block in {gradle}")

if ABI not in text:
    sys.exit(f"ABI filter was not inserted into {gradle}")

gradle.write_text(text)

manifest = pathlib.Path("android/app/src/main/AndroidManifest.xml")
if not manifest.exists():
    sys.exit(f"Missing {manifest}")
m = manifest.read_text()
for perm in ["android.permission.INTERNET", "android.permission.RECORD_AUDIO"]:
    if perm not in m:
        m = re.sub(
            r"(<manifest[^>]*>)",
            lambda x: x.group(1) + f'\n    <uses-permission android:name="{perm}"/>',
            m,
            count=1,
        )
manifest.write_text(m)

print(f"Patched {gradle} (NDK {NDK_VERSION}, ABI {ABI}) and {manifest}")
