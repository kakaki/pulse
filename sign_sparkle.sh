# Signs the embedded Sparkle.framework inside-out (per Sparkle's docs). Sourced by build.sh and release.sh.
#   sign_sparkle <app> <identity> [extra codesign flags…]
sign_sparkle() {
  local app="$1" id="$2"; shift 2
  local fw="$app/Contents/Frameworks/Sparkle.framework" v
  v="$fw/Versions/B"
  local cs=(codesign --force --sign "$id" "$@")
  for xpc in "$v"/XPCServices/*.xpc; do
    [[ -e "$xpc" ]] || continue
    if [[ "$(basename "$xpc")" == "Downloader.xpc" ]]; then
      "${cs[@]}" --preserve-metadata=entitlements "$xpc" >/dev/null
    else
      "${cs[@]}" "$xpc" >/dev/null
    fi
  done
  "${cs[@]}" "$v/Autoupdate" >/dev/null
  "${cs[@]}" "$v/Updater.app" >/dev/null
  "${cs[@]}" "$fw" >/dev/null
}
