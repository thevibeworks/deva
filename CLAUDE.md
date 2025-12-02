# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Deva Architecture: Container-Based Agent Sandboxing

**CRITICAL DESIGN PATTERN**: Deva purposely runs ALL agents inside Docker containers. The container IS the sandbox.

- Each agent (claude, codex, gemini) runs in isolated container environment
- Agent internal sandboxes/permission systems are DISABLED (e.g., claude --dangerously-skip-permissions, GEMINI_SANDBOX=false)
- Container provides security boundary instead of agent-level prompts
- Result: No interactive permission prompts while maintaining isolation

**Why**: Avoids permission fatigue in trusted workspaces while keeping agents containerized for safety.

## We're following Issue-Based Development (IBD) workflow
1. Before running any Git/GitHub CLI `Bash` command (`git commit`, `gh issue create`, `gh pr create`, etc.), open the corresponding file in @workflows to review required steps.
2. Always apply the exact templates or conventions from the following files:
   - @workflows/GITHUB-ISSUE.md → issues
   - @workflows/GIT-COMMIT.md  → commits
   - @workflows/GITHUB-PR.md   → pull requests
   - @workflows/RELEASE.md     → releases
3. Keep one branch per issue; merging the PR must auto-close its linked issue.


@./AGENTS.md
