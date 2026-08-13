#!/usr/bin/env -S awk -f

# dia:file scripts/_ls-make-targets.awk

# ---
# description: >-
#   Lists all make targets with description; more precisely, all lines
#   conceptually matching "pattern: ## description"
# ---

# ---

BEGIN {
    FS = ":.*?## *"

    # Ignore hidden targets by default; specify
    # -v target_pattern="^[A_Za-z_-]+$" for inclusion
    if (target_pattern == "") {
        target_pattern = "^[A-Za-z][A-Za-z_-]*$"
    }
}

$1 ~ target_pattern {
    targets[++n] = $1
    desc[n] = $2
    len = length($1)
    if (length($1) > max) {
        max = len
    }
}

END {
    max += 1
    for (i = 1; i <= n; i++) {
        printf "%-*s: %s\n", max, targets[i], desc[i]
    }
}
