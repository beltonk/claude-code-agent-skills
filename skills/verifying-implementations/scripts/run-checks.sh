#!/usr/bin/env bash
# Auto-detect and run verification checks for a project.
# Uses shared detect-project.sh for consistent detection across skills.
# Outputs structured PASS/FAIL results the agent can parse directly.
#
# Usage:
#   ./run-checks.sh                    # run in current directory
#   ./run-checks.sh /path/to/project   # run in specified directory
#   ./run-checks.sh --tests-only       # skip lint and type checks
#   ./run-checks.sh --lint-only        # skip tests

set -uo pipefail

MODE="all"
DIR="."
for arg in "$@"; do
  case "$arg" in
    --tests-only) MODE="tests" ;;
    --lint-only)  MODE="lint" ;;
    *)            DIR="$arg" ;;
  esac
done

cd "$DIR" 2>/dev/null || { echo "FAIL: Cannot access directory $DIR"; exit 1; }

# --- Project detection (inlined for skill portability) ---
detect_project() {
  local dir="${1:-.}"
  local orig_dir="$(pwd)"
  cd "$dir" 2>/dev/null || return 1
  PROJECT_TYPE="" PKG_MGR="" TEST_RUNNER="" LINTER="" TYPE_CHECKER="" BUILDER="" FRAMEWORK=""
  if [ -f "package.json" ]; then
    PROJECT_TYPE="node"
    if [ -f "pnpm-lock.yaml" ]; then PKG_MGR="pnpm"
    elif [ -f "bun.lockb" ] || [ -f "bun.lock" ]; then PKG_MGR="bun"
    elif [ -f "yarn.lock" ]; then PKG_MGR="yarn"
    else PKG_MGR="npm"; fi
    if [ -f "tsconfig.json" ]; then PROJECT_TYPE="typescript"; fi
  elif [ -f "Cargo.toml" ]; then PROJECT_TYPE="rust"; PKG_MGR="cargo"
  elif [ -f "go.mod" ]; then PROJECT_TYPE="go"; PKG_MGR="go"
  elif [ -f "pyproject.toml" ] || [ -f "setup.py" ] || [ -f "requirements.txt" ]; then
    PROJECT_TYPE="python"
    if [ -f "poetry.lock" ]; then PKG_MGR="poetry"
    elif [ -f "Pipfile.lock" ]; then PKG_MGR="pipenv"
    elif [ -f "uv.lock" ]; then PKG_MGR="uv"
    else PKG_MGR="pip"; fi
  elif [ -f "Gemfile" ]; then PROJECT_TYPE="ruby"; PKG_MGR="bundler"
  elif [ -f "build.gradle" ] || [ -f "build.gradle.kts" ] || [ -f "pom.xml" ]; then
    PROJECT_TYPE="java"
    if [ -f "build.gradle" ] || [ -f "build.gradle.kts" ]; then PKG_MGR="gradle"; else PKG_MGR="maven"; fi
  fi
  case "$PROJECT_TYPE" in
    node|typescript)
      if [ -f "vitest.config.ts" ] || [ -f "vitest.config.js" ]; then TEST_RUNNER="$PKG_MGR run test"
      elif [ -f "jest.config.js" ] || [ -f "jest.config.ts" ] || ([ -f "package.json" ] && grep -q '"jest"' package.json 2>/dev/null); then TEST_RUNNER="$PKG_MGR test"
      elif [ -f "package.json" ] && grep -q '"test"' package.json 2>/dev/null; then TEST_RUNNER="$PKG_MGR test"; fi ;;
    rust) TEST_RUNNER="cargo test" ;; go) TEST_RUNNER="go test ./..." ;;
    python)
      if [ -f "pytest.ini" ] || [ -f "conftest.py" ] || ([ -f "pyproject.toml" ] && grep -q "pytest" pyproject.toml 2>/dev/null); then TEST_RUNNER="python -m pytest"
      elif [ -d "tests" ] || [ -d "test" ]; then TEST_RUNNER="python -m pytest"
      else TEST_RUNNER="python -m unittest discover"; fi ;;
    ruby) TEST_RUNNER="bundle exec rspec" ;;
    java) if [ "$PKG_MGR" = "gradle" ]; then TEST_RUNNER="./gradlew test"; else TEST_RUNNER="mvn test"; fi ;;
  esac
  case "$PROJECT_TYPE" in
    node|typescript)
      if [ -f ".eslintrc.js" ] || [ -f ".eslintrc.json" ] || [ -f ".eslintrc.yml" ] || [ -f "eslint.config.js" ] || [ -f "eslint.config.mjs" ]; then LINTER="npx eslint ."
      elif [ -f "biome.json" ]; then LINTER="npx biome check ."; fi ;;
    rust) LINTER="cargo clippy -- -D warnings" ;; go) if command -v golangci-lint &>/dev/null; then LINTER="golangci-lint run"; else LINTER="go vet ./..."; fi ;;
    python) if command -v ruff &>/dev/null; then LINTER="ruff check ."; elif command -v flake8 &>/dev/null; then LINTER="flake8 ."; fi ;;
    ruby) LINTER="bundle exec rubocop" ;;
  esac
  case "$PROJECT_TYPE" in
    typescript) TYPE_CHECKER="npx tsc --noEmit" ;; python) if command -v mypy &>/dev/null; then TYPE_CHECKER="mypy ."; fi ;; rust) TYPE_CHECKER="cargo check" ;;
  esac
  case "$PROJECT_TYPE" in
    node|typescript) if [ -f "package.json" ] && grep -q '"build"' package.json 2>/dev/null; then BUILDER="$PKG_MGR run build"; fi ;;
    rust) BUILDER="cargo build" ;; go) BUILDER="go build ./..." ;;
    java) if [ "$PKG_MGR" = "gradle" ]; then BUILDER="./gradlew build"; else BUILDER="mvn package"; fi ;;
  esac
  cd "$orig_dir"
}
detect_project "."

PASS=0
FAIL=0
SKIP=0

run_check() {
  local name="$1"
  local cmd="$2"
  echo "### Check: $name"
  echo "**Command:** \`$cmd\`"
  if output=$(eval "$cmd" 2>&1); then
    echo "**Result:** PASS"
    PASS=$((PASS + 1))
  else
    echo "**Result:** FAIL"
    echo "**Output (last 20 lines):**"
    echo '```'
    echo "$output" | tail -20
    echo '```'
    FAIL=$((FAIL + 1))
  fi
  echo ""
}

skip_check() {
  local name="$1"
  local reason="$2"
  echo "### Check: $name"
  echo "**Result:** SKIP — $reason"
  SKIP=$((SKIP + 1))
  echo ""
}

echo "# Verification Report"
echo "**Directory:** $(pwd)"
echo "**Date:** $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""
echo "## Detection"
echo "- Project type: ${PROJECT_TYPE:-not detected}"
echo "- Package manager: ${PKG_MGR:-not detected}"
echo "- Test runner: ${TEST_RUNNER:-not detected}"
echo "- Linter: ${LINTER:-not detected}"
echo "- Type checker: ${TYPE_CHECKER:-not detected}"
echo "- Builder: ${BUILDER:-not detected}"
echo ""

echo "## Results"
echo ""

if [ "$MODE" = "all" ] || [ "$MODE" = "tests" ]; then
  if [ -n "$TEST_RUNNER" ]; then
    run_check "Test suite" "$TEST_RUNNER"
  else
    skip_check "Test suite" "No test runner detected"
  fi
fi

if [ "$MODE" = "all" ] || [ "$MODE" = "lint" ]; then
  if [ -n "$LINTER" ]; then
    run_check "Linter" "$LINTER"
  else
    skip_check "Linter" "No linter detected"
  fi

  if [ -n "$TYPE_CHECKER" ]; then
    run_check "Type checker" "$TYPE_CHECKER"
  else
    skip_check "Type checker" "No type checker detected"
  fi
fi

if [ "$MODE" = "all" ] && [ -n "$BUILDER" ]; then
  run_check "Build" "$BUILDER"
fi

echo "## Summary"
echo ""
echo "| Result | Count |"
echo "|--------|-------|"
echo "| PASS   | $PASS |"
echo "| FAIL   | $FAIL |"
echo "| SKIP   | $SKIP |"
echo ""

if [ "$FAIL" -gt 0 ]; then
  echo "**VERDICT: FAIL**"
  exit 1
elif [ "$PASS" -eq 0 ]; then
  echo "**VERDICT: PARTIAL** — no checks could be run"
  exit 2
else
  echo "**VERDICT: PASS**"
  exit 0
fi
