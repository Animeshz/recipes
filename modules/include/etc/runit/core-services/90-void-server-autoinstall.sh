#!/bin/sh
set -euo pipefail

trigger_seen=0

for tok in $(cat /proc/cmdline 2>/dev/null || true); do
  case "$tok" in
    void_server_autoinstall=1) trigger_seen=1 ;;
  esac
done

if [ "$trigger_seen" -ne 1 ]; then
  exit 0
fi

recipes_repo=https://github.com/Animeshz/recipes.git
recipes_ref=main
recipes_root=/run/animeshz-recipes
mkdir -p "$recipes_root"

if [ ! -d "$recipes_root/.git" ]; then
  git clone --depth=1 --branch "$recipes_ref" "$recipes_repo" "$recipes_root"
else
  git -C "$recipes_root" fetch --depth=1 origin "$recipes_ref"
  git -C "$recipes_root" checkout --detach FETCH_HEAD
fi

recipe_file="$recipes_root/recipes/void-server-install.ncl"
module_file="$recipes_root/modules/void-server-install.ncl"

if [ ! -f "$recipe_file" ] || [ ! -f "$module_file" ]; then
  logger -t void-server-autoinstall "recipe 'void-server-install' not found in $recipes_repo@$recipes_ref"
  exit 0
fi

nickel_export=$(nickel export --format=json "$recipe_file")
install_plan=$(printf '%s' "$nickel_export" | jq -r .plan)

if [ -z "$install_plan" ] || [ "$install_plan" = "null" ]; then
  logger -t void-server-autoinstall "recipe 'void-server-install' produced no plan"
  exit 0
fi

logger -t void-server-autoinstall "running recipe 'void-server-install' from $recipes_repo@$recipes_ref"
exec sh -c "$install_plan"
