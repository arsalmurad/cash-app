#!/usr/bin/env bash
# Optional cached Android tools; source after scripts/codex_cloud_env.sh.
# The base Linux bootstrap deliberately does not install mobile SDKs.
if [[ ! -x /workspace/toolchains/temurin-17.0.20.1/bin/java ||
      ! -x /workspace/toolchains/android-sdk/cmdline-tools/19.0/bin/sdkmanager ]]; then
  printf '%s\n' 'Pinned optional Android tools are missing; inspect the handoff before installing.' >&2
  return 2 2>/dev/null || exit 2
fi
export JAVA_HOME=/workspace/toolchains/temurin-17.0.20.1
export ANDROID_HOME=/workspace/toolchains/android-sdk
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export ANDROID_USER_HOME=/workspace/.cache/android-user
export ANDROID_AVD_HOME=/workspace/.cache/android-avd
export GRADLE_USER_HOME=/workspace/.cache/gradle
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/cmdline-tools/19.0/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"
# Preserve TLS verification with the managed host's verified CA roots.
if [[ " ${JAVA_TOOL_OPTIONS:-} " != *' -Djavax.net.ssl.trustStore=/etc/ssl/certs/java/cacerts '* ]]; then
  export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:+$JAVA_TOOL_OPTIONS }-Djavax.net.ssl.trustStore=/etc/ssl/certs/java/cacerts"
fi
