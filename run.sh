#!/bin/bash
lpm run \
  --config='core.reload_module("colors.onedark")' \
  --ephemeral \
  ./ scm \
  json onedark \
  language_sh \
  "$@"
