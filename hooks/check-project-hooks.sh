#!/bin/zsh
# check-project-hooks.sh — Global SessionStart hook
# Scans the current project for .claude/hooks/ scripts and ensures:
#   1. All .sh scripts are executable (auto-fix if not)
#   2. All hook commands referenced in .claude/settings.json point to existing files

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
HOOKS_DIR="$PROJECT_DIR/.claude/hooks"
SETTINGS="$PROJECT_DIR/.claude/settings.json"

# No project hooks dir → nothing to check
if [[ ! -d "$HOOKS_DIR" ]]; then exit 0; fi

ISSUES=()
FIXED=()

# ── 1. Ensure all scripts in .claude/hooks/ are executable ──
for script_file in "$HOOKS_DIR"/*.sh(N); do
    if [[ ! -x "$script_file" ]]; then
        chmod +x "$script_file"
        FIXED+=("chmod +x $(basename "$script_file")")
    fi
done

# ── 2. Check hook commands in settings.json reference valid files ──
if [[ -f "$SETTINGS" ]]; then
    # Extract all command strings from hooks config
    hook_commands=("${(@f)$(jq -r '
        .hooks // {} | to_entries[] | .value[] | .hooks[]? |
        select(.type == "command") | .command
    ' "$SETTINGS" 2>/dev/null)}")

    for cmd in "${hook_commands[@]}"; do
        if [[ -z "$cmd" ]]; then continue; fi
        # Check if the command starts with a relative path to a file
        first_token="${cmd%% *}"
        # Resolve relative to project dir
        if [[ "$first_token" == ./* || "$first_token" == .claude/* ]]; then
            resolved="$PROJECT_DIR/$first_token"
            if [[ ! -f "$resolved" ]]; then
                ISSUES+=("Hook references missing file: $first_token")
            elif [[ ! -x "$resolved" ]]; then
                chmod +x "$resolved"
                FIXED+=("chmod +x $first_token")
            fi
        fi
    done
fi

# ── 3. Check if hooks dir has scripts but settings.json has no hooks config ──
script_count=$(ls "$HOOKS_DIR"/*.sh 2>/dev/null | wc -l | tr -d ' ')
if [[ "$script_count" -gt 0 ]]; then
    if [[ ! -f "$SETTINGS" ]]; then
        ISSUES+=("Project has $script_count hook script(s) in .claude/hooks/ but no .claude/settings.json")
    elif [[ -z "$(jq -r '.hooks // empty' "$SETTINGS" 2>/dev/null)" ]]; then
        ISSUES+=("Project has $script_count hook script(s) in .claude/hooks/ but settings.json has no hooks config")
    fi
fi

# ── Output ──
if [[ ${#FIXED[@]} -gt 0 || ${#ISSUES[@]} -gt 0 ]]; then
    echo "🔧 Project hooks check:"
    for f in "${FIXED[@]}"; do
        echo "  ✅ Auto-fixed: $f"
    done
    for i in "${ISSUES[@]}"; do
        echo "  ⚠️ $i"
    done
fi
