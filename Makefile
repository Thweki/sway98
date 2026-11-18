# sway98 development targets.
#
# `make check` is what CI runs: static analysis, then a full rehearsal install
# and rollback in a throwaway $HOME so nothing on the developer machine moves.

SHELL_FILES := $(shell find . -name '*.sh' -not -path './.git/*')

# The sandbox checks delete and recreate the same tests/sandbox tree. Keep
# recipes serial even with -j or inherited MAKEFLAGS, including explicit goals.
.NOTPARALLEL:

.PHONY: check check-make check-syntax check-shellcheck check-selection check-sandbox check-dryrun check-roundtrip check-real check-hashes check-presets check-install-status check-verify check-ini check-include-block check-include-trimming check-real-isolation check-plan install-hooks

check: check-make check-syntax check-shellcheck check-selection check-sandbox check-hashes check-presets check-install-status check-verify check-ini check-include-block check-include-trimming check-real-isolation check-plan

check-make:
	@bash tests/check-make.sh

check-hashes:
	@bash tests/file-hashes.sh

check-presets:
	@bash tests/module-presets.sh

check-ini:
	@bash tests/ini-line-endings.sh

check-include-block:
	@bash tests/include-block.sh

check-verify:
	@bash tests/verify-files.sh

check-install-status:
	@bash tests/install-status.sh

check-syntax:
	@git ls-files -z -- '*.sh' | xargs -0 -r -n 1 bash -n
	@echo "bash -n: clean"

# Reject invalid numeric selections before any module can be applied.
check-selection:
	@bash tests/test-selection.sh

# Against a real Chicago95 checkout (symlinks, depth, 4900+ files). Skips itself
# with exit 0 when no checkout is found, so CI stays green without one.
check-real:
	@tests/verify-real-tree.sh

check-shellcheck:
	@command -v shellcheck >/dev/null || { echo "shellcheck not installed"; exit 1; }
	shellcheck -x -S style $(SHELL_FILES)
	@echo "shellcheck: clean"

# Every module must survive --dry-run without touching the filesystem.
check-dryrun:
	@tests/run-sandbox.sh dry-run

# Reuse the dry-run fixture for roundtrip (regression: tests/sandbox-reuse.sh).
check-sandbox:
	@tests/run-sandbox.sh all

# Install everything, then uninstall, then compare the sandbox $HOME against a
# pristine copy of it. Any difference is a bug in the transaction layer.
check-roundtrip:
	@tests/run-sandbox.sh roundtrip

clean:
	rm -rf tests/sandbox

check-include-trimming:
	@bash tests/include-trimming.sh

check-real-isolation:
	@bash tests/check-real-isolation.sh

check-plan:
	@bash tests/install-plan.sh
