#!/bin/bash
lpm run --ephemeral --config='core.reload_module("colors.onedark")' ./ json onedark scm language_sh "$@"
