#!/bin/sh
# Enforces the package dependency rule (see README.md › Dependency rule) at the import level. The package
# manifests already enforce it for standalone package builds; this also catches an import that only
# compiles inside the app build, where every package's module sits in the same products directory.
set -eu
cd "$(dirname "$0")/.."

status=0
check() { # package, forbidden modules…
    package=$1
    shift
    for module in "$@"; do
        if grep -rnE "^(@testable )?import $module\$" "Packages/$package/Sources" "Packages/$package/Tests" 2>/dev/null; then
            echo "error: $package must not import $module" >&2
            status=1
        fi
    done
}

check InkKit NotaUI NotaCore NotaDocuments
check NotaUI InkKit NotaCore NotaDocuments
check NotaCore NotaUI NotaDocuments
check NotaDocuments # feature packages may use NotaCore, InkKit and NotaUI; list other features here as they're added

exit $status
