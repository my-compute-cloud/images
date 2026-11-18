# A host owner may give jobs a directory that outlives them (the agent's cache_dir policy);
# the agent names it in MCC_CACHE_DIR. Only download caches are put there: what they hold is
# checked against a lock file or a checksum when it is used, and several jobs can write to
# them at once.
if [ -n "${MCC_CACHE_DIR:-}" ] && [ -w "$MCC_CACHE_DIR" ]; then
  export npm_config_cache="$MCC_CACHE_DIR/npm"
  export YARN_CACHE_FOLDER="$MCC_CACHE_DIR/yarn"
  export PIP_CACHE_DIR="$MCC_CACHE_DIR/pip"
  export UV_CACHE_DIR="$MCC_CACHE_DIR/uv"
  export GOMODCACHE="$MCC_CACHE_DIR/go-mod"
  export NUGET_PACKAGES="$MCC_CACHE_DIR/nuget"
  export HOMEBREW_CACHE="$MCC_CACHE_DIR/homebrew"
fi
