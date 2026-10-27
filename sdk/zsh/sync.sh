#!/bin/zsh
# Copies sdk/zsh/vektor.zsh into the plugin folders that carry it (a plugin may only load files from its own folder).
# Run it after changing vektor.zsh; the helper's tests fail while a copy differs.
cd ${0:A:h}/../.. || exit 1
for target in templates/zsh samples/todo; do
  cp sdk/zsh/vektor.zsh $target/vektor.zsh && echo "copied to $target/vektor.zsh"
done
