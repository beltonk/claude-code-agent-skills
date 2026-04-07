#!/usr/bin/env bash
# Explore a project's structure, conventions, and tooling in one shot.
# Replaces 5-10 tool calls the agent would otherwise make.
# Sources shared detect-project.sh for consistent detection.
#
# Usage:
#   ./explore-project.sh                    # current directory
#   ./explore-project.sh /path/to/project   # specified directory

set -euo pipefail

DIR="${1:-.}"
cd "$DIR" 2>/dev/null || { echo "ERROR: Cannot access $DIR"; exit 1; }

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
    if [ -f "next.config.js" ] || [ -f "next.config.mjs" ] || [ -f "next.config.ts" ]; then FRAMEWORK="nextjs"
    elif [ -f "nuxt.config.ts" ] || [ -f "nuxt.config.js" ]; then FRAMEWORK="nuxt"
    elif [ -f "vite.config.ts" ] || [ -f "vite.config.js" ]; then FRAMEWORK="vite"
    elif [ -f "angular.json" ]; then FRAMEWORK="angular"
    elif [ -f "svelte.config.js" ]; then FRAMEWORK="svelte"
    elif grep -q '"react"' package.json 2>/dev/null; then FRAMEWORK="react"
    elif grep -q '"vue"' package.json 2>/dev/null; then FRAMEWORK="vue"
    elif grep -q '"express"' package.json 2>/dev/null; then FRAMEWORK="express"
    elif grep -q '"fastify"' package.json 2>/dev/null; then FRAMEWORK="fastify"
    elif grep -q '"hono"' package.json 2>/dev/null; then FRAMEWORK="hono"; fi
  elif [ -f "Cargo.toml" ]; then PROJECT_TYPE="rust"; PKG_MGR="cargo"
  elif [ -f "go.mod" ]; then PROJECT_TYPE="go"; PKG_MGR="go"
  elif [ -f "pyproject.toml" ] || [ -f "setup.py" ] || [ -f "requirements.txt" ]; then
    PROJECT_TYPE="python"
    if [ -f "poetry.lock" ]; then PKG_MGR="poetry"
    elif [ -f "Pipfile.lock" ]; then PKG_MGR="pipenv"
    elif [ -f "uv.lock" ]; then PKG_MGR="uv"
    else PKG_MGR="pip"; fi
    if grep -q "django" requirements.txt 2>/dev/null || grep -q "django" pyproject.toml 2>/dev/null; then FRAMEWORK="django"
    elif grep -q "flask" requirements.txt 2>/dev/null || grep -q "flask" pyproject.toml 2>/dev/null; then FRAMEWORK="flask"
    elif grep -q "fastapi" requirements.txt 2>/dev/null || grep -q "fastapi" pyproject.toml 2>/dev/null; then FRAMEWORK="fastapi"; fi
  elif [ -f "Gemfile" ]; then
    PROJECT_TYPE="ruby"; PKG_MGR="bundler"
    if grep -q "rails" Gemfile 2>/dev/null; then FRAMEWORK="rails"; fi
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

echo "# Project Exploration"
echo "**Directory**: $(pwd)"
echo "**Date**: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

echo "## Project Type"
echo "- **Platform**: ${PROJECT_TYPE:-unknown}"
echo "- **Package manager**: ${PKG_MGR:-not detected}"
if [ -n "$FRAMEWORK" ]; then echo "- **Framework**: $FRAMEWORK"; fi
if [ -n "$TEST_RUNNER" ]; then echo "- **Test runner**: $TEST_RUNNER"; fi
if [ -n "$LINTER" ]; then echo "- **Linter**: $LINTER"; fi
if [ -n "$TYPE_CHECKER" ]; then echo "- **Type checker**: $TYPE_CHECKER"; fi
if [ -n "$BUILDER" ]; then echo "- **Builder**: $BUILDER"; fi
echo ""

# --- Test conventions (details beyond what detect-project provides) ---
echo "## Testing"
test_dirs=""
for d in tests test spec __tests__ cypress e2e; do
  [ -d "$d" ] && test_dirs="$test_dirs $d"
done
if [ -n "$test_dirs" ]; then
  echo "- **Test directories**:$test_dirs"
else
  echo "- **Test directories**: none found"
fi

test_count=$(find . -maxdepth 5 -type f \( -name '*_test.*' -o -name '*.test.*' -o -name '*.spec.*' -o -name 'test_*' \) \
  -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/dist/*' 2>/dev/null | wc -l | tr -d ' ')
echo "- **Test files found**: $test_count"
echo ""

# --- Code quality (additional tools beyond linter/type checker) ---
echo "## Code Quality"
if [ -f ".prettierrc" ] || [ -f ".prettierrc.json" ] || [ -f "prettier.config.js" ]; then echo "- **Formatter**: Prettier"; fi
if [ -f ".editorconfig" ]; then echo "- **Editor config**: .editorconfig"; fi
if [ -f ".pre-commit-config.yaml" ]; then echo "- **Pre-commit hooks**: configured"; fi
if [ -f "biome.json" ]; then echo "- **Biome**: configured"; fi
echo ""

# --- CI/CD ---
echo "## CI/CD"
if [ -d ".github/workflows" ]; then
  echo "- **Platform**: GitHub Actions"
  for f in .github/workflows/*.yml .github/workflows/*.yaml; do
    [ -f "$f" ] && echo "  - \`$(basename "$f")\`"
  done
fi
if [ -f ".gitlab-ci.yml" ]; then echo "- **Platform**: GitLab CI"; fi
if [ -f "Jenkinsfile" ]; then echo "- **Platform**: Jenkins"; fi
if [ -f ".circleci/config.yml" ]; then echo "- **Platform**: CircleCI"; fi
if [ -f "Dockerfile" ] || [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ]; then echo "- **Docker**: yes"; fi
echo ""

# --- Key configuration files ---
echo "## Configuration Files"
for f in .env.example .env.template docker-compose.yml docker-compose.yaml \
  Makefile Taskfile.yml Justfile \
  tsconfig.json package.json pyproject.toml Cargo.toml go.mod Gemfile \
  AGENTS.md CLAUDE.md .cursorrules; do
  [ -f "$f" ] && echo "- \`$f\`"
done
echo ""

# --- Directory structure ---
echo "## Directory Structure"
echo '```'
if command -v tree &>/dev/null; then
  tree -L 2 -d --noreport -I 'node_modules|.git|dist|build|__pycache__|target|.next|.turbo|coverage|.venv|venv' 2>/dev/null
else
  find . -maxdepth 2 -type d \
    -not -path '*/node_modules*' -not -path '*/.git*' \
    -not -path '*/dist*' -not -path '*/build*' -not -path '*/__pycache__*' \
    -not -path '*/target*' -not -path '*/.next*' -not -path '*/.venv*' \
    2>/dev/null | sort | head -40
fi
echo '```'
echo ""

# --- Entry points ---
echo "## Likely Entry Points"
for f in src/index.ts src/index.js src/main.ts src/main.js src/app.ts src/app.js \
  main.go cmd/main.go main.py app.py manage.py src/main.rs src/lib.rs \
  index.ts index.js app.ts app.js server.ts server.js; do
  [ -f "$f" ] && echo "- \`$f\`"
done

# --- Naming conventions sample ---
echo ""
echo "## Naming Convention Sample (first 10 source files)"
find . -maxdepth 3 -type f \( -name '*.ts' -o -name '*.js' -o -name '*.py' -o -name '*.go' -o -name '*.rs' -o -name '*.rb' \) \
  -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/dist/*' -not -path '*/build/*' \
  2>/dev/null | head -10 | while read -r f; do echo "- \`$f\`"; done
