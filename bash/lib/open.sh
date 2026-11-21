# shellcheck shell=bash
# URLs for posts and comments, and an opt-in browser launcher.

# luti_url post|comment ID [page|link|media|origin]: print a URL, launch nothing.
#   page    <instance>/post/ID or <instance>/comment/ID (default)
#   link    the post's link (url)
#   media   the post's image/video url, else embed_video_url, else thumbnail_url
#   origin  the original federated copy (ap_id)
luti_url() {
	local kind=${1:-} id=${2:-} what=${3:-page} norm url
	_luti_need_id "$kind" "$id" || return 1
	_luti_ready || return 1
	case $kind:$what in
		post:page | comment:page)
			printf '%s/%s/%s\n' "$LUTI_INSTANCE" "$kind" "$id"
			return 0
			;;
		post:link | post:media | post:origin | comment:origin) ;;
		*)
			_luti_err "luti_url: '$what' is not available for a $kind (use page, origin$([[ $kind == post ]] && echo ", link, media"))"
			return 1
			;;
	esac
	if [[ $kind == post ]]; then
		norm=$(LUTI_RAW=0 luti_post_get "$id" '{"comments":0}' | jq -c .post) || return
	else
		norm=$(LUTI_RAW=0 luti_comment_get "$id") || return
	fi
	url=$(jq -r --arg w "$what" '
		if $w == "origin" then .ap_id
		elif $w == "link" then .url
		else (if .media_kind == "image" or .media_kind == "video" then .url else null end)
			// .embed_video_url // .thumbnail_url end // empty' <<<"$norm")
	if [[ -z $url ]]; then
		case $what in
			link) _luti_err "post $id has no link" ;;
			media) _luti_err "post $id has no image or video" ;;
			*) _luti_err "$kind $id has no origin URL" ;;
		esac
		return 1
	fi
	printf '%s\n' "$url"
}

# luti_safe_url URL: true for http:// or https:// URLs without spaces or control characters.
luti_safe_url() {
	local u=${1:-} lower
	lower=${u,,}
	[[ $lower == http://?* || $lower == https://?* ]] || return 1
	[[ $u != *[[:space:][:cntrl:]]* ]]
}

# luti_open_url URL: open URL in the default browser, detached, output discarded.
# Tries $BROWSER, xdg-open, open (macOS), wslview, then cmd.exe. Only http(s)
# URLs are accepted. Without any launcher, prints the URL and returns 1.
luti_open_url() {
	local url=${1:-} b list=() words=()
	luti_safe_url "$url" || {
		_luti_err "refusing to open '$url' (only http:// and https:// URLs)"
		return 2
	}
	if [[ -n ${BROWSER:-} ]]; then
		IFS=: read -r -a list <<<"$BROWSER"
		for b in "${list[@]}"; do
			read -r -a words <<<"$b"
			if [[ ${#words[@]} -gt 0 ]] && command -v "${words[0]}" >/dev/null 2>&1; then
				_luti_launch "${words[@]}" "$url"
				return 0
			fi
		done
	fi
	if command -v xdg-open >/dev/null 2>&1; then
		_luti_launch xdg-open "$url"
	elif [[ $(uname -s 2>/dev/null) == Darwin ]] && command -v open >/dev/null 2>&1; then
		_luti_launch open "$url"
	elif command -v wslview >/dev/null 2>&1; then
		_luti_launch wslview "$url"
	elif command -v cmd.exe >/dev/null 2>&1 && [[ $url != *[\"^%!\<\>\|\&]* ]]; then
		_luti_launch cmd.exe /c start "" "$url"
	else
		_luti_err "no browser launcher found (set BROWSER); the URL is:"
		printf '%s\n' "$url"
		return 1
	fi
	return 0
}

# _luti_launch CMD ARGS...: run detached with all output discarded.
_luti_launch() {
	("$@" </dev/null >/dev/null 2>&1 &)
}
