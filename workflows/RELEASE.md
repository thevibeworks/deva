# Release Workflow

Execute when user requests: `patch`, `minor`, or `major` release.

## Steps

1. **Prerequisites**: Clean git, synced upstream, CI passing
2. **Current version**: Extract from `deva.sh` VERSION variable
3. **New version**: Increment per semver (patch/minor/major)
4. **Changelog**: Generate from `git log --oneline --no-merges v{last}..HEAD`
5. **Update files**: `deva.sh` VERSION, `CHANGELOG.md` entry
6. **Commit**: `chore: release v{version}`
7. **Tag & push**: `git tag -a v{version} && git push --tags`
8. **Verify**: Show final git log confirmation

## Semver

- **patch**: Bug fixes (0.0.x)
- **minor**: Features (0.x.0)
- **major**: Breaking (x.0.0)

## Rollback

```bash
git reset --hard HEAD~1       # if not pushed
git tag -d v{version}         # delete local tag
git push origin :v{version}   # delete remote tag
```
