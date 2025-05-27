#!/bin/bash

# This solves the baroque exception that (some?) gems installed from git cannot be loaded from bare ruby with `require`.

shopt -s nullglob
IFS=:
for path in $(gem env GEM_PATH);do
	for lib in "$path"/bundler/gems/*/lib "$path"/bundler/gems/extensions/*/*/*;do
		if [ -z "$rubylib" ];then
			rubylib="$lib"
		else
			rubylib="$rubylib:$lib"
		fi
	done
done

RUBYLIB="$rubylib" exec "$@"
