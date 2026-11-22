CANDIDATE REPLACEMENT SCRIPTS - NOT INSTALLED

release_extension.sh: single extension-only build and ZIP workflow; no upstream merge,
no Git push, no Chrome Web Store publication. It overwrites generated extension
assets after making a timestamped extension backup in HOME. Run only after review.

restart_docker.sh: non-destructive docker compose up -d, no -v volume removal.

Do NOT delete or overwrite the existing scripts on your Mac yet. After testing,
use git mv to archive legacy scripts, update references, and commit the migration.
Current legacy scripts to review: deploy_dashboard.sh, release_dashboard.sh,
update_extension.sh, package_extension.sh, package_chrome_extension.sh.
