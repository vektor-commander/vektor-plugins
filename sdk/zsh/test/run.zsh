#!/bin/zsh
# The test plugin for sdk/zsh/vektor.zsh: `vektor-plugin test sdk/zsh/test sdk/zsh/test/checks.json` talks to it over the real
# wire. It loads the helper from the folder above, which a published plugin never may (it carries its own copy).
#
#   * command `selftest`  runs selftest.zsh (the unit tests) in a child shell and answers with its summary;
#   * view event `echo`   answers with a view that shows the text it received, and a field read from a nested value of the
#                         event: multi-byte framing and nested reads, both directions, through the real host;
#   * view event `ask`    sends a confirm request, waits for the answer and shows it: a request answered over the wire.
source ${0:A:h}/../vektor.zsh

on_startup() { vk_get params.settings.greeting greeting; greeting=${greeting:-Hello} }

on_invoke() {
  local command summary
  vk_get params.command command
  case $command in
    selftest)
      if summary=$(zsh ${0:A:h}/selftest.zsh 2>&1); then
        vk_reply $VK_ID "{\"message\":$(vk_str "${summary##*$'\n'}")}"
      else
        vk_log error "$summary"
        vk_refuse $VK_ID "The helper's tests failed: ${summary##*$'\n'}"
      fi ;;
    *) vk_refuse $VK_ID "This plugin has no command “$command”." ;;
  esac
}

on_view_event() {
  local action value first answer
  vk_get params.action action
  case $action in
    echo)
      vk_get params.value value
      vk_get params.files.0.name first
      vk_view_update echo "$(vk_description 1 "$(vk_vstack "$(vk_text "$value" id=echoed)" "$(vk_text "${first}" id=nested)" id=root)" Echo)" ;;
    ask)
      if vk_confirm "Sure?" "Really?" "Yes"; then answer=yes; else answer=no; fi
      vk_toast "answer: $answer" ;;
  esac
}

vk_run
