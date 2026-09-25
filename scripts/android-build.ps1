# Build APK Android di Windows.
#   powershell -File scripts/android-build.ps1            -> APK debug
#   powershell -File scripts/android-build.ps1 -Release   -> APK rilis (butuh keystore)
#
# Dua penyesuaian untuk laptop ini:
#  - JAVA_HOME default ke JDK bawaan Android Studio (JDK 25; butuh Gradle 9.1+).
#  - JDK memakai "Unix domain socket" di folder TEMP; folder TEMP yang mengandung
#    spasi (C:\Users\Dell Latitude\...) membuat Gradle gagal ("Unable to establish
#    loopback connection"), jadi diarahkan ke folder tanpa spasi.
param([switch]$Release)

$ErrorActionPreference = 'Stop'
if (-not $env:JAVA_HOME) { $env:JAVA_HOME = 'C:\Program Files\Android\Android Studio\jbr' }
$socketDir = 'D:\AndroidStudio\tmp'
New-Item -ItemType Directory -Force $socketDir | Out-Null
$env:JAVA_TOOL_OPTIONS = "-Djdk.net.unixdomain.tmpdir=$socketDir"

Push-Location (Join-Path $PSScriptRoot '..\android')
try {
    $task = if ($Release) { 'assembleRelease' } else { 'assembleDebug' }
    & .\gradlew.bat $task --console=plain
    if ($LASTEXITCODE -ne 0) { throw "Build gagal ($task)" }
} finally {
    Pop-Location
}
