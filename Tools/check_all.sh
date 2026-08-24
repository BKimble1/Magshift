#!/bin/sh
# Runs every repository check that does not need Xcode.
#
# These are not a substitute for `xcodebuild test`; they check what a compiler
# and an Xcode-less machine can check: project reference integrity, Swift source
# rules, the prohibited-wording rules, symbol references, the detection
# arithmetic against the expectations the XCTests assert, and both CI
# configurations against what is actually in the repository.
set -e
cd "$(dirname "$0")/.."

python3 Tools/validate_project.py
python3 Tools/audit_sources.py
python3 Tools/audit_sources.py --self-test
python3 Tools/check_symbols.py
python3 Tools/lint_claims.py
python3 Tools/verify_algorithm.py
python3 Tools/select_simulator.py --self-test
python3 Tools/select_xcode.py --self-test
python3 Tools/appstore_build_number.py --self-test
python3 Tools/validate_codemagic.py
python3 Tools/validate_github_workflows.py

echo "All repository checks passed."
