# Local app updates

After implementing changes in this project, automatically build, sign, and
update the installed app at `~/Applications/Sundial.app`. Run the appropriate
checks first, then use `build-app.sh`, preserving the app's existing signing
identity and user data.

Gracefully quit any running copy and launch the updated installed app so the
changes are active without the user having to reopen it. Do not stop after
changing the repository or compiling a development binary.

# Public releases

Publish `main` and release tags descended from it. If this checkout contains a
`master` branch with the original private development history, keep that branch
local: never push it or use `git push --all`.

Use a GitHub noreply address for public commits. Keep signing credentials and
activity records out of commits and release assets. Public preview DMGs are
ad-hoc signed and must clearly disclose that they are not notarized.
