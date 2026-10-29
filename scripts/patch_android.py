"""Adds the NDK/CMake settings and permissions that the flutter-generated android/ folder lacks.
Works with build.gradle (Groovy) or build.gradle.kts (Kotlin DSL)."""
import pathlib, re, sys

app = pathlib.Path('android/app')
gradle = next((p for p in [app / 'build.gradle.kts', app / 'build.gradle'] if p.exists()), None)
if gradle is None:
    sys.exit('No android/app/build.gradle(.kts) found. Run flutter create --platforms=android . first.')

kts = gradle.suffix == '.kts'
text = gradle.read_text()
text = re.sub(r'^\s*ndkVersion.*\n', '', text, flags=re.M)

if kts:
    android_block = (
        '    ndkVersion = "27.2.12479018"\n'
        '    externalNativeBuild {\n'
        '        cmake {\n'
        '            path = file("src/main/cpp/CMakeLists.txt")\n'
        '            version = "3.22.1"\n'
        '        }\n'
        '    }\n'
    )
    ndk_filter = '        ndk { abiFilters += listOf("arm64-v8a") }\n'
else:
    android_block = (
        '    ndkVersion "27.2.12479018"\n'
        '    externalNativeBuild {\n'
        '        cmake {\n'
        '            path "src/main/cpp/CMakeLists.txt"\n'
        '            version "3.22.1"\n'
        '        }\n'
        '    }\n'
    )
    ndk_filter = '        ndk { abiFilters "arm64-v8a" }\n'

if 'externalNativeBuild' not in text:
    text = re.sub(r'(^android\s*\{\s*\n)', lambda m: m.group(1) + android_block, text, count=1, flags=re.M)
    text = re.sub(r'(defaultConfig\s*\{\s*\n)', lambda m: m.group(1) + ndk_filter, text, count=1)
gradle.write_text(text)

manifest = pathlib.Path('android/app/src/main/AndroidManifest.xml')
m = manifest.read_text()
for perm in ['android.permission.INTERNET', 'android.permission.RECORD_AUDIO']:
    if perm not in m:
        m = re.sub(r'(<manifest[^>]*>)', lambda x: x.group(1) + f'\n    <uses-permission android:name="{perm}"/>', m, count=1)
manifest.write_text(m)
print('Patched', gradle, 'and', manifest)
