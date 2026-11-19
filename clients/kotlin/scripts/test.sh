#!/bin/sh
# Compiles and tests the SDK with Android Studio's bundled Kotlin and JDK (no Gradle, no downloads).
#   KOTLIN_HOME / JAVA_HOME override the defaults.
set -eu
cd "$(dirname "$0")/.."
: "${JAVA_HOME:=/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
: "${KOTLIN_HOME:=/Applications/Android Studio.app/Contents/plugins/Kotlin/kotlinc}"
export JAVA_HOME
out=build/test
rm -rf "$out" && mkdir -p "$out"
"$JAVA_HOME/bin/keytool" -genkeypair -alias hub -keyalg RSA -keysize 2048 -validity 2 -dname CN=LocalHub \
  -storetype PKCS12 -keystore "$out/hub.p12" -storepass secret >/dev/null 2>&1
"$KOTLIN_HOME/bin/kotlinc" src/main/kotlin src/test/kotlin -include-runtime -d "$out/tests.jar" 2>&1 | grep -v '^warning' || true
"$JAVA_HOME/bin/java" -cp "$out/tests.jar" dev.localhub.client.ClientTestKt "$out/hub.p12"
