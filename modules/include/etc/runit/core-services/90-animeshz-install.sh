#!/bin/sh
set -euo pipefail

cmdline=$(cat /proc/cmdline 2>/dev/null || true)

install_arg=animesh.install=
repo_arg=animesh.recipes=
ref_arg=animesh.recipes-ref=

install_recipe=
recipes_repo=https://github.com/Animeshz/recipes.git
recipes_ref=main

for tok in $cmdline; do
  case "$tok" in
    "$install_arg"*) install_recipe=${tok#"$install_arg"} ;;
    "$repo_arg"*)    recipes_repo=${tok#"$repo_arg"} ;;
    "$ref_arg"*)     recipes_ref=${tok#"$ref_arg"} ;;
  esac
done

if [ -z "$install_recipe" ] || [ "$install_recipe" = "0" ] || [ "$install_recipe" = "no" ]; then
  exit 0
fi

recipes_root=/run/animeshz-recipes
mkdir -p "$recipes_root"

if [ ! -d "$recipes_root/.git" ]; then
  git clone --depth=1 --branch "$recipes_ref" "$recipes_repo" "$recipes_root"
else
  git -C "$recipes_root" fetch --depth=1 origin "$recipes_ref"
  git -C "$recipes_root" checkout --detach FETCH_HEAD
fi

recipe_file="$recipes_root/recipes/$install_recipe.ncl"
module_file="$recipes_root/modules/$install_recipe.ncl"

if [ ! -f "$recipe_file" ] || [ ! -f "$module_file" ]; then
  logger -t animeshz-install "recipe '$install_recipe' not found in $recipes_repo@$recipes_ref"
  exit 0
fi

nickel_export=$(nickel export --format=json "$recipe_file")
install_plan=$(printf '%s' "$nickel_export" | jq -r .plan)

if [ -z "$install_plan" ] || [ "$install_plan" = "null" ]; then
  logger -t animeshz-install "recipe '$install_recipe' produced no plan"
  exit 0
fi

logger -t animeshz-install "running recipe '$install_recipe' from $recipes_repo@$recipes_ref"
exec sh -c "$install_plan"
