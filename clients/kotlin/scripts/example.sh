#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
: "${JAVA_HOME:=/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
: "${KOTLIN_HOME:=/Applications/Android Studio.app/Contents/plugins/Kotlin/kotlinc}"
export JAVA_HOME
mkdir -p build/example
"$KOTLIN_HOME/bin/kotlinc" src/main/kotlin src/example/kotlin -include-runtime -d build/example/example.jar 2>&1 | grep -v '^warning' || true
"$JAVA_HOME/bin/java" -cp build/example/example.jar dev.localhub.example.ListModelsKt "$1"
